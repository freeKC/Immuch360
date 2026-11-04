// The splat photos of the library, told by our packet at the head of their file (plan of 3 November 2026, section 4):
// only the photos named like one are read, 128 KiB of their head, from the copy on the device first, once per session.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/splat/splat_photo_xmp.dart';
import 'package:immich_mobile/domain/services/splat_photo/splat_photo_probe.dart';

import '../../unit/factories/remote_asset_factory.dart';
import 'splat_photo_fixtures.dart';

void main() {
  final carrier = splatPhotoFixture('ok_v2.jpg');
  late Map<String, CountingReader> serverFiles;
  late Map<String, File> localFiles;
  late List<String> localLookups;
  late Directory temporary;

  setUp(() {
    serverFiles = {};
    localFiles = {};
    localLookups = [];
    temporary = Directory.systemTemp.createTempSync('splat_photo_probe');
  });

  tearDown(() => temporary.deleteSync(recursive: true));

  SplatPhotoService service() => SplatPhotoService(
    localFile: (localId) async {
      localLookups.add(localId);
      return localFiles[localId];
    },
    serverReader: (remoteId) => serverFiles[remoteId]?.call,
  );

  RemoteAsset remote(String name, {String? localId, AssetType type = AssetType.image}) =>
      RemoteAssetFactory.create(name: name, localId: localId, type: type, width: 1600, height: 1067);

  Uint8List withTail(Uint8List head) => Uint8List.fromList([...head, ...List.filled(300 * 1024, 0)]);

  test('only an image named like a splat photo is a candidate', () {
    expect(SplatPhotoService.isCandidate(remote('salon_splat.jpg')), isTrue);
    expect(SplatPhotoService.isCandidate(remote('PANO_360_salon_splat.jpg')), isTrue);
    expect(SplatPhotoService.isCandidate(remote('salon_splat.mp4', type: AssetType.video)), isFalse);
    expect(SplatPhotoService.isCandidate(remote('salon.jpg')), isFalse);
  });

  test('a splat photo on the server is read by its 128 KiB head once, then kept in memory', () async {
    final asset = remote('salon_splat.jpg');
    final file = serverFiles[asset.id] = CountingReader(withTail(carrier));
    final photos = service();

    final found = await photos.detect(asset);
    expect(found, isA<SplatPhotoFound>());
    expect((found as SplatPhotoFound).xmp.splatName, 'axes_v2.spz');
    expect(file.reads, 1);
    expect(file.largest, splatPhotoHeadBytes);
    expect(await photos.detect(asset), isA<SplatPhotoFound>());
    expect(file.reads, 1, reason: 'answered from memory');
    expect(photos.known(asset), isA<SplatPhotoFound>());
  });

  test('an ordinary library costs no read: a name without the word splat is never read', () async {
    final photos = service();
    for (final name in ['IMG_0001.jpg', 'salon_scene3D.jpg', 'PANO_0001.jpg', 'splats.jpg']) {
      final asset = remote(name, localId: 'local-$name');
      final file = serverFiles[asset.id] = CountingReader(withTail(carrier));
      expect(await photos.detect(asset), isA<SplatPhotoNone>());
      expect(file.reads, 0, reason: name);
    }
    expect(localLookups, isEmpty);
  });

  test('the copy on the device is read first; the server is not asked', () async {
    final asset = remote('salon_splat.jpg', localId: 'local-1');
    localFiles['local-1'] = File('${temporary.path}/salon_splat.jpg')..writeAsBytesSync(carrier);
    final file = serverFiles[asset.id] = CountingReader(withTail(carrier));

    expect(await service().detect(asset), isA<SplatPhotoFound>());
    expect(localLookups, ['local-1']);
    expect(file.reads, 0);
  });

  test('a photo named like one but holding no packet is told so, and keeps that answer', () async {
    final asset = remote('beach_splat.jpg');
    final file = serverFiles[asset.id] = CountingReader(withTail(splatPhotoFixture('reencoded_plain.jpg')));
    final photos = service();

    expect(await photos.detect(asset), isA<SplatPhotoNone>());
    expect(photos.known(asset), isA<SplatPhotoNone>());
    expect(await photos.detect(asset), isA<SplatPhotoNone>());
    expect(file.reads, 1);
  });

  test('a read that fails is tried again next time', () async {
    final asset = remote('salon_splat.jpg');
    final photos = service();

    expect(await photos.detect(asset), isA<SplatPhotoUnread>(), reason: 'no server');
    expect(photos.known(asset), isA<SplatPhotoUnread>());
    serverFiles[asset.id] = CountingReader(withTail(carrier));
    expect(await photos.detect(asset), isA<SplatPhotoFound>());
  });

  test('two looks at once share one read', () async {
    final asset = remote('salon_splat.jpg');
    final file = serverFiles[asset.id] = CountingReader(withTail(carrier));
    final photos = service();

    final both = await Future.wait([photos.detect(asset), photos.detect(asset)]);
    expect(both.every((probe) => probe is SplatPhotoFound), isTrue);
    expect(file.reads, 1);
  });

  test('the last 2,000 photos are remembered', () async {
    final photos = SplatPhotoService(
      localFile: (_) async => null,
      serverReader: (remoteId) => serverFiles[remoteId]?.call,
      maxEntries: 2,
    );
    final assets = [for (var i = 0; i < 3; i++) remote('salon_${i}_splat.jpg')];
    for (final asset in assets) {
      serverFiles[asset.id] = CountingReader(withTail(carrier));
      await photos.detect(asset);
    }
    expect(photos.known(assets.first), isA<SplatPhotoUnread>(), reason: 'forgotten');
    expect(photos.known(assets.last), isA<SplatPhotoFound>());
  });

  test('the original of the server is read without the edited parameter: an edit is a copy without the scene', () {
    final uri = splatPhotoOriginalUri('https://media.example/api', 'abc-123');
    expect(uri.toString(), 'https://media.example/api/assets/abc-123/original');
    expect(uri.queryParameters, isEmpty);
  });
}
