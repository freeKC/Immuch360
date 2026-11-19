// Lab test of previous and next on the flat screen of the immersive viewer of the Meta Quest (GitHub issue 19, point
// 1), in the real app signed in on the fake Immich server of the Android lab, in its JPEG XL run (a 360 photo flagged
// EQUIRECTANGULAR among the photos, and a video between them: .github/android-lab/fake_immich.py --image-format jxl,
// started by run_lab.sh), on an emulator of the CI, never on a device of the owner. The viewer itself needs Horizon OS
// and does not run on the emulator: the navigator of "View on a big screen" is made as the top bar of the asset viewer
// makes it (flatScreenNavigatorFor, the providers of the asset viewer page), with a recording ImmersiveApi in place of
// the headset; the timeline, the database query of the server's 360° flags, the reads of the HEIF head on the fake
// server and the asset viewer that follows on close are the app's own.
//
//   flat-browse-open      the asset viewer on lab_jxl_jpeg.jpg, its navigator made from the providers of the page
//   flat-browse-next      next: the video and the 360 photo passed over, lab_jxl_heic.heic then lab_jxl_avif.avif on
//                         the big screen, then none after the last photo
//   flat-browse-previous  previous: back to the HEIC photo, then the JPEG one, then none (the 360 photo first)
//   flat-browse-close     the viewer closes on the HEIC photo: the asset viewer shows it
//
// By hand, with the fake server on the computer that runs the emulator (port 2283):
//   python3 .github/android-lab/fake_immich.py --fixtures mobile/test/fixtures/android_lab \
//     --spec open-api/immich-openapi-specs.json --adb adb --serial emulator-5554 --image-format jxl &
//   flutter test integration_test/lab_flat_screen_browse_test.dart -d emulator-5554 --flavor phone

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/platform/immersive_api.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_viewer.page.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/flat_screen_navigator.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/immersive_viewer.dart';
import 'package:immich_mobile/presentation/widgets/images/thumbnail_tile.widget.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/sphere_coverage.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/spherical_probe.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/video_source.provider.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/storage.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:integration_test/integration_test.dart';

import 'test_utils/lab_server.dart';

/// The media of the JPEG XL run, newest first as the timeline shows them
const _sphereName = 'lab_jxl_360.jpg';
const _jpegName = 'lab_jxl_jpeg.jpg';
const _videoName = 'lab_jxl_clip.mp4';
const _heicName = 'lab_jxl_heic.heic';
const _avifName = 'lab_jxl_avif.avif';

/// What the headset was asked to show in place: the url and the stereoPair JSON
typedef _Shown = ({String url, String? stereoPair});

/// The headset of the test: every media asked for is shown
class _RecordingImmersiveApi extends ImmersiveApi {
  final shown = <_Shown>[];

  @override
  Future<bool> showAdjacent(
    int requestId,
    String url,
    bool isVideo,
    String title,
    ImmersiveStereoLayout stereoLayout,
    ImmersiveSphereCoverage coverage,
    String? fallbackUrl,
    String? rawProjection,
    String? stereoPair, {
    String? sourceNotice,
    String? sourceRefusal,
    int startPositionMs = 0,
    String? startNotice,
  }) async {
    labLog('Flat screen: the headset shows $url, ${stereoPair ?? 'no stereo pair'}');
    shown.add((url: url, stereoPair: stereoPair));
    return true;
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('previous and next on the flat screen pass over the video and the 360 photo', (tester) async {
    final server = LabServer.fromEnvironment();
    labLog('Fake server ${server.url}, permissions: ${await LabHost(server).grant()}');
    await startLabApp(tester);
    await signInThroughLabServer(tester, server);
    await pumpUntil(
      tester,
      () => [_sphereName, _jpegName, _videoName, _heicName, _avifName].every((n) => labTile(n).evaluate().isNotEmpty),
      reason: 'the photos and the video of the JPEG XL run in the timeline',
      timeout: const Duration(seconds: 90),
    );
    final state = await server.state();
    expect(state.json['imageFormat'], 'jxl', reason: 'the run with the 360 photo and the video');
    final api = _RecordingImmersiveApi();
    final session = ImmersiveSession();
    late ProviderContainer container;
    late int openingId;
    var requestId = 0;
    final names = <String, String>{};

    Future<bool> request(int step) =>
        session.requestAdjacent(openingId, ++requestId, step, ImmersiveStereoLayout.mono, ImmersiveSphereCoverage.full);

    String? kindOf(String? stereoPair) =>
        stereoPair == null ? null : (jsonDecode(stereoPair) as Map)['kind'] as String?;

    /// The name of the media whose original the headset was asked to read last
    String lastShown() {
      final url = api.shown.last.url;
      for (final MapEntry(key: id, value: name) in names.entries) {
        if (url.contains('/assets/$id/')) {
          return name;
        }
      }
      return url;
    }

    for (final name in [_sphereName, _jpegName, _videoName, _heicName, _avifName]) {
      names[state.assetId(name)] = name;
    }

    await labScenario('flat-browse-open', () async {
      final asset = tester.widget<ThumbnailTile>(labTile(_jpegName).first).asset!;
      await tester.tap(labTile(_jpegName).first);
      await pumpUntil(tester, () => find.byType(AssetViewerPage).evaluate().isNotEmpty, reason: 'the asset viewer');
      // The providers inside the asset viewer page (its own scope: its timeline and its AssetViewerJump), as the top
      // bar reads them for "View on a big screen"; the page itself stands above that scope
      await pumpUntil(tester, () => find.byType(AssetViewer).evaluate().isNotEmpty, reason: 'the pages of the viewer');
      container = ProviderScope.containerOf(tester.element(find.byType(AssetViewer).first), listen: false);
      final builder = flatScreenNavigatorFor(container.read, asset, const StereoPhotoRequest.bigScreen());
      expect(builder, isNotNull, reason: 'a navigator from the providers of the asset viewer');
      final resolver = ImmersiveAssetResolver(
        api: api,
        stereoLabels: const {},
        coverageOverrides: container.read(sphereCoverageOverridesProvider.notifier),
        storage: container.read(storageRepositoryProvider),
        probeService: container.read(sphericalProbeServiceProvider),
        gpanoClient: container.read(immersiveGPanoClientProvider),
        videoSources: container.read(videoSourceServiceProvider),
      );
      final opened = await resolver.resolveStereoPhoto(asset, const StereoPhotoRequest.bigScreen());
      openingId = session.start(builder!(resolver, opened));
    });

    await labScenario('flat-browse-next', () async {
      expect(await request(1), isTrue, reason: 'a photo after $_jpegName');
      expect(lastShown(), _heicName, reason: 'the video passed over');
      expect(kindOf(api.shown.last.stereoPair), 'bigScreen', reason: 'a HEIC photo that holds one eye');
      expect(await request(1), isTrue);
      expect(lastShown(), _avifName);
      expect(await request(1), isFalse, reason: 'nothing after the last photo');
    });

    await labScenario('flat-browse-previous', () async {
      expect(await request(-1), isTrue);
      expect(lastShown(), _heicName);
      expect(await request(-1), isTrue);
      expect(lastShown(), _jpegName, reason: 'the video passed over again');
      expect(await request(-1), isFalse, reason: 'the 360 photo flagged by the server is not a flat screen photo');
      // Back to the HEIC photo, which the viewer then closes on
      expect(await request(1), isTrue);
      expect(lastShown(), _heicName);
      final videoId = state.assetId(_videoName);
      expect(
        (await server.state()).requests.where((r) => r.path.contains('/assets/$videoId/original')),
        isEmpty,
        reason: 'the video never read',
      );
    });

    await labScenario('flat-browse-close', () async {
      session.closed(openingId, api.shown.last.url, ImmersiveStereoLayout.mono, ImmersiveSphereCoverage.full, 0);
      await pumpUntil(
        tester,
        () => container.read(assetViewerProvider).currentAsset?.name == _heicName,
        reason: 'the asset viewer on the photo the viewer closed on',
        describe: () => 'the asset viewer shows ${container.read(assetViewerProvider).currentAsset?.name}',
      );
      final router = labContainer(tester).read(appRouterProvider);
      for (var pops = 0; pops < 3 && labTile(_jpegName).evaluate().isEmpty; pops++) {
        await router.maybePop();
        await tester.pump(const Duration(milliseconds: 500));
      }
      await pumpUntil(tester, () => labTile(_jpegName).evaluate().isNotEmpty, reason: 'the timeline again');
    });

    await waitForQuietSyncs(tester);
  }, timeout: const Timeout(Duration(minutes: 5)));
}
