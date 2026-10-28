// A photo that carries a 3D scene, told by our packet at the head of its file (design-final 2026-10-27, sections 8.2
// and 8.3): only the photos named like one are read, from the copy on the device first, then kept in memory; the
// photos of the shares say it with their GPano read, without a read more.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/ai_immersive/immersive_xmp.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/services/ai_immersive/scene_photo_probe.dart';
import 'package:immich_mobile/domain/services/network_media.service.dart';

import '../../test_utils/heif_builder.dart';
import '../../unit/factories/remote_asset_factory.dart';
import 'stereo_photo_fixtures.dart';

void main() {
  // The photo that carries a scene of the fixtures, made by make_scene_fixture.py
  final tiny = File('test/fixtures/ai_immersive/tiny_scene3D.jpg').readAsBytesSync();
  late Map<String, RecordingReader> serverFiles;
  late Map<String, File> localFiles;
  late List<String> localLookups;
  late Directory temporary;

  setUp(() {
    serverFiles = {};
    localFiles = {};
    localLookups = [];
    temporary = Directory.systemTemp.createTempSync('scene_photo_test');
  });

  tearDown(() => temporary.deleteSync(recursive: true));

  ScenePhotoService service() => ScenePhotoService(
    localFile: (localId) async {
      localLookups.add(localId);
      return localFiles[localId];
    },
    serverReader: (remoteId) => serverFiles[remoteId]?.call,
  );

  RemoteAsset remote(String name, {String? localId, AssetType type = AssetType.image}) =>
      RemoteAssetFactory.create(name: name, localId: localId, type: type, width: 32, height: 24);

  test('a photo named like a scene is a candidate, whatever the case, the counter and the extension', () {
    for (final name in ['salon_scene3D.jpg', 'SALON_SCENE3D.JPG', 'salon_scene3D (2).jpg', 'a-b_scene3D.jpeg']) {
      expect(isScenePhotoCandidate(name), isTrue, reason: name);
    }
    for (final name in ['salon.jpg', 'salon_3D_LRF_Full_SBS.jpg', 'salon_scene3Dx.jpg', 'scene3dish.jpg']) {
      expect(isScenePhotoCandidate(name), isFalse, reason: name);
    }
    expect(ScenePhotoService.isCandidate(remote('clip_scene3D.mp4', type: AssetType.video)), isFalse);
  });

  test('our packet of a scene in the head says the request, another packet of ours says nothing', () {
    final scene = sceneXmpOfHead(Uint8List.sublistView(tiny, 0, tiny.length));

    expect(scene, isNotNull);
    expect(scene!.request?.triangles, 10);
    expect(scene.hiddenFraction, 0.05);
    expect(sceneXmpOfHead(jpegFile(width: 8000, height: 3000, xmp: ourXmp())), isNull);
    expect(sceneXmpOfHead(jpegFile(width: 4000, height: 3000)), isNull);
  });

  test('a scene on the server is read by its head once, then kept in memory', () async {
    final asset = remote('salon_scene3D.jpg');
    final file = serverFiles[asset.id] = RecordingReader(
      Uint8List.fromList([...tiny, ...List.filled(200 * 1024, 0)]),
    );
    final scenes = service();

    final found = await scenes.detect(asset);
    expect(found?.sceneTriangles, 10);
    expect(file.reads, [(0, scenePhotoHeadLength)]);
    expect(await scenes.detect(asset), found);
    expect(file.reads, hasLength(1), reason: 'answered from memory');
  });

  test('the copy on the device is read first, and an ordinary photo not at all', () async {
    final asset = remote('salon_scene3D.jpg', localId: 'local-1');
    localFiles['local-1'] = File('${temporary.path}/salon_scene3D.jpg')..writeAsBytesSync(tiny);
    final server = serverFiles[asset.id] = RecordingReader(tiny);

    expect((await service().detect(asset))?.sceneMeshes, 2);
    expect(localLookups, ['local-1']);
    expect(server.reads, isEmpty);

    final ordinary = remote('salon.jpg', localId: 'local-2');
    expect(await service().detect(ordinary), isNull);
    expect(localLookups, ['local-1'], reason: 'an ordinary photo costs no read');
  });

  test('a photo named like a scene without one is kept as none, one that cannot be read is read again', () async {
    final renamed = remote('holiday_scene3D.jpg');
    final file = serverFiles[renamed.id] = RecordingReader(jpegFile(width: 4000, height: 3000));
    final scenes = service();
    expect(await scenes.detect(renamed), isNull);
    expect(await scenes.detect(renamed), isNull);
    expect(file.reads, hasLength(1));

    final later = remote('later_scene3D.jpg');
    expect(await scenes.detect(later), isNull, reason: 'no server yet');
    serverFiles[later.id] = RecordingReader(tiny);
    expect(await scenes.detect(later), isA<SceneXmp>());
  });

  test('a read that fails gives null, never an error', () async {
    final failing = ScenePhotoService(
      localFile: (_) async => null,
      serverReader: (_) =>
          (offset, length) async => throw const HttpException('Connection reset'),
    );

    expect(await failing.detect(remote('salon_scene3D.jpg')), isNull);
  });

  test('a scene on a share is told with its GPano read, without a read more', () async {
    final file = Uint8List.fromList([...tiny, ...List.filled(300 * 1024, 0)]);
    final reader = RecordingReader(file);
    final entry = NetworkEntry(
      sourceId: 'nas',
      path: '/Photos/salon_scene3D.jpg',
      isDirectory: false,
      size: file.length,
      modified: DateTime.utc(2026, 10, 28),
    );

    final info = await NetworkMediaService().detect(entry, reader.call);
    expect(info?.scene?.sceneTriangles, 10);
    expect(info?.is360, isFalse);
    expect(info?.stereoPhoto, isNull);
    expect(reader.reads, [(0, 131072), (file.length - 131072, 131072)]);

    final ordinary = await NetworkMediaService().detect(
      const NetworkEntry(sourceId: 'nas', path: '/Photos/salon.jpg', isDirectory: false, size: 4096),
      RecordingReader(jpegFile(width: 4000, height: 3000)).call,
    );
    expect(ordinary?.scene, isNull);
  });
}
