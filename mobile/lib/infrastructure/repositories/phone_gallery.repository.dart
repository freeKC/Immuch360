// The albums and assets of the device that "Share this phone on the network" serves, read from the database the
// local sync fills (see PhoneGalleryTree). Photos and videos only.

import 'package:drift/drift.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/data/db/main/table/local/asset.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/services/phone_share/phone_gallery_tree.dart';
import 'package:immich_mobile/infrastructure/repositories/local_album.repository.dart';

class PhoneGalleryRepository implements PhoneGallerySource {
  PhoneGalleryRepository(this._db, this._albums);

  final Drift _db;
  final LocalAlbumRepository _albums;

  /// Ids per query, under the limit of SQLite on the variables of a statement
  static const _idChunk = 500;

  static const _mediaTypes = [AssetType.image, AssetType.video];

  @override
  Future<List<LocalAlbum>> albums() => _albums.getAll(sortBy: {SortLocalAlbumsBy.name});

  @override
  Future<List<LocalAsset>> albumAssets(String albumId) async => [
    for (final asset in await _albums.getAssets(albumId))
      if (_mediaTypes.contains(asset.type)) asset,
  ];

  @override
  Future<List<({int year, int month, int count})>> months() async {
    final month = _localMonth;
    final count = _db.localAssetEntity.id.count();
    final query = _db.selectOnly(_db.localAssetEntity)
      ..addColumns([month, count])
      ..where(_db.localAssetEntity.type.isInValues(_mediaTypes))
      ..groupBy([month])
      ..orderBy([OrderingTerm.desc(month)]);
    final rows = await query.get();
    final months = <({int year, int month, int count})>[];
    for (final row in rows) {
      final parsed = RegExp(r'^(\d{4})-(\d{2})$').firstMatch(row.read(month) ?? '');
      if (parsed == null) {
        continue;
      }
      months.add((year: int.parse(parsed.group(1)!), month: int.parse(parsed.group(2)!), count: row.read(count) ?? 0));
    }
    return months;
  }

  /// The assets whose creation month, in local time, is [month] of [year]: the months of [months] group them the same
  /// way, so that a month folder holds what its count said
  @override
  Future<List<LocalAsset>> monthAssets(int year, int month) {
    final key = '${year.toString().padLeft(4, '0')}-${month.toString().padLeft(2, '0')}';
    final query = _db.localAssetEntity.select()
      ..where((row) => row.type.isInValues(_mediaTypes) & _localMonth.equals(key))
      ..orderBy([(row) => OrderingTerm.desc(row.createdAt), (row) => OrderingTerm.desc(row.id)]);
    return query.map((row) => row.toDto()).get();
  }

  @override
  Future<List<LocalAsset>> assetsByIds(Iterable<String> ids) async {
    final unique = ids.toSet().toList();
    final assets = <LocalAsset>[];
    for (var start = 0; start < unique.length; start += _idChunk) {
      final chunk = unique.sublist(start, start + _idChunk > unique.length ? unique.length : start + _idChunk);
      final query = _db.localAssetEntity.select()
        ..where((row) => row.id.isIn(chunk) & row.type.isInValues(_mediaTypes));
      assets.addAll(await query.map((row) => row.toDto()).get());
    }
    assets.sort((a, b) {
      final byDate = b.createdAt.compareTo(a.createdAt);
      return byDate != 0 ? byDate : b.id.compareTo(a.id);
    });
    return assets;
  }

  /// The creation month of an asset as "yyyy-MM" in local time, as the timelines of the device group them; the dates
  /// are stored in UTC
  Expression<String> get _localMonth =>
      _db.localAssetEntity.createdAt.modify(const DateTimeModifier.localTime()).strftime('%Y-%m');
}
