// A gallery in memory and files on disk for the tests of the phone share: no device, no database.

import 'dart:io';

import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/services/phone_share/phone_gallery_tree.dart';
import 'package:immich_mobile/platform/phone_share_api.g.dart';

LocalAsset galleryAsset(String id, String name, {AssetType type = AssetType.image, required DateTime createdAt}) =>
    LocalAsset(
      id: id,
      name: name,
      type: type,
      createdAt: createdAt,
      updatedAt: createdAt,
      playbackStyle: type == AssetType.video ? AssetPlaybackStyle.video : AssetPlaybackStyle.image,
      isEdited: false,
    );

LocalAlbum galleryAlbum(String id, String name) => LocalAlbum(id: id, name: name, updatedAt: DateTime.utc(2026, 9, 1));

/// Albums and assets in memory; [calls] records what the tree asked
class FakePhoneGallery implements PhoneGallerySource {
  final List<LocalAlbum> albumList = [];
  final Map<String, List<LocalAsset>> assetsByAlbum = {};
  final List<LocalAsset> assets = [];
  final List<String> calls = [];

  void add(LocalAsset asset, {List<String> albums = const []}) {
    assets.add(asset);
    for (final album in albums) {
      assetsByAlbum.putIfAbsent(album, () => []).add(asset);
    }
  }

  @override
  Future<List<LocalAlbum>> albums() async {
    calls.add('albums');
    return albumList;
  }

  @override
  Future<List<LocalAsset>> albumAssets(String albumId) async {
    calls.add('albumAssets $albumId');
    return assetsByAlbum[albumId] ?? const [];
  }

  @override
  Future<List<({int year, int month, int count})>> months() async {
    calls.add('months');
    final counts = <(int, int), int>{};
    for (final asset in assets) {
      final local = asset.createdAt.toLocal();
      counts.update((local.year, local.month), (count) => count + 1, ifAbsent: () => 1);
    }
    final months = [for (final MapEntry(:key, :value) in counts.entries) (year: key.$1, month: key.$2, count: value)];
    months.sort((a, b) => (b.year * 100 + b.month).compareTo(a.year * 100 + a.month));
    return months;
  }

  @override
  Future<List<LocalAsset>> monthAssets(int year, int month) async {
    calls.add('monthAssets $year-$month');
    return [
      for (final asset in assets)
        if (asset.createdAt.toLocal().year == year && asset.createdAt.toLocal().month == month) asset,
    ]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  @override
  Future<List<LocalAsset>> assetsByIds(Iterable<String> ids) async {
    calls.add('assetsByIds');
    final wanted = ids.toSet();
    return [
      for (final asset in assets)
        if (wanted.contains(asset.id)) asset,
    ];
  }
}

/// The files of the assets: real files on disk, with what the platform would tell of them
class FakePhoneShareFiles implements PhoneShareFiles {
  final Map<String, ({File file, String mimeType, String fileName, int modifiedMs})> files = {};
  final List<List<String>> infoCalls = [];
  final List<String> openCalls = [];

  /// When set, the size the platform tells for every file (0: it does not tell)
  int? toldSize;

  void add(String assetId, File file, {required String mimeType, String? fileName, int modifiedMs = 1757000000000}) {
    files[assetId] = (
      file: file,
      mimeType: mimeType,
      fileName: fileName ?? file.uri.pathSegments.last,
      modifiedMs: modifiedMs,
    );
  }

  @override
  Future<List<PhoneShareFileInfo>> fileInfos(List<String> assetIds) async {
    infoCalls.add(assetIds);
    return [
      for (final id in assetIds)
        if (files[id] case final known? when known.file.existsSync())
          PhoneShareFileInfo(
            assetId: id,
            size: toldSize ?? known.file.lengthSync(),
            mimeType: known.mimeType,
            fileName: known.fileName,
            modifiedMs: known.modifiedMs,
          ),
    ];
  }

  @override
  Future<PhoneShareOpenedFile?> openFile(String assetId) async {
    openCalls.add(assetId);
    final known = files[assetId];
    if (known == null) {
      return null;
    }
    return PhoneShareOpenedFile(path: known.file.path, size: known.file.lengthSync(), isTemporary: false);
  }
}

/// Bytes that differ from one offset to the next, so that a range read at the wrong place shows
List<int> patternBytes(int length, {int seed = 0}) => List.generate(length, (i) => (i * 31 + seed + (i >> 8)) & 0xff);
