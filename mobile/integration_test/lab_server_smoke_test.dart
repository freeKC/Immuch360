// Lab smoke test of the phone app against the fake Immich server of the Android lab
// (.github/android-lab/fake_immich.py, started by run_lab.sh on the runner), on an Android 14 emulator of the CI with
// CheckJNI on (immuch360-android-lab.yml), never on a device of the owner. It is the smoke the reviews of release 44
// asked for on ai1's emulator, made runnable on every push of the lab: each scenario checks its own result, and
// check_logcat.py fails the job on a crash, a CheckJNI abort, an ANR or a process death of the app while it runs.
//
//   redirect       sign in through relative 302 Locations: /.well-known/immich, /api/server/ping and the POST of the
//                  sign in (RedirectInterceptor of the vendored ok_http, crash F1), with the AppHealth line it writes
//   timeline       the sync from the server, the three photos in the timeline and their thumbnails decoded
//   originals      "Load original" on the HEIC and the AVIF photo in the viewer: the originals decoded at their full
//                  size by RemoteImagesImpl (decodeBitmapSized), none remembered as undecodable
//   native-decode  NativeImageDecodeApi on the HEIC and the AVIF within two bounds, and on a 6000 x 3000 HEIC and
//                  AVIF: decoded at the bound as the shares ask, or refused cleanly where the decoder cannot
//   upload         a file shared to the app sent by ForegroundUploadService, checked byte for byte by the server
//
// By hand, with the fake server on the computer that runs the emulator (port 2283):
//   python3 .github/android-lab/fake_immich.py --fixtures mobile/test/fixtures/android_lab \
//     --spec open-api/immich-openapi-specs.json --adb adb --serial emulator-5554 &
//   flutter test integration_test/lab_server_smoke_test.dart -d emulator-5554 --flavor phone

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/settings_key.dart';
import 'package:immich_mobile/domain/services/tiff_photos.dart';
import 'package:immich_mobile/infrastructure/loaders/image_request.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/presentation/widgets/images/guarded_image.dart';
import 'package:immich_mobile/presentation/widgets/images/image_provider.dart';
import 'package:immich_mobile/presentation/widgets/images/remote_image_provider.dart';
import 'package:immich_mobile/presentation/widgets/images/thumbnail_tile.widget.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/services/foreground_upload.service.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'test_utils/lab_server.dart';

/// The size of the originals of the fake server, and of their preview
const _originalWidth = 1200;
const _previewWidth = 720;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets(
    'sign in through relative redirects, the timeline, the originals, the native decoder and an upload',
    (tester) async {
      final server = LabServer.fromEnvironment();
      final host = LabHost(server);
      labLog('Fake server ${server.url}, permissions: ${await host.grant()}');
      await startLabApp(tester);

      await labScenario('redirect', () async {
        final mark = await host.mark();
        final endpoint = await signInThroughLabServer(tester, server);
        expect(endpoint, '${server.url}/api', reason: 'the endpoint /.well-known/immich gives, through its 302');
        final state = await server.state();
        void expectOne(String method, String path, Object status, String why) =>
            expect(state.matching(method, path, status: status), isNotEmpty, reason: '$why (${state.requests})');
        expectOne('GET', '/.well-known/immich', 302, 'the well-known request answered 302');
        expectOne('GET', '/lab/well-known/immich', 200, 'its relative Location followed');
        expectOne('GET', '/api/server/ping', 302, 'the ping answered 302');
        expectOne('GET', '/api/server/ping-target', 200, 'its relative Location (ping-target) followed');
        expectOne('POST', '/api/auth/login', 302, 'the sign in answered 302');
        expectOne('POST', '/api/auth/login-target', 201, 'the sign in sent again, as a POST with its body');
        final signIn = state.matching('POST', '/api/auth/login-target', status: 201).first;
        expect(signIn.json['email'], state.user['email'], reason: 'the body of the sign in kept through the 302');
        final report = await host.waitFor(
          mark,
          r'AppHealth\s*: Redirect 302 of GET http://10\.0\.2\.2:\d+/\.well-known/immich to a relative Location, '
          r'resolved to http://10\.0\.2\.2:\d+/lab/well-known/immich',
          timeout: const Duration(seconds: 30),
        );
        labLog('Redirect report: ${report.split(': ').skip(1).join(': ')}');
      });

      await labScenario('timeline', () async {
        await waitForLabTimeline(tester, server);
        final state = await server.state();
        expect(state.streams, isNotEmpty, reason: 'a sync stream from the server');
        for (final name in labTimelineNames) {
          final asset = tester.widget<ThumbnailTile>(labTile(name).first).asset!;
          final provider = getThumbnailImageProvider(asset);
          expect(provider, isNotNull, reason: 'a thumbnail for $name');
          final (width, height) = await _resolveImage(
            tester,
            provider!,
            (width, height) => width > 0 && height > 0,
            reason: 'the thumbnail of $name decoded',
          );
          labLog('Thumbnail of $name: ${width}x$height');
          final id = state.assetId(name);
          await pumpUntil(
            tester,
            () async => (await server.state()).matching('GET', '/api/assets/$id/thumbnail', status: 200).isNotEmpty,
            reason: 'the thumbnail of $name asked to the server',
            timeout: const Duration(seconds: 30),
          );
        }
      });

      await labScenario('originals', () async {
        await SettingsRepository.instance.write(SettingsKey.imageLoadOriginal, true);
        final container = labContainer(tester);
        for (final name in ['lab_heic.heic', 'lab_avif.avif']) {
          final id = (await server.state()).assetId(name);
          final asset = tester.widget<ThumbnailTile>(labTile(name).first).asset!;
          await tester.tap(labTile(name).first);
          await pumpUntil(
            tester,
            () async => (await server.state()).matching('GET', '/api/assets/$id/original', status: 200).isNotEmpty,
            reason: 'the viewer of $name asking its original (Load original on)',
            describe: () async => 'last requests ${(await server.state()).requests.reversed.take(12).toList()}',
          );
          // The provider of the viewer, so the image cache gives the load the viewer started
          final (width, height) = await _resolveImage(
            tester,
            getFullImageProvider(asset),
            (width, _) => width == _originalWidth,
            reason: 'the original of $name decoded at its full size (the preview is $_previewWidth wide)',
          );
          labLog('Original of $name: ${width}x$height');
          for (final edited in [false, true]) {
            final key = RemoteFullImageProvider.undecodableKey(id, edited: edited);
            expect(UndecodablePhotos.instance.failureOf(key), isNull, reason: 'the original of $name not undecodable');
          }
          await container.read(appRouterProvider).maybePop();
          await pumpUntil(tester, () => labTile(name).evaluate().isNotEmpty, reason: 'the timeline again after $name');
        }
      });

      await labScenario('native-decode', () async {
        // Each decode runs, then the checks: one run tells about all of them. The 1200 x 800 photos within 600 (half)
        // and within 1000 (a scale of 0.83) must decode at the fit size; the 6000 x 3000 ones within 4096 decode at
        // 4096 x 2048 or fail as an ImageDecodeException, never as a crash (check_logcat.py reads the crashes)
        Future<String> decode(String name, int bound) async {
          final bytes = await server.fixture(name);
          try {
            final codec = await decodeEncodedBytes(bytes, maxWidth: bound, maxHeight: bound, source: 'lab', name: name);
            final frame = await codec.getNextFrame();
            final size = '${frame.image.width}x${frame.image.height}';
            frame.image.dispose();
            codec.dispose();
            return size;
          } on ImageDecodeException catch (error) {
            return 'not decoded (${bytes.length} bytes), $error';
          }
        }

        final strict = <String>[];
        for (final (name, bound, width, height, required) in [
          ('lab_photo.heic', 600, 600, 400, true),
          ('lab_photo.avif', 600, 600, 400, true),
          ('lab_photo.heic', 1000, 1000, 667, true),
          ('lab_photo.avif', 1000, 1000, 667, true),
          ('lab_large.heic', 4096, 4096, 2048, false),
          ('lab_large.avif', 4096, 4096, 2048, false),
        ]) {
          final expected = '${width}x$height';
          final outcome = await decode(name, bound);
          labLog('Native decode of $name within $bound: $outcome');
          if (outcome != expected && (required || !outcome.startsWith('not decoded'))) {
            strict.add('$name within $bound: $outcome, expected $expected');
          }
        }
        expect(strict, isEmpty, reason: 'the native decoder (NativeImageDecodeApi) at the fit size');
      });

      await labScenario('upload', () async {
        final bytes = await server.fixture('lab_photo.jpg');
        final file = File('${(await getTemporaryDirectory()).path}/lab_upload.jpg')..writeAsBytesSync(bytes);
        final sent = <String>[];
        final errors = <String>[];
        await labContainer(tester)
            .read(foregroundUploadServiceProvider)
            .uploadShareIntent(
              [file],
              onSuccess: (_, remoteId) => sent.add(remoteId),
              onError: (_, message) => errors.add(message),
            );
        expect(errors, isEmpty, reason: 'the upload accepted');
        expect(sent, hasLength(1), reason: 'one asset id from the server');
        final upload = (await server.state()).uploads.firstWhere((upload) => upload['id'] == sent.single);
        final files = upload['files'] as List<dynamic>;
        expect(files, hasLength(1), reason: 'one file in the upload ($upload)');
        final part = files.single as Map<String, dynamic>;
        expect(part['field'], 'assetData');
        expect(part['filename'], 'lab_upload.jpg');
        expect(part['size'], bytes.length, reason: 'every byte of the file sent');
        expect(part['sha1'], sha1.convert(bytes).toString(), reason: 'the bytes of the file sent unchanged');
        final fields = upload['fields'] as Map<String, dynamic>;
        expect(fields.keys, containsAll(['deviceAssetId', 'deviceId', 'fileCreatedAt', 'fileModifiedAt']));
        labLog('Upload: ${upload['length']} bytes, ${part['size']} of them the file, id ${sent.single}');
      });

      final state = await server.state();
      labLog('Web socket: ${state.socket}');
      labLog('Paths the fake server did not know: ${state.unknownPaths}');
      await waitForQuietSyncs(tester);
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
}

/// Resolves [provider] and pumps frames until it gives an image that [accept] takes, or fails with [reason]
Future<(int, int)> _resolveImage(
  WidgetTester tester,
  ImageProvider provider,
  bool Function(int width, int height) accept, {
  required String reason,
}) async {
  final seen = <String>[];
  Object? error;
  (int, int)? found;
  final stream = provider.resolve(ImageConfiguration.empty);
  final listener = ImageStreamListener((info, _) {
    final size = (info.image.width, info.image.height);
    info.dispose();
    seen.add('${size.$1}x${size.$2}');
    if (found == null && accept(size.$1, size.$2)) {
      found = size;
    }
  }, onError: (exception, _) => error = exception);
  stream.addListener(listener);
  try {
    await pumpUntil(tester, () => found != null || error != null, reason: reason, describe: () => 'images seen: $seen');
  } finally {
    stream.removeListener(listener);
  }
  final result = found;
  if (result == null) {
    return fail('$reason: $error (images seen: $seen)');
  }
  return result;
}
