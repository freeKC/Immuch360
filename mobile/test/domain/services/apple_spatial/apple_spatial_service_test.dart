import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/apple_spatial.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/services/apple_spatial/apple_spatial.service.dart';
import 'package:immich_mobile/domain/services/apple_spatial/heic_stereo_probe.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';

import '../../../test_utils/heif_builder.dart';
import '../../../unit/factories/local_asset_factory.dart';
import '../../../unit/factories/remote_asset_factory.dart';

void main() {
  late Uint8List spatialPhoto;
  late Uint8List flatPhoto;
  late Map<String, RecordingReader> serverFiles;
  late List<String> serverReads;
  late Map<String, File> localFiles;
  late Map<String, SphericalProbe?> videoProbes;
  late List<BaseAsset> probed;
  String? store;
  late List<String> writes;
  late Directory temporary;

  setUp(() {
    spatialPhoto = spatialPhotoBuilder().build();
    flatPhoto = HeifBuilder(
      items: const [
        HeifItem(1, 'hvc1', properties: [1]),
      ],
      properties: [heifIspe(4032, 3024)],
    ).build();
    serverFiles = {};
    serverReads = [];
    localFiles = {};
    videoProbes = {};
    probed = [];
    store = null;
    writes = [];
    temporary = Directory.systemTemp.createTempSync('apple_spatial_test');
  });

  tearDown(() => temporary.deleteSync(recursive: true));

  AppleSpatialService service({int maxEntries = 2000}) => AppleSpatialService(
    localFile: (localId) async => localFiles[localId],
    serverReader: (remoteId) {
      final file = serverFiles[remoteId];
      if (file == null) {
        return null;
      }
      return (offset, length) {
        serverReads.add(remoteId);
        return file.call(offset, length);
      };
    },
    probeVideo: (asset) async {
      probed.add(asset);
      return videoProbes[asset.name];
    },
    readCache: () => store,
    writeCache: (json) async {
      store = json;
      writes.add(json);
    },
    maxEntries: maxEntries,
  );

  RemoteAsset remote(String name, {AssetType type = AssetType.image, String? localId}) =>
      RemoteAssetFactory.create(name: name, type: type, localId: localId);

  group('candidates', () {
    test('HEIF photos and videos only', () {
      expect(AppleSpatialService.isCandidate(remote('IMG_0001.HEIC')), isTrue);
      expect(AppleSpatialService.isCandidate(remote('IMG_0001.heif')), isTrue);
      expect(AppleSpatialService.isCandidate(remote('IMG_0001.hif')), isTrue);
      expect(AppleSpatialService.isCandidate(remote('IMG_0001.MOV', type: AssetType.video)), isTrue);
      expect(AppleSpatialService.isCandidate(remote('IMG_0001.jpg')), isFalse);
      expect(AppleSpatialService.isCandidate(remote('IMG_0001.heic.png')), isFalse);
    });

    test('any other photo is not read', () async {
      final asset = remote('IMG_0001.jpg');
      serverFiles[asset.id] = RecordingReader(spatialPhoto);

      expect(await service().detect(asset), isNull);
      expect(serverReads, isEmpty);
      expect(writes, isEmpty);
    });
  });

  group('photos', () {
    test('a spatial photo on the server is read by its head, then kept', () async {
      final asset = remote('IMG_0002.HEIC');
      final file = serverFiles[asset.id] = RecordingReader(spatialPhoto);
      final spatial = service();

      final info = await spatial.detect(asset);
      expect(info?.kind, AppleSpatialKind.stereoPhoto);
      expect(info?.photo?.rightItemId, 20);
      expect(file.reads, [(0, heicStereoHeadLength)]);
      expect(spatial.cached(asset), info);

      // Read once: the next detect answers from memory
      expect(await spatial.detect(asset), info);
      expect(file.reads, hasLength(1));

      final kept = jsonDecode(store!) as Map<String, dynamic>;
      expect(kept.keys, [appleSpatialCacheKey(asset)]);
      expect(kept.values.single['k'], 'photo');
      expect(kept.values.single['p']['rightItemId'], 20);
    });

    test('the store answers after a restart, without reading the file', () async {
      final asset = remote('IMG_0003.HEIC');
      serverFiles[asset.id] = RecordingReader(spatialPhoto);
      final first = await service().detect(asset);

      serverReads.clear();
      final second = await service().detect(asset);
      // The field of view is kept to the hundredth of a degree, as the viewer gets it
      expect(second?.kind, AppleSpatialKind.stereoPhoto);
      expect(second?.photo?.toImmersiveMap(), first?.photo?.toImmersiveMap());
      expect(serverReads, isEmpty);
    });

    test('a flat HEIF photo is kept as none', () async {
      final asset = remote('IMG_0004.HEIC');
      serverFiles[asset.id] = RecordingReader(flatPhoto);
      final spatial = service();

      expect(await spatial.detect(asset), isNull);
      expect((jsonDecode(store!) as Map).values.single, {'k': 'none'});

      serverReads.clear();
      expect(await service().detect(asset), isNull);
      expect(serverReads, isEmpty, reason: 'known flat, not read again');
    });

    test('a photo that could not be read is not kept, and read again', () async {
      final asset = remote('IMG_0005.HEIC');
      final spatial = service();

      // No server
      expect(await spatial.detect(asset), isNull);
      expect(writes, isEmpty);

      serverFiles[asset.id] = RecordingReader(spatialPhoto);
      expect((await spatial.detect(asset))?.kind, AppleSpatialKind.stereoPhoto);
    });

    test('the copy on the device is read rather than the server one', () async {
      final asset = remote('IMG_0006.HEIC', localId: 'local-6');
      serverFiles[asset.id] = RecordingReader(flatPhoto);
      final file = File('${temporary.path}/IMG_0006.HEIC')..writeAsBytesSync(spatialPhoto);
      localFiles['local-6'] = file;

      expect((await service().detect(asset))?.kind, AppleSpatialKind.stereoPhoto);
      expect(serverReads, isEmpty);
    });

    test('a photo only on the device is known by its local id and its date', () async {
      final asset = LocalAssetFactory.create(name: 'IMG_0007.HEIC');
      localFiles[asset.id] = File('${temporary.path}/IMG_0007.HEIC')..writeAsBytesSync(spatialPhoto);

      expect((await service().detect(asset))?.kind, AppleSpatialKind.stereoPhoto);
      expect((jsonDecode(store!) as Map).keys.single, 'l:${asset.id}:${asset.updatedAt.millisecondsSinceEpoch}');
    });

    test('readers asking at once share one read', () async {
      final asset = remote('IMG_0008.HEIC');
      final file = serverFiles[asset.id] = RecordingReader(spatialPhoto);
      final spatial = service();

      final results = await Future.wait([spatial.detect(asset), spatial.detect(asset)]);
      expect(results[0], results[1]);
      expect(file.reads, hasLength(1));
    });

    test('the store keeps the latest media, at most maxEntries', () async {
      final spatial = service(maxEntries: 3);
      final assets = [for (var i = 0; i < 5; i++) remote('IMG_10$i.HEIC')];
      for (final asset in assets) {
        serverFiles[asset.id] = RecordingReader(flatPhoto);
        await spatial.detect(asset);
      }

      final kept = (jsonDecode(store!) as Map).keys.toList();
      expect(kept, [for (final asset in assets.skip(2)) appleSpatialCacheKey(asset)]);
    });

    test('a damaged store is read as empty', () async {
      store = '{not json';
      final asset = remote('IMG_0009.HEIC');
      serverFiles[asset.id] = RecordingReader(spatialPhoto);

      expect((await service().detect(asset))?.kind, AppleSpatialKind.stereoPhoto);
    });
  });

  group('videos', () {
    test('a spatial video is what its probe says, and is kept', () async {
      final asset = remote('IMG_0100.MOV', type: AssetType.video);
      videoProbes[asset.name] = const SphericalProbe(
        codec: 'hvc1',
        multiview: MultiviewInfo(heroEye: 1, baselineMicrometres: 19240, horizontalFovDegrees: 63.4),
      );

      final info = await service().detect(asset);
      expect(
        info,
        const AppleSpatialInfo.video(MultiviewInfo(heroEye: 1, baselineMicrometres: 19240, horizontalFovDegrees: 63.4)),
      );

      // From the store after a restart
      probed.clear();
      expect(await service().detect(asset), info);
      expect(probed, isEmpty);
    });

    test('a plain video is none, a video whose probe failed is read again', () async {
      final plain = remote('IMG_0101.MOV', type: AssetType.video);
      final failed = remote('IMG_0102.MOV', type: AssetType.video);
      videoProbes[plain.name] = const SphericalProbe(codec: 'hvc1');
      final spatial = service();

      expect(await spatial.detect(plain), isNull);
      expect(await spatial.detect(failed), isNull);
      expect((jsonDecode(store!) as Map).keys, [appleSpatialCacheKey(plain)]);
    });

    test('the 2D notice is taken once per video', () {
      final spatial = service();
      final asset = remote('IMG_0103.MOV', type: AssetType.video);

      expect(spatial.takeVideoNotice(asset), isTrue);
      expect(spatial.takeVideoNotice(asset), isFalse);
      expect(spatial.takeVideoNotice(remote('IMG_0104.MOV', type: AssetType.video)), isTrue);
    });
  });

  group('cache entries', () {
    test('survive their JSON form', () {
      const photo = AppleSpatialInfo.photo(
        HeicStereoPair(
          primaryItemId: 1,
          leftItemId: 1,
          rightItemId: 2,
          pitmIdOffset: 129,
          pitmIdBytes: 2,
          width: 3072,
          height: 3072,
          disparityAdjustment: -1000,
          horizontalFovDegrees: 59.98,
        ),
      );
      const video = AppleSpatialInfo.video(
        MultiviewInfo(heroEye: 2, baselineMicrometres: 64000, disparityAdjustment: 200, eyesReversed: true),
      );
      for (final info in [photo, video, null]) {
        final decoded = decodeAppleSpatialEntry(jsonDecode(jsonEncode(encodeAppleSpatialEntry(info))));
        expect(decoded, isNotNull);
        expect(decoded!.info, info);
      }
      expect(decodeAppleSpatialEntry({'k': 'other'}), isNull);
      expect(decodeAppleSpatialEntry('photo'), isNull);
    });
  });
}
