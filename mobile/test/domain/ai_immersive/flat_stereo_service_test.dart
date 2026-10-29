import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_format.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/services/ai_immersive/stereo_photo_probe.dart';

import '../../test_utils/heif_builder.dart';
import '../../unit/factories/remote_asset_factory.dart';
import 'stereo_photo_fixtures.dart';

void main() {
  late Map<String, RecordingReader> serverFiles;
  late List<String> serverReads;
  late Map<String, File> localFiles;
  late List<String> localLookups;
  late Directory temporary;

  setUp(() {
    serverFiles = {};
    serverReads = [];
    localFiles = {};
    localLookups = [];
    temporary = Directory.systemTemp.createTempSync('flat_stereo_test');
  });

  tearDown(() => temporary.deleteSync(recursive: true));

  FlatStereoService service({int maxEntries = 2000}) => FlatStereoService(
    maxEntries: maxEntries,
    localFile: (localId) async {
      localLookups.add(localId);
      return localFiles[localId];
    },
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
  );

  RemoteAsset remote(String name, {int? width, int? height, String? localId, AssetType type = AssetType.image}) =>
      RemoteAssetFactory.create(name: name, width: width, height: height, localId: localId, type: type);

  test('an ordinary photo is not read at all', () async {
    final asset = remote('IMG_0001.jpg', width: 4000, height: 3000, localId: 'local-1');
    serverFiles[asset.id] = RecordingReader(jpegFile(width: 4000, height: 3000, xmp: ourXmp()));

    expect(FlatStereoService.isCandidate(asset), isFalse);
    expect(await service().detect(asset), isNull);
    expect(serverReads, isEmpty);
    expect(localLookups, isEmpty);
  });

  test('videos are never read', () async {
    final asset = remote('clip_sbs.mp4', width: 3840, height: 1080, type: AssetType.video);

    expect(FlatStereoService.isCandidate(asset), isFalse);
    expect(await service().detect(asset), isNull);
  });

  test('a photo of ours on the server is read by its head, then kept in memory', () async {
    final asset = remote('salon_3D_LRF_Full_SBS.jpg', width: 8000, height: 3000);
    final file = serverFiles[asset.id] = RecordingReader(
      Uint8List.fromList([...jpegFile(width: 8000, height: 3000, xmp: ourXmp()), ...List.filled(300 * 1024, 0)]),
    );
    final stereo = service();

    final found = await stereo.detect(asset);
    expect(found?.isOurs, isTrue);
    expect(found?.eyes, StereoEyes.full);
    expect(file.reads, [(0, 131072)]);
    expect(stereo.cached(asset), found);

    expect(await stereo.detect(asset), found);
    expect(file.reads, hasLength(1), reason: 'answered from memory');
  });

  test('the copy on the device is read first', () async {
    final asset = remote('photo_LRF_Full_SBS.png', localId: 'local-2');
    final copy = File('${temporary.path}/photo_LRF_Full_SBS.png')..writeAsBytesSync(pngFile(width: 8064, height: 3024));
    localFiles['local-2'] = copy;
    serverFiles[asset.id] = RecordingReader(pngFile(width: 4032, height: 3024));

    expect(await service().detect(asset), const FlatStereoPhoto(eyes: StereoEyes.full));
    expect(localLookups, ['local-2']);
    expect(serverReads, isEmpty);
  });

  test('an unreadable copy on the device: the server copy is read', () async {
    final asset = remote('photo_LRF_Full_SBS.png', localId: 'local-3');
    localFiles['local-3'] = File('${temporary.path}/gone.png');
    serverFiles[asset.id] = RecordingReader(pngFile(width: 8064, height: 3024));

    expect(await service().detect(asset), const FlatStereoPhoto(eyes: StereoEyes.full));
    expect(serverReads, hasLength(1));
  });

  test('a candidate found flat is kept flat, without a read more', () async {
    final asset = remote('PANO_0001.jpg', width: 6000, height: 2000);
    final file = serverFiles[asset.id] = RecordingReader(jpegFile(width: 6000, height: 2000));
    final stereo = service();

    expect(await stereo.detect(asset), isNull);
    expect(await stereo.detect(asset), isNull);
    expect(file.reads, hasLength(1));
  });

  test('a photo that cannot be read is read again next time', () async {
    final asset = remote('photo_sbs.jpg', width: 3840, height: 1080);
    final stereo = service();

    expect(await stereo.detect(asset), isNull, reason: 'no server');
    serverFiles[asset.id] = RecordingReader(jpegFile(width: 3840, height: 1080));
    expect(await stereo.detect(asset), const FlatStereoPhoto(eyes: StereoEyes.full));
  });

  test('a read that fails gives null, never an error', () async {
    final asset = remote('photo_sbs.jpg', width: 3840, height: 1080);
    final stereo = FlatStereoService(
      localFile: (_) async => null,
      serverReader: (_) =>
          (offset, length) async => throw const HttpException('Connection reset'),
    );

    expect(await stereo.detect(asset), isNull);
    expect(stereo.cached(asset), isNull);
  });

  test('past maxEntries photos, the one read first is forgotten and read again', () async {
    final assets = [
      for (final name in ['a', 'b', 'c']) remote('${name}_3D_LRF_Full_SBS.jpg', width: 8000, height: 3000),
    ];
    for (final asset in assets) {
      serverFiles[asset.id] = RecordingReader(jpegFile(width: 8000, height: 3000, xmp: ourXmp()));
    }
    final stereo = service(maxEntries: 2);

    for (final asset in assets) {
      expect((await stereo.detect(asset))?.isOurs, isTrue);
    }
    expect(stereo.cached(assets[0]), isNull);
    expect(stereo.cached(assets[1])?.isOurs, isTrue);
    expect(stereo.cached(assets[2])?.isOurs, isTrue);

    expect((await stereo.detect(assets[0]))?.isOurs, isTrue);
    expect(serverReads.where((id) => id == assets[0].id), hasLength(2));
  });

  test('two callers at once share one read', () async {
    final asset = remote('salon_3D_LRF_Full_SBS.jpg');
    final file = serverFiles[asset.id] = RecordingReader(jpegFile(width: 8000, height: 3000, xmp: ourXmp()));
    final stereo = service();

    final results = await Future.wait([stereo.detect(asset), stereo.detect(asset)]);
    expect(results[0]?.isOurs, isTrue);
    expect(results[1], results[0]);
    expect(file.reads, hasLength(1));
  });
}
