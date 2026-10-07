// No secret of a camera in a log record or in the text of an error, over a whole session: the logins (V4 and V3),
// requests, a refused password, a fetch and a thumbnail through the media port, the live probe and the test of a
// camera. Looked for: the passwords, their md5 and SHA-256 forms (the passcodes and the Digest hash), the stoks.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/network_source.dart';
import 'package:immich_mobile/domain/models/tapo_camera_info.dart';
import 'package:immich_mobile/domain/services/tapo_camera.dart';
import 'package:immich_mobile/infrastructure/tapo/rtsp_probe.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_camera_tester.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_control_client.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_crypto.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_file_system.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_login.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_media_worker.dart';
import 'package:immich_mobile/infrastructure/tapo/tapo_session_cache.dart';
import 'package:logging/logging.dart';
import 'package:timezone/data/latest.dart';

import 'fake_streamd.dart';
import 'fake_tapo_camera.dart';

const _password = 'synthetic-cloud-password';
const _cameraPassword = 'camera-account-pw';
const _sourceId = '0123456789abcdef';

void main() {
  setUpAll(initializeTimeZones);

  test('no secret reaches a log record or the text of an error', () async {
    final records = <LogRecord>[];
    final errors = <Object>[];
    final previous = Logger.root.level;
    Logger.root.level = Level.ALL;
    final subscription = Logger.root.onRecord.listen(records.add);
    addTearDown(() async {
      Logger.root.level = previous;
      await subscription.cancel();
    });

    final root = await Directory.systemTemp.createTemp('immuch360-tapo-log');
    addTearDown(() => root.delete(recursive: true));
    final streamd = await FakeStreamd.start();
    addTearDown(streamd.close);
    final cameras = <FakeTapoCamera>[];

    // A cache per camera: the logins and the refusals of one would answer for the next one
    TapoControlClient client(FakeTapoCamera camera, String password) {
      cameras.add(camera);
      return TapoControlClient(
        sourceId: _sourceId,
        host: '127.0.0.1',
        password: password,
        known: TapoCameraInfo(mediaPort: streamd.port, certificateSha256: fakeCameraCertificate),
        transport: (host, pin) => camera,
        login: (transport) =>
            TapoLogin(transport, spake2p: (input) async => spake2pClient(input), reloginDelay: Duration.zero),
        cache: TapoSessionCache(),
      );
    }

    Future<void> run(Future<Object?> Function() step) async {
      try {
        await step();
      } catch (error) {
        errors.add(error);
      }
    }

    // A whole session: V4, a dead session and its new login, the listings, a fetch and a thumbnail
    final v4 = FakeTapoCamera();
    final fileSystem = await TapoFileSystem.openWith(
      NetworkSource(
        id: _sourceId,
        type: NetworkSourceType.tapo,
        name: 'Garden',
        host: '127.0.0.1',
        camera: TapoCameraInfo(mediaPort: streamd.port),
      ),
      _password,
      client: client(v4, _password),
      worker: TapoMediaWorker(pauseAfterClip: Duration.zero),
      cacheRoot: () async => root,
    );
    await run(() => fileSystem.details());
    v4.killSession();
    await run(() => fileSystem.cardStatus());
    await run(() => fileSystem.days());
    final clips = await fileSystem.clips('2026-09-18');
    await run(() => fileSystem.fetch(clips.first));
    await run(() => fileSystem.thumbnail(clips.first));
    await fileSystem.close();

    // V3, a refused password, a camera that does not answer
    await run(() => client(FakeTapoCamera(protocol: TapoLoginProtocol.v3), _password).details());
    await run(() => client(FakeTapoCamera(cloudPassword: 'another'), _password).details());
    await run(() => client(FakeTapoCamera()..failNextPosts = 5, _password).details());
    // The live probe and the test of a camera, with a wrong account
    await run(
      () => probeTapoRtsp(
        '127.0.0.1',
        port: 1,
        user: 'viewer',
        password: _cameraPassword,
        timeout: const Duration(seconds: 1),
      ),
    );
    final tested = await runTapoCameraTest(
      const TapoTestRequest(
        sourceId: _sourceId,
        host: fakeCameraHost,
        cloudPassword: _password,
        cameraUser: 'viewer',
        cameraPassword: _cameraPassword,
      ),
      client: (request, password) => client(FakeTapoCamera(cloudPassword: 'another'), password),
      rtsp: (host, {required port, required user, required password}) async =>
          throw const TapoCameraException(TapoErrorKind.wrongPassword, code: 401),
    );
    errors.addAll([?tested.recordingsError, ?tested.liveError]);

    final secrets = {
      _password,
      _cameraPassword,
      md5Hex(_password),
      md5HexUpper(_password),
      sha256Hex(_password),
      sha256HexUpper(_password),
      for (final camera in cameras) ...camera.stoks,
    };
    expect(cameras.expand((camera) => camera.stoks), isNotEmpty);
    expect(records, isNotEmpty);
    expect(errors, isNotEmpty);
    final texts = [
      for (final record in records) ...[record.message, '${record.error ?? ''}', '${record.stackTrace ?? ''}'],
      for (final error in errors) '$error',
      TapoMediaTarget(host: '127.0.0.1', password: _password, playerId: tapoPlayerId(_sourceId)).toString(),
      const TapoTestRequest(sourceId: _sourceId, host: fakeCameraHost, cloudPassword: _password).toString(),
    ];
    for (final secret in secrets) {
      for (final text in texts) {
        expect(text.contains(secret), isFalse, reason: 'a secret in "$text"');
      }
    }
    // A whole session with the SPAKE2+ maths in the test isolate: well over 30 s on a loaded machine
  }, timeout: const Timeout(Duration(minutes: 3)));
}
