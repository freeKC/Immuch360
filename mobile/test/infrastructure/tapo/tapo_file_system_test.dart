// The file system of a camera with the fake camera and the fake media port: opening does no I/O, the days are folders
// and the clips files, a clip not fetched is not found (the bridge never waits on the camera), a fetch writes a
// QuickTime file whole or not at all, with its progress, through the busy answers, until a cancel (which tells the
// camera "do stop"); the pictures of the event recordings, kept on disk; the media port only after a login through the
// pinned certificate; the cache.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/tapo_camera_info.dart';
import 'package:immich_mobile/domain/services/network_file_system.dart';
import 'package:immich_mobile/domain/services/spherical_probe.dart';
import 'package:immich_mobile/domain/services/tapo_camera.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_clip_cache.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_control_client.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_crypto.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_file_system.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_login.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_media_worker.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_session_cache.dart';
import 'package:timezone/data/latest.dart';

import 'fake_streamd.dart';
import 'fake_tapo_camera.dart';
import 'tapo_test_streams.dart';

const _password = 'synthetic-cloud-password';
const _sourceId = '0123456789abcdef';

void main() {
  setUpAll(initializeTimeZones);

  late Directory root;
  late FakeStreamd streamd;
  late FakeTapoCamera camera;
  late TapoSessionCache cache;
  late TapoMediaWorker worker;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('immuch360-tapo-fs');
    streamd = await FakeStreamd.start();
    camera = FakeTapoCamera();
    cache = TapoSessionCache();
    worker = TapoMediaWorker(
      busyDelays: const [Duration(milliseconds: 50), Duration(milliseconds: 50), Duration(milliseconds: 50)],
      pauseAfterClip: const Duration(milliseconds: 10),
      pauseAfterFailedBatch: const Duration(milliseconds: 10),
    );
  });

  tearDown(() async {
    await streamd.close();
    await root.delete(recursive: true);
  });

  NetworkSource source() => NetworkSource(
    id: _sourceId,
    type: NetworkSourceType.tapo,
    name: 'Garden',
    host: '127.0.0.1',
    useTls: true,
    camera: TapoCameraInfo(mediaPort: streamd.port),
  );

  Future<TapoFileSystem> open({FakeTapoCamera? withCamera}) => TapoFileSystem.openWith(
    source(),
    _password,
    client: TapoControlClient(
      sourceId: _sourceId,
      host: '127.0.0.1',
      password: _password,
      known: TapoCameraInfo(mediaPort: streamd.port, certificateSha256: fakeCameraCertificate),
      transport: (host, pin) => withCamera ?? camera,
      login: (transport) =>
          TapoLogin(transport, spake2p: (input) async => spake2pClient(input), reloginDelay: Duration.zero),
      cache: cache,
    ),
    worker: worker,
    cacheRoot: () async => root,
  );

  TapoClip clip(int start, int end, {int type = 2}) => TapoClip(
    start: DateTime.fromMillisecondsSinceEpoch(start * 1000, isUtc: true),
    end: DateTime.fromMillisecondsSinceEpoch(end * 1000, isUtc: true),
    videoType: type,
    kind: tapoClipKind(type),
    path: '/2026-09-18/$start-$end.mov',
  );

  test('needs the TP-Link password and opens without any request', () async {
    await expectLater(
      TapoFileSystem.openWith(source(), null, cacheRoot: () async => root),
      throwsA(isA<NetworkFileSystemException>().having((e) => e.isAuthentication, 'auth', isTrue)),
    );
    await open();
    expect(camera.bodies, isEmpty);
    expect(streamd.connections, 0);
  });

  test('lists the days as folders and the clips of a day as files', () async {
    final fileSystem = await open();
    final days = await fileSystem.list('/');
    expect(days.map((entry) => entry.path), ['/2026-09-17', '/2026-09-18']);
    expect(days.every((entry) => entry.isDirectory), isTrue);
    final clips = await fileSystem.list('/2026-09-18');
    expect(clips.map((entry) => entry.name), [
      '1789683060-1789683144.mov',
      '1789700000-1789700060.mov',
      '1789750000-1789750600.mov',
    ]);
    expect(clips.first.mimeType, 'video/quicktime');
    expect(clips.first.durationMs, 84000);
    expect(clips.first.size, isNull);
    await expectLater(
      fileSystem.list('/nope'),
      throwsA(isA<NetworkFileSystemException>().having((e) => e.isNotFound, 'not found', isTrue)),
    );
  });

  test('answers not found for a clip not fetched, so that the bridge never waits on the camera', () async {
    final fileSystem = await open();
    const path = '/2026-09-18/1789683060-1789683144.mov';
    await expectLater(
      fileSystem.stat(path),
      throwsA(isA<NetworkFileSystemException>().having((e) => e.isNotFound, 'not found', isTrue)),
    );
    await expectLater(
      fileSystem.readRange(path, 0, 10),
      throwsA(isA<NetworkFileSystemException>().having((e) => e.isNotFound, 'not found', isTrue)),
    );
    expect(camera.bodies, isEmpty);
  });

  test('fetches a clip into a QuickTime file the bridge then serves', () async {
    final fileSystem = await open();
    final target = clip(1789683060, 1789683062);
    final progress = <double>[];
    await fileSystem.fetch(target, onProgress: progress.add);
    expect(fileSystem.isFetched(target), isTrue);
    expect(progress.last, 1);
    expect(progress, orderedEquals([...progress]..sort()));
    final entry = await fileSystem.stat(target.path);
    expect(entry.size, greaterThan(1000));
    expect(entry.modified, target.start);
    final head = await fileSystem.readRange(target.path, 4, 8);
    expect(String.fromCharCodes(head), 'ftypqt  ');
    final probe = await probeSphericalMetadata((offset, length) => fileSystem.readRange(target.path, offset, length));
    expect(probe.codec, 'avc1');
    expect(probe.codedWidth, 64);
    expect(streamd.stops, hasLength(1));
    expect(Directory('${root.path}/tapo/$_sourceId/clips').listSync().whereType<File>().map((file) => file.path), [
      endsWith('1789683060-1789683062.mov'),
    ]);
    // Fetched once: a second fetch asks nothing
    final sessions = streamd.sessions;
    await fileSystem.fetch(target);
    expect(streamd.sessions, sessions);
  });

  test('tries a busy camera again later', () async {
    streamd.refuseNext.addAll([-52405, -52417]);
    final fileSystem = await open();
    final target = clip(1789683060, 1789683062);
    await fileSystem.fetch(target);
    expect(fileSystem.isFetched(target), isTrue);
    expect(streamd.requests, hasLength(3));
  });

  test('tells a camera that stays busy', () async {
    streamd.refuseNext.addAll([-52405, -52405, -52405, -52405]);
    final fileSystem = await open();
    await expectLater(
      fileSystem.fetch(clip(1789683060, 1789683062)),
      throwsA(isA<TapoCameraException>().having((e) => e.kind, 'kind', TapoErrorKind.busy)),
    );
  });

  test('stops a fetch on cancel and leaves no file', () async {
    final frames = fixtureAccessUnits();
    streamd.clip = clipParts([for (var i = 0; i < 20; i++) ...frames]);
    final fileSystem = await open();
    final target = clip(1789683060, 1789683100);
    final cancel = Completer<void>();
    final fetching = fileSystem.fetch(
      target,
      cancel: cancel.future,
      onProgress: (value) {
        if (value > 0.05 && !cancel.isCompleted) {
          cancel.complete();
        }
      },
    );
    await expectLater(
      fetching,
      throwsA(isA<TapoCameraException>().having((e) => e.kind, 'kind', TapoErrorKind.cancelled)),
    );
    expect(fileSystem.isFetched(target), isFalse);
    final folder = Directory('${root.path}/tapo/$_sourceId/clips');
    expect(folder.existsSync() ? folder.listSync() : const [], isEmpty);
    // The camera's session slot is freed at once, as at the end of a clip
    final told = DateTime.now().add(const Duration(seconds: 10));
    while (streamd.stops.isEmpty && DateTime.now().isBefore(told)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(streamd.stops, hasLength(1));
  });

  test('refuses an H.265 recording', () async {
    streamd.clip = clipParts(fixtureAccessUnits().take(2).toList(), videoType: 0x24);
    final fileSystem = await open();
    await expectLater(
      fileSystem.fetch(clip(1789683060, 1789683062)),
      throwsA(isA<TapoCameraException>().having((e) => e.kind, 'kind', TapoErrorKind.h265)),
    );
  });

  test('opens the media port only after a login through the pinned certificate', () async {
    final refusing = FakeTapoCamera(cloudPassword: 'another');
    final fileSystem = await open(withCamera: refusing);
    await expectLater(
      fileSystem.fetch(clip(1789683060, 1789683062)),
      throwsA(isA<TapoCameraException>().having((e) => e.kind, 'kind', TapoErrorKind.wrongPassword)),
    );
    expect(await fileSystem.thumbnail(clip(1789683060, 1789683062)), isNull);
    expect(streamd.connections, 0);
  });

  test('gets the picture of an event recording once, and none for a continuous one', () async {
    final fileSystem = await open();
    final event = clip(1789683060, 1789683144);
    expect(await fileSystem.thumbnail(event), fakeSnapshot);
    final sessions = streamd.sessions;
    expect(await fileSystem.thumbnail(event), fakeSnapshot);
    expect(streamd.sessions, sessions);
    expect(await fileSystem.thumbnail(clip(1789750000, 1789750600, type: 1)), isNull);
    expect(streamd.requests, hasLength(1));
  });

  test('gets several pictures on one connection', () async {
    final fileSystem = await open();
    final pictures = await Future.wait([
      for (var i = 0; i < 3; i++) fileSystem.thumbnail(clip(1789683060 + i * 100, 1789683070 + i * 100)),
    ]);
    expect(pictures, everyElement(fakeSnapshot));
    expect(streamd.sessions, lessThanOrEqualTo(2));
  });

  test('deletes a copy, tells the size of the cache and clears it', () async {
    final fileSystem = await open();
    final target = clip(1789683060, 1789683062);
    await fileSystem.fetch(target);
    expect(await fileSystem.cacheBytes(), greaterThan(1000));
    await fileSystem.deleteCopy(target);
    expect(fileSystem.isFetched(target), isFalse);
    await fileSystem.fetch(target);
    await fileSystem.clearCache();
    expect(await fileSystem.cacheBytes(), 0);
  });

  test('tells a refused password as an authentication error of the share', () async {
    final fileSystem = await open(withCamera: FakeTapoCamera(cloudPassword: 'another'));
    await expectLater(
      fileSystem.list('/'),
      throwsA(isA<NetworkFileSystemException>().having((e) => e.isAuthentication, 'auth', isTrue)),
    );
  });

  test('keeps the clips under their limit, the ones played least recently going first', () async {
    final clips = Directory('${root.path}/tapo/$_sourceId/clips')..createSync(recursive: true);
    final other = Directory('${root.path}/tapo/fedcba9876543210/clips')..createSync(recursive: true);
    final old = File('${clips.path}/1-2.mov')..writeAsBytesSync(Uint8List(600));
    old.setLastModifiedSync(DateTime(2026, 1, 1));
    final played = File('${other.path}/3-4.mov')..writeAsBytesSync(Uint8List(600));
    played.setLastModifiedSync(DateTime(2026, 2, 1));
    final fresh = File('${clips.path}/5-6.mov')..writeAsBytesSync(Uint8List(600));
    await trimTapoClipCache(Directory('${root.path}/tapo'), limit: 1300, keep: fresh.path);
    expect(old.existsSync(), isFalse);
    expect(played.existsSync(), isTrue);
    expect(fresh.existsSync(), isTrue);
  });
}
