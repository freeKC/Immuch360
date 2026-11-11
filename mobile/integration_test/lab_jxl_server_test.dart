// Lab test of the phone app against the fake Immich server of the Android lab answering as a server whose admin
// picked JPEG XL for the thumbnails and previews, a choice of Immich 3.4.0 (.github/android-lab/fake_immich.py
// --image-format jxl, started by run_lab.sh on the runner after the other lab tests), on an Android 14 emulator of the
// CI with CheckJNI on (immuch360-android-lab.yml), never on a device of the owner. Every size of /thumbnail is a JPEG
// XL file there (image/jxl), which neither Android nor the engine decodes: the app decodes them with the Rust core.
// Each scenario checks its own result, and check_logcat.py fails the job on a crash, an ANR or a death of the app, and
// on a "Not decoded" line of the app while a jxl scenario runs.
//
//   jxl-grid           the sync from the server, the four photos in the timeline and their JPEG XL thumbnails decoded
//   jxl-viewer         the viewer of a photo showing its JPEG XL preview (Load original off), 720 pixels wide, the
//                      photo not remembered as undecodable
//   jxl-360            a photo flagged EQUIRECTANGULAR opened in the 360° viewer, which shows its JPEG XL preview
//                      (1440 x 720) on the sphere
//   jxl-native-decode  NativeImageDecodeApi on the JPEG XL preview (720 x 480) within two bounds, decoded at the fit
//                      size
//
// By hand, with the fake server on the computer that runs the emulator (port 2283):
//   python3 .github/android-lab/fake_immich.py --fixtures mobile/test/fixtures/android_lab \
//     --spec open-api/immich-openapi-specs.json --adb adb --serial emulator-5554 --image-format jxl &
//   flutter test integration_test/lab_jxl_server_test.dart -d emulator-5554 --flavor phone

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/settings_key.dart';
import 'package:immich_mobile/domain/services/tiff_photos.dart';
import 'package:immich_mobile/infrastructure/loaders/image_request.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_viewer.page.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/panorama_viewer.widget.dart';
import 'package:immich_mobile/presentation/widgets/images/guarded_image.dart';
import 'package:immich_mobile/presentation/widgets/images/image_provider.dart';
import 'package:immich_mobile/presentation/widgets/images/remote_image_provider.dart';
import 'package:immich_mobile/presentation/widgets/images/thumbnail_tile.widget.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:integration_test/integration_test.dart';

import 'test_utils/lab_server.dart';

/// The photos of the JPEG XL run of the fake server, the 360 photo first
const _jxlNames = ['lab_jxl_360.jpg', 'lab_jxl_jpeg.jpg', 'lab_jxl_heic.heic', 'lab_jxl_avif.avif'];
const _photoName = 'lab_jxl_jpeg.jpg';
const _sphereName = 'lab_jxl_360.jpg';

/// The width of the JPEG XL previews of the fake server, of a photo and of the 360 photo, and of the 360 thumbnail
const _previewWidth = 720;
const _spherePreviewWidth = 1440;
const _sphereThumbnailWidth = 320;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('JPEG XL thumbnails and previews in the timeline, the viewer, the 360° viewer and the native decoder', (
    tester,
  ) async {
    final server = LabServer.fromEnvironment();
    final host = LabHost(server);
    labLog('Fake server ${server.url}, permissions: ${await host.grant()}');
    await startLabApp(tester);
    await signInThroughLabServer(tester, server);
    // The preview is what the viewers show then, and it is the JPEG XL file
    await SettingsRepository.instance.write(SettingsKey.imageLoadOriginal, false);

    await labScenario('jxl-grid', () async {
      await _waitForJxlTimeline(tester, server);
      final state = await server.state();
      expect(state.json['imageFormat'], 'jxl', reason: 'the fake server answers JPEG XL thumbnails');
      for (final name in _jxlNames) {
        final asset = tester.widget<ThumbnailTile>(labTile(name).first).asset!;
        final provider = getThumbnailImageProvider(asset);
        expect(provider, isNotNull, reason: 'a thumbnail for $name');
        final (width, height) = await _resolveImage(
          tester,
          provider!,
          (width, height) => width > 0 && height > 0,
          reason: 'the JPEG XL thumbnail of $name decoded',
        );
        labLog('JXL thumbnail of $name: ${width}x$height');
        final id = state.assetId(name);
        await pumpUntil(
          tester,
          () async => (await server.state())
              .matching('GET', '/api/assets/$id/thumbnail', status: 200)
              .any((request) => request.json['type'] == 'image/jxl'),
          reason: 'the thumbnail of $name asked to the server and answered image/jxl',
          timeout: const Duration(seconds: 30),
        );
      }
    });

    await labScenario('jxl-viewer', () async {
      final container = labContainer(tester);
      final id = (await server.state()).assetId(_photoName);
      final asset = tester.widget<ThumbnailTile>(labTile(_photoName).first).asset!;
      await tester.tap(labTile(_photoName).first);
      await pumpUntil(
        tester,
        () => find.byType(AssetViewerPage).evaluate().isNotEmpty,
        reason: 'the viewer of $_photoName',
      );
      await pumpUntil(
        tester,
        () async => (await server.state())
            .matching('GET', '/api/assets/$id/thumbnail', status: 200)
            .any((request) => request.json['size'] == 'preview' && request.json['type'] == 'image/jxl'),
        reason: 'the viewer of $_photoName asking its JPEG XL preview',
        describe: () async => 'last requests ${(await server.state()).requests.reversed.take(12).toList()}',
      );
      // The provider of the viewer, so the image cache gives the load the viewer started
      final (width, height) = await _resolveImage(
        tester,
        getFullImageProvider(asset),
        (width, _) => width == _previewWidth,
        reason: 'the JPEG XL preview of $_photoName decoded ($_previewWidth wide)',
      );
      labLog('JXL preview of $_photoName: ${width}x$height');
      for (final edited in [false, true]) {
        final key = RemoteFullImageProvider.undecodableKey(id, edited: edited);
        expect(UndecodablePhotos.instance.failureOf(key), isNull, reason: '$_photoName not undecodable');
      }
      await container.read(appRouterProvider).maybePop();
      await pumpUntil(tester, () => labTile(_photoName).evaluate().isNotEmpty, reason: 'the timeline again');
    });

    await labScenario('jxl-360', () async {
      final container = labContainer(tester);
      final router = container.read(appRouterProvider);
      final id = (await server.state()).assetId(_sphereName);
      final asset = tester.widget<ThumbnailTile>(labTile(_sphereName).first).asset!;
      await tester.tap(labTile(_sphereName).first);
      await pumpUntil(
        tester,
        () => find.byType(AssetViewerPage).evaluate().isNotEmpty,
        reason: 'the viewer of $_sphereName',
      );
      // The 360° button of the viewer shows once the exif of the photo, flagged EQUIRECTANGULAR, is read
      final button = find.byTooltip('360°');
      final buttonUntil = DateTime.now().add(const Duration(seconds: 15));
      while (button.evaluate().isEmpty && DateTime.now().isBefore(buttonUntil)) {
        await tester.pump(const Duration(milliseconds: 200));
      }
      if (button.evaluate().isNotEmpty) {
        labLog('JXL 360: the 360° button of the viewer');
        await tester.tap(button.first);
      } else {
        labLog('JXL 360: no 360° button within 15 s, the 360° viewer opened by its route');
        // The push ends when the route is popped
        unawaited(router.push(PanoramaViewerRoute(asset: asset)));
      }
      await pumpUntil(
        tester,
        () => find.byType(PanoramaViewerPage).evaluate().isNotEmpty,
        reason: 'the 360° viewer of $_sphereName',
      );
      await pumpUntil(
        tester,
        () async => (await server.state())
            .matching('GET', '/api/assets/$id/thumbnail', status: 200)
            .any((request) => request.json['size'] == 'preview' && request.json['type'] == 'image/jxl'),
        reason: 'the 360° viewer asking the JPEG XL preview of $_sphereName',
        describe: () async => 'last requests ${(await server.state()).requests.reversed.take(12).toList()}',
      );
      // The provider of the 360° viewer (panoramaImageProvider), at the size it gives it
      final page = tester.element(find.byType(PanoramaViewerPage).first);
      final (width, height) = await _resolveImage(
        tester,
        container.read(panoramaImageProvider)(asset, MediaQuery.sizeOf(page)),
        (width, _) => width > _sphereThumbnailWidth,
        reason: 'the JPEG XL preview of $_sphereName on the sphere ($_spherePreviewWidth wide)',
      );
      labLog('JXL 360 preview of $_sphereName: ${width}x$height');
      expect(
        UndecodablePhotos.instance.failureOf(RemoteFullImageProvider.undecodableKey(id, edited: false)),
        isNull,
        reason: '$_sphereName not undecodable',
      );
      // The 360° viewer, then the viewer
      for (var pops = 0; pops < 4 && find.byType(AssetViewerPage).evaluate().isNotEmpty; pops++) {
        await router.maybePop();
        await tester.pump(const Duration(milliseconds: 500));
      }
      await pumpUntil(tester, () => labTile(_sphereName).evaluate().isNotEmpty, reason: 'the timeline again');
    });

    await labScenario('jxl-native-decode', () async {
      // The guarded images (shares, files opened from another app) of a JPEG XL: the native decoder of Android
      // decodes it with the Rust core, never larger than the image, its aspect kept
      final bytes = await server.fixture('lab_preview.jxl');
      final strict = <String>[];
      for (final (bound, expected) in [(360, '360x240'), (1000, '720x480')]) {
        String outcome;
        try {
          final codec = await decodeEncodedBytes(
            bytes,
            maxWidth: bound,
            maxHeight: bound,
            source: 'lab',
            name: 'lab_preview.jxl',
          );
          final frame = await codec.getNextFrame();
          outcome = '${frame.image.width}x${frame.image.height}';
          frame.image.dispose();
          codec.dispose();
        } on ImageDecodeException catch (error) {
          outcome = 'not decoded (${bytes.length} bytes), $error';
        }
        labLog('JXL native decode of lab_preview.jxl within $bound: $outcome');
        if (outcome != expected) {
          strict.add('lab_preview.jxl within $bound: $outcome, expected $expected');
        }
      }
      expect(strict, isEmpty, reason: 'the native decoder (NativeImageDecodeApi) on a JPEG XL at the fit size');
    });

    final state = await server.state();
    labLog('Paths the fake server did not know: ${state.unknownPaths}');
    await waitForQuietSyncs(tester);
  }, timeout: const Timeout(Duration(minutes: 6)));
}

/// Waits for the four photos of the JPEG XL run in the timeline
Future<void> _waitForJxlTimeline(WidgetTester tester, LabServer server) => pumpUntil(
  tester,
  () => _jxlNames.every((name) => labTile(name).evaluate().isNotEmpty),
  reason: 'the four photos of the JPEG XL run in the timeline',
  timeout: const Duration(seconds: 90),
  describe: () async {
    final state = await server.state();
    final shown = [for (final name in _jxlNames) '$name: ${labTile(name).evaluate().length}'];
    return 'tiles $shown; sync streams ${state.streams}; last requests ${state.requests.reversed.take(15).toList()}';
  },
);

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
