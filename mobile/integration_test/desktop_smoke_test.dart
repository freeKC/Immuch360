// The first check of Immuch360 Desktop on a real computer, run in a slot the owner gave (it opens a window):
//   flutter test integration_test/desktop_smoke_test.dart -d windows
// It starts the app as lib/main_desktop.dart does, without the window setup, and waits for the first page: the welcome
// page, the timeline when a session is already saved in this profile, or the login page when its server refused it.
// On Windows it then opens the Spatial 2.5D route on a stereo clip of the tests with the slider (never the webcam, and
// without touching the Spatial settings of this profile), checks that the passes draw on this computer's GPU and that
// an arrow key moves the viewpoint, prints their figures, and closes it.

import 'dart:async';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/data/store.dart';
import 'package:immich_mobile/desktop/platform/desktop_overrides.dart';
import 'package:immich_mobile/desktop/spatial/spatial_player_route.dart';
import 'package:immich_mobile/desktop/spatial/spatial_plugin_output.dart';
import 'package:immich_mobile/desktop/spatial/spatial_settings.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/main.dart' as app;
import 'package:immich_mobile/pages/common/tab_shell.page.dart';
import 'package:immich_mobile/pages/login/welcome.page.dart';
import 'package:immich_mobile/platform/spatial_video_api.g.dart' show SpatialStereoLayout;
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/utils/bootstrap.dart';
import 'package:immich_mobile/widgets/forms/login/login_form.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Immuch360 Desktop starts to its first page', (tester) async {
    expect(CurrentPlatform.isDesktop, isTrue, reason: 'run with -d windows, -d linux or -d macos');

    await EasyLocalization.ensureInitialized();
    final (dataController, apiService) = await Bootstrap.initDomain();
    await app.initApp();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...Store.overrideWith(dataController: dataController, apiService: apiService),
          ...desktopOverrides(),
        ],
        child: const app.MainWidget(),
      ),
    );

    final firstPage = find.byWidgetPredicate(
      (widget) => widget is WelcomePage || widget is LoginForm || widget is TabShellPage,
    );
    for (var i = 0; i < 300 && firstPage.evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(firstPage, findsWidgets);
    final shown = find.byType(WelcomePage).evaluate().isNotEmpty
        ? 'welcome'
        : find.byType(LoginForm).evaluate().isNotEmpty
        ? 'login'
        : 'timeline';
    debugPrint('First page: $shown');

    // A profile without a saved login (the debug build's own profile at first) is signed out by the splash page,
    // which shows the welcome page without waiting for that sign out: it must end before the test tears the providers
    // down, or it writes to a disposed AuthNotifier
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    if (CurrentPlatform.isWindows) {
      await _spatialRoute(tester, ProviderScope.containerOf(tester.element(firstPage.first)));
    }
  });
}

/// The Spatial 2.5D route on the stereo clip of the tests, moved by the slider and the arrow keys only (see the top of
/// this file)
Future<void> _spatialRoute(WidgetTester tester, ProviderContainer container) async {
  final capabilities = await container.read(spatialVideoApiProvider).capabilities();
  debugPrint(
    'Spatial 2.5D: supported ${capabilities.supported}${capabilities.reason == null ? '' : ', ${capabilities.reason}'}',
  );
  expect(capabilities.supported, isTrue, reason: 'Windows with libmpv');
  final clip = p.absolute(p.join('test', 'fixtures', 'video', 'spatial-sbs-dots-4s.mp4'));
  expect(File(clip).existsSync(), isTrue, reason: clip);
  final navigator = container.read(appRouterProvider).navigatorKey.currentState!;
  SpatialPluginOutput? output;
  unawaited(
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => DesktopSpatialPlayerPage(
          args: SpatialPlayerArgs(url: clip, title: 'Spatial smoke', layout: SpatialStereoLayout.sideBySide),
          dependencies: SpatialPlayerDependencies(
            outputFor: (engine) {
              final controller = engine.videoController;
              return output = controller == null ? null : SpatialPluginOutput.forController(controller);
            },
            // The slider: no webcam in a smoke test, and the settings of this profile stay as they are
            loadSettings: () async => const DesktopSpatialSettings(source: SpatialViewpointSource.manual),
            saveSettings: (_) async {},
          ),
        ),
      ),
    ),
  );
  for (var i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  final page = tester.state<DesktopSpatialPlayerPageState>(find.byType(DesktopSpatialPlayerPage));
  expect(page.drawing, isTrue, reason: 'the Spatial passes draw on this GPU (${output?.glRenderer})');
  expect(page.tracking.cameraOpen, isFalse, reason: 'no webcam in the smoke test');
  final before = await output!.stats();
  await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  final after = await output!.stats();
  debugPrint(
    'Spatial 2.5D on ${output!.glRenderer}: ${after?.quality.name}, ${after?.renderFps.toStringAsFixed(1)} draws/s, '
    '${after?.renderMs.toStringAsFixed(1)} ms, disparity ${after?.disparityWidth} x ${after?.disparityHeight}, '
    'viewpoint ${before?.requestedViewpoint} then ${after?.requestedViewpoint}',
  );
  expect(after?.spatial, isTrue);
  expect(after?.requestedViewpoint, closeTo(0.55, 1e-6), reason: 'the right arrow moves the viewpoint');
  navigator.pop();
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
