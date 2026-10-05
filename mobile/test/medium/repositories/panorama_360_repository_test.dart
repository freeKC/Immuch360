import 'package:drift/drift.dart' hide isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/table/remote/asset.drift.dart';
import 'package:immich_mobile/data/db/main/table/remote/exif.drift.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/panorama_360.model.dart';
import 'package:immich_mobile/infrastructure/repositories/panorama_360.repository.dart';
import 'package:immich_mobile/utils/option.dart';

import '../repository_context.dart';

void main() {
  late MediumRepositoryContext ctx;
  late Panorama360Repository sut;
  late String userId;
  late String partnerId;

  setUp(() async {
    ctx = MediumRepositoryContext();
    sut = Panorama360Repository(ctx.db);
    userId = (await ctx.newUser()).id;
    partnerId = (await ctx.newUser()).id;
  });

  tearDown(() async {
    await ctx.dispose();
  });

  Future<RemoteAssetEntityData> newAsset({
    String? projectionType,
    bool withExif = true,
    String? ownerId,
    String? name,
    AssetType type = .image,
    AssetVisibility visibility = .timeline,
    DateTime? createdAt,
    DateTime? localDateTime,
    DateTime? deletedAt,
    String? checksum,
    String? stackId,
    String? make,
    String? model,
    int? width,
    int? height,
    int? exifWidth,
    int? exifHeight,
  }) async {
    final asset = await ctx.newRemoteAsset(
      ownerId: ownerId ?? userId,
      name: name,
      type: type,
      visibility: visibility,
      createdAt: createdAt,
      localDateTime: localDateTime,
      deletedAt: deletedAt,
      checksum: checksum,
      stackId: stackId,
      width: width,
      height: height,
    );
    if (withExif) {
      await ctx.newRemoteExif(assetId: asset.id, projectionType: projectionType, make: make, model: model);
      await (ctx.db.update(ctx.db.remoteExifEntity)..where((row) => row.assetId.equals(asset.id))).write(
        RemoteExifEntityCompanion(width: Value(exifWidth), height: Value(exifHeight)),
      );
    }
    return asset;
  }

  Future<List<Panorama360Entry>> loadRemote({Set<String> forcedKeys = const {}, Set<String> deviceIds = const {}}) =>
      sut.loadRemote(userId: userId, forcedKeys: forcedKeys, deviceIds: deviceIds);

  Future<List<String>> listedIds({Set<String> forcedKeys = const {}, Set<String> deviceIds = const {}}) async =>
      (await loadRemote(forcedKeys: forcedKeys, deviceIds: deviceIds)).map((entry) => entry.asset.remoteId!).toList();

  group('loadRemote', () {
    test('lists equirectangular photos and videos and nothing else', () async {
      final photo = await newAsset(projectionType: 'EQUIRECTANGULAR');
      final video = await newAsset(projectionType: 'EQUIRECTANGULAR', type: .video);
      await newAsset();
      await newAsset(withExif: false);
      await newAsset(projectionType: 'CUBEMAP');
      await newAsset(projectionType: 'EQUIRECTANGULAR_STEREO');
      await newAsset(projectionType: 'NONE', type: .video);

      final entries = await loadRemote();

      expect(entries.map((entry) => entry.asset.remoteId), unorderedEquals([photo.id, video.id]));
      expect(entries.firstWhere((entry) => entry.asset.remoteId == video.id).asset.isVideo, isTrue);
      expect(entries.every((entry) => entry.flagged && entry.isOwn), isTrue);
      expect(entries.every((entry) => entry.asset is RemoteAsset), isTrue);
    });

    test('keeps archived assets and leaves out trashed, locked and hidden ones', () async {
      final archived = await newAsset(projectionType: 'EQUIRECTANGULAR', visibility: .archive);
      await newAsset(projectionType: 'EQUIRECTANGULAR', deletedAt: DateTime.utc(2024, 9, 5));
      await newAsset(projectionType: 'EQUIRECTANGULAR', visibility: .locked);
      await newAsset(projectionType: 'EQUIRECTANGULAR', visibility: .hidden);
      final partner = await newAsset(projectionType: 'EQUIRECTANGULAR', ownerId: partnerId);

      final entries = await loadRemote();

      expect(entries.map((entry) => entry.asset.remoteId), unorderedEquals([archived.id, partner.id]));
      expect(entries.firstWhere((entry) => entry.asset.remoteId == archived.id).isOwn, isTrue);
      expect(entries.firstWhere((entry) => entry.asset.remoteId == partner.id).isOwn, isFalse);
    });

    test('shows only the primary asset of a stack', () async {
      final primary = await newAsset(projectionType: 'EQUIRECTANGULAR', stackId: 'stack-1');
      await newAsset(projectionType: 'EQUIRECTANGULAR', stackId: 'stack-1');
      await ctx.newStack(id: 'stack-1', ownerId: userId, primaryAssetId: primary.id);

      expect(await listedIds(), [primary.id]);
    });

    test('resolves the copy on the device without listing the asset twice', () async {
      const checksum = 'panorama-checksum';
      final asset = await newAsset(projectionType: 'EQUIRECTANGULAR', type: .video, checksum: checksum);
      final local1 = await ctx.newLocalAsset(checksum: checksum);
      final local2 = await ctx.newLocalAsset(checksum: checksum);

      final entries = await loadRemote();

      expect(entries, hasLength(1));
      final remote = entries.single.asset as RemoteAsset;
      expect(remote.id, asset.id);
      expect([local1.id, local2.id], contains(remote.localId));
    });

    test('gives the day of the bucket: the local date time when set, else the creation date in local time', () async {
      final shifted = await newAsset(
        projectionType: 'EQUIRECTANGULAR',
        createdAt: DateTime.utc(2024, 9, 2, 12),
        localDateTime: DateTime.utc(2024, 9, 3, 12),
      );
      final createdAt = DateTime.utc(2024, 9, 5, 12);
      final withoutLocalDate = await newAsset(projectionType: 'EQUIRECTANGULAR', createdAt: createdAt);
      await (ctx.db.update(ctx.db.remoteAssetEntity)..where((row) => row.id.equals(withoutLocalDate.id))).write(
        const RemoteAssetEntityCompanion(localDateTime: Value(null)),
      );

      final entries = await loadRemote();
      DateTime dayOf(String id) => entries.firstWhere((entry) => entry.asset.remoteId == id).day;

      expect(dayOf(shifted.id), DateTime(2024, 9, 3));
      final local = createdAt.toLocal();
      expect(dayOf(withoutLocalDate.id), DateTime(local.year, local.month, local.day));
      expect(dayOf(shifted.id).isUtc, isFalse, reason: 'a local midnight, as the buckets have it');
    });

    test('lists the raw Insta360 files by name, in any case', () async {
      final video = await newAsset(name: 'VID_1.insv', type: .video, withExif: false);
      final photo = await newAsset(name: 'IMG_1.INSP');
      await newAsset(name: 'VID_1.mp4', type: .video);

      final entries = await loadRemote();

      expect(entries.map((entry) => entry.asset.remoteId), unorderedEquals([video.id, photo.id]));
      expect(entries.any((entry) => entry.flagged), isFalse);
    });

    test('lists the 2:1 photos of 360° cameras without GPano tags, an Insta360 one only named .jpg', () async {
      Future<RemoteAssetEntityData> camera(
        String make,
        String model, {
        String? name,
        AssetType type = .image,
        int width = 5760,
        int height = 2880,
        bool sizeInExif = true,
      }) => newAsset(
        name: name,
        type: type,
        make: make,
        model: model,
        // The asset of a size of its own, so that the size of the exif tells when there is one
        width: sizeInExif ? 1000 : width,
        height: sizeInExif ? 1000 : height,
        exifWidth: sizeInExif ? width : null,
        exifHeight: sizeInExif ? height : null,
      );
      final goPro = await camera('GoPro', 'GoPro Max');
      final osmo = await camera('DJI', 'Osmo 360', width: 15520, height: 7760);
      final oq = await camera(' dji ', 'OQ001', width: 7680, height: 3840);
      final insta360 = await camera('Arashi Vision', 'Insta360 X4', name: 'IMG_20240101_120000_00_001.JPG');
      final assetSize = await camera('GoPro', 'GoPro Max', sizeInExif: false);
      await camera('DJI', 'Osmo 360', width: 6400, height: 4800);
      await camera('DJI', 'Mini 4 Pro', width: 8064, height: 4032);
      await camera('Apple', 'iPhone 15', width: 8000, height: 4000);
      await camera('GoPro', 'GoPro Max', type: .video);
      await camera('Arashi Vision', 'Insta360 X4', name: 'IMG_20240101_120000_00_002.dng');
      await camera('Arashi Vision', 'Insta360 X4', name: 'IMG_20240101_120000_00_003.jpg', width: 4000, height: 3000);

      final entries = await loadRemote();

      expect(
        entries.map((entry) => entry.asset.remoteId),
        unorderedEquals([goPro.id, osmo.id, oq.id, insta360.id, assetSize.id]),
      );
      expect(entries.any((entry) => entry.flagged), isFalse);
    });

    test('lists a forced asset by its server id, in slices', () async {
      final first = await newAsset();
      final second = await newAsset(withExif: false, ownerId: partnerId);
      await newAsset();
      final forcedKeys = {
        for (var index = 0; index < 1200; index++) 'missing-$index',
        first.id,
        'local-id-of-something',
        second.id,
      };
      expect(forcedKeys.length, greaterThan(2 * Panorama360Repository.chunkSize));

      expect(await listedIds(forcedKeys: forcedKeys), unorderedEquals([first.id, second.id]));
    });

    test('lists an own asset whose checksum is the one of a device asset found 360°, with that device id', () async {
      const checksum = 'found-on-device';
      final own = await newAsset(checksum: checksum);
      await newAsset(checksum: checksum, ownerId: partnerId);
      final local = await ctx.newLocalAsset(id: 'L1', checksum: checksum);
      await ctx.newLocalAsset(id: 'L0', checksum: checksum);

      final entries = await loadRemote(deviceIds: {local.id});

      expect(entries, hasLength(1));
      final asset = entries.single.asset as RemoteAsset;
      expect(asset.id, own.id);
      expect(asset.localId, 'L1');
      expect(entries.single.flagged, isFalse);
      expect(await loadRemote(), isEmpty);
    });

    test('reads the make and the model of the exif', () async {
      await newAsset(projectionType: 'EQUIRECTANGULAR', make: 'Arashi Vision', model: 'Insta360 X3');

      final entry = (await loadRemote()).single;

      expect(entry.make, 'Arashi Vision');
      expect(entry.model, 'Insta360 X3');
      expect(entry.camera, (key: 'insta360 x3', label: 'Insta360 X3'));
    });
  });

  group('loadDevice', () {
    test('lists the found and forced device assets that are not uploaded', () async {
      final uploaded = await ctx.newLocalAsset(id: 'L1', checksum: 'c1');
      await newAsset(checksum: 'c1');
      final sharedOnly = await ctx.newLocalAsset(id: 'L2', checksum: 'c2', type: .video);
      await newAsset(checksum: 'c2', ownerId: partnerId);
      final withoutChecksum = await ctx.newLocalAsset(id: 'L3', checksumOption: const Option.none());
      await ctx.newLocalAsset(id: 'L4', type: .audio);
      await ctx.newLocalAsset(id: 'L5');
      final ids = {uploaded.id, sharedOnly.id, withoutChecksum.id, 'L4', 'gone-from-the-device'};

      final entries = await sut.loadDevice(ids: ids, userId: userId);

      expect(entries.map((entry) => entry.asset.localId), unorderedEquals(['L2', 'L3']));
      expect(entries.every((entry) => entry.asset is LocalAsset && entry.isOwn), isTrue);
      expect(entries.firstWhere((entry) => entry.asset.localId == 'L2').asset.isVideo, isTrue);

      final withoutServer = await sut.loadDevice(ids: ids);
      expect(withoutServer.map((entry) => entry.asset.localId), unorderedEquals(['L1', 'L2', 'L3']));
    });

    test('gives the day of the bucket in local time, in slices', () async {
      final createdAt = DateTime.utc(2024, 9, 14, 12);
      final asset = await ctx.newLocalAsset(createdAt: createdAt);
      final ids = {for (var index = 0; index < 1100; index++) 'missing-$index', asset.id};

      final entries = await sut.loadDevice(ids: ids);

      final local = createdAt.toLocal();
      expect(entries.single.day, DateTime(local.year, local.month, local.day));
    });

    test('is empty for no id', () async {
      await ctx.newLocalAsset();

      expect(await sut.loadDevice(ids: const {}), isEmpty);
    });
  });

  group('watchChanges', () {
    test('tells of a change of the exif table', () async {
      final asset = await newAsset(withExif: false);
      final change = expectLater(sut.watchChanges().first, completes);
      await Future<void>.delayed(Duration.zero);

      await ctx.newRemoteExif(assetId: asset.id, projectionType: 'EQUIRECTANGULAR');

      await change;
    });

    test('tells of a change of the assets of the device', () async {
      final change = expectLater(sut.watchChanges().first, completes);
      await Future<void>.delayed(Duration.zero);

      await ctx.newLocalAsset();

      await change;
    });
  });
}
