import 'package:collection/collection.dart';
import 'package:drift/drift.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/data/db/main/table/local/asset.dart';
import 'package:immich_mobile/data/db/main/table/remote/asset.dart';
import 'package:immich_mobile/data/db/main/table/remote/asset.drift.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/exif.model.dart';
import 'package:immich_mobile/domain/models/panorama_360.model.dart';

/// The candidates of the 360° page of the Library, read from the local database: the remote assets the sync stream
/// brought (own, partner and album assets, their exif included) and the assets of this device. No network: the server
/// list is the one the sync keeps here. See Panorama360ListService, which merges and filters them in memory.
class Panorama360Repository {
  const Panorama360Repository(this._db);

  final Drift _db;

  /// Ids per IN clause, well under the variable limit of SQLite
  static const chunkSize = 500;

  /// Fires after any change of the tables the list reads, a sync batch included
  Stream<void> watchChanges() => _db
      .tableUpdates(
        TableUpdateQuery.onAllTables([
          _db.remoteAssetEntity,
          _db.remoteExifEntity,
          _db.localAssetEntity,
          _db.stackEntity,
        ]),
      )
      .map((_) {});

  /// The remote candidates for [userId]: flagged, raw by name, equirect photos of 360° cameras without GPano tags (see
  /// [_cameraEquirectPhoto]), forced ([forcedKeys], server ids among them), and own assets whose checksum is the one of
  /// a device asset of [deviceIds]. One entry per remote id.
  ///
  /// No owner filter for the first two: the local database only holds own assets, partner assets and the assets of
  /// shared albums, all of which the user may see; [Panorama360Entry.isOwn] tells them apart.
  Future<List<Panorama360Entry>> loadRemote({
    required String userId,
    required Set<String> forcedKeys,
    required Set<String> deviceIds,
  }) async {
    final deviceChecksums = <String, String>{};
    final lae = _db.localAssetEntity;
    for (final slice in deviceIds.slices(chunkSize)) {
      final query = lae.selectOnly()
        ..addColumns([lae.id, lae.checksum])
        ..where(lae.id.isIn(slice) & lae.checksum.isNotNull());
      for (final row in await query.get()) {
        // The first id wins, so that the entry carries one stable id on the device
        deviceChecksums.putIfAbsent(row.read(lae.checksum)!, () => row.read(lae.id)!);
      }
    }

    final entries = <String, Panorama360Entry>{};
    Future<void> collect(Expression<bool> match, {String? Function(RemoteAssetEntityData data)? deviceIdOf}) async {
      for (final entry in await _remoteEntries(userId, match, deviceIdOf: deviceIdOf)) {
        entries.putIfAbsent(entry.asset.remoteId!, () => entry);
      }
    }

    final rae = _db.remoteAssetEntity;
    final exif = _db.remoteExifEntity;
    // The server accepts .insp and .insv uploads only, of all the raw 360° files the app opens
    await collect(
      exif.projectionType.equals(ProjectionType.equirectangular.value) |
          rae.name.lower().like('%.insp') |
          rae.name.lower().like('%.insv') |
          _cameraEquirectPhoto(),
    );
    for (final slice in forcedKeys.slices(chunkSize)) {
      await collect(rae.id.isIn(slice));
    }
    for (final slice in deviceChecksums.keys.slices(chunkSize)) {
      // With the id on the device the scan found 360°, which isEquirectangularProvider looks for
      await collect(
        rae.checksum.isIn(slice) & rae.ownerId.equals(userId),
        deviceIdOf: (data) => deviceChecksums[data.checksum],
      );
    }
    return entries.values.toList(growable: false);
  }

  /// The photos a 360° camera stitched into an equirect picture itself, without the GPano tags that make the server flag
  /// them, by the rule of the viewers (see isEquirectCameraPhoto): 2:1 within 1 percent (the size of the exif, else the
  /// one of the asset), from a GoPro MAX or a DJI 360° camera (Osmo 360, model "oq"). The .36p photos of the GoPro MAX 2
  /// never get here: the server refuses them.
  ///
  /// An Insta360 photo (make "Arashi Vision") only when it is named .jpg, at a small risk taken on purpose: only the
  /// trailer of its file tells a photo the camera stitched from a raw one renamed .jpg, and the database does not hold
  /// it. The phone viewer leaves such a photo flat for that reason until the user views it as 360° (see
  /// hasEquirectCameraExifProvider); the immersive viewer of the 360° page takes it as equirect, right for a photo the
  /// camera stitched, two fisheye circles on the sphere for a renamed raw one.
  Expression<bool> _cameraEquirectPhoto() {
    final rae = _db.remoteAssetEntity;
    final exif = _db.remoteExifEntity;
    final make = exif.make.lower().trim();
    final model = exif.model.lower();
    final width = coalesce([exif.width, rae.width]).cast<double>();
    final height = coalesce([exif.height, rae.height]).cast<double>();
    final isCamera =
        (make.like('%gopro%') & model.like('%max%')) |
        (make.like('%dji%') & (model.like('%360%') | model.like('%oq%'))) |
        (make.equals('arashi vision') & rae.name.lower().like('%.jpg'));
    return rae.type.equalsValue(AssetType.image) &
        isCamera &
        (width / height - const Constant(2.0)).abs().isSmallerOrEqualValue(0.02);
  }

  Future<List<Panorama360Entry>> _remoteEntries(
    String userId,
    Expression<bool> match, {
    String? Function(RemoteAssetEntityData data)? deviceIdOf,
  }) async {
    final rae = _db.remoteAssetEntity;
    final exif = _db.remoteExifEntity;
    final lae = _db.localAssetEntity;
    // The copy on the device, if any, lets the 360° players read the local file. Picked with a correlated subquery,
    // so a photo present in several device albums is not listed twice (#23273).
    final localId = subqueryExpression<String>(
      lae.selectOnly()
        ..addColumns([lae.id])
        ..where(lae.checksum.equalsExp(rae.checksum))
        ..limit(1),
    );
    // The day of the bucket, the same expressions as the timelines for GroupAssetsBy.day
    final day = coalesce([rae.localDateTime.date, rae.createdAt.modify(const DateTimeModifier.localTime()).date]);
    final base =
        rae.deletedAt.isNull() &
        (rae.visibility.equalsValue(AssetVisibility.timeline) | rae.visibility.equalsValue(AssetVisibility.archive)) &
        (rae.stackId.isNull() |
            rae.id.isInQuery(_db.stackEntity.selectOnly()..addColumns([_db.stackEntity.primaryAssetId])));
    final query = rae.select().join([leftOuterJoin(exif, exif.assetId.equalsExp(rae.id), useColumns: false)])
      ..addColumns([localId, day, exif.make, exif.model, exif.projectionType])
      ..where(base & match);

    final rows = await query.get();
    return rows
        .map((row) {
          final data = row.readTable(rae);
          return Panorama360Entry(
            asset: data.toDto(localId: deviceIdOf?.call(data) ?? row.read(localId)),
            day: _dayOf(row.read(day), data.createdAt),
            isOwn: data.ownerId == userId,
            make: row.read(exif.make),
            model: row.read(exif.model),
            flagged: row.read(exif.projectionType) == ProjectionType.equirectangular.value,
          );
        })
        .toList(growable: false);
  }

  /// The device candidates: [ids] (found 360° or forced) that are photos or videos, minus those an own remote asset of
  /// [userId] has the checksum of (none without a server). A device asset whose checksum is not computed yet is listed
  /// as on the device only, the rule of the main timeline.
  Future<List<Panorama360Entry>> loadDevice({required Set<String> ids, String? userId}) async {
    final lae = _db.localAssetEntity;
    final rae = _db.remoteAssetEntity;
    final day = lae.createdAt.modify(const DateTimeModifier.localTime()).date;
    final entries = <Panorama360Entry>[];
    for (final slice in ids.slices(chunkSize)) {
      final query = lae.select().addColumns([day])
        ..where(lae.id.isIn(slice) & (lae.type.equalsValue(AssetType.image) | lae.type.equalsValue(AssetType.video)));
      if (userId != null) {
        query.where(
          notExistsQuery(
            rae.selectOnly()
              ..addColumns([rae.id])
              ..where(rae.checksum.equalsExp(lae.checksum) & rae.ownerId.equals(userId)),
          ),
        );
      }
      for (final row in await query.get()) {
        final data = row.readTable(lae);
        entries.add(Panorama360Entry(asset: data.toDto(), day: _dayOf(row.read(day), data.createdAt)));
      }
    }
    return entries;
  }
}

// The day SQLite gave (local midnight), else the local day of [createdAt]
DateTime _dayOf(String? sqlDay, DateTime createdAt) {
  final parsed = sqlDay == null ? null : DateTime.tryParse(sqlDay);
  if (parsed != null) {
    return DateTime(parsed.year, parsed.month, parsed.day);
  }
  final local = createdAt.toLocal();
  return DateTime(local.year, local.month, local.day);
}
