// The controls of a video in the asset viewer hide 5 s after they show while it plays. A remote moving between them
// starts the 5 s again: they never hide under a user who is still using them, and hide 5 s after the last key.

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/video_player_provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/services/gcast.service.dart';
import 'package:immich_mobile/widgets/asset_viewer/animated_play_pause.dart';
import 'package:immich_mobile/widgets/asset_viewer/video_controls.dart';

import '../../service.mocks.dart';

class _Playing extends VideoPlayerNotifier {
  _Playing() {
    state = const VideoPlayerState(
      position: Duration(seconds: 3),
      duration: Duration(minutes: 1),
      status: VideoPlaybackStatus.playing,
    );
  }
}

void main() {
  late ProviderContainer container;
  final outside = FocusNode(debugLabel: 'the viewer');

  const wakelock = 'dev.flutter.pigeon.wakelock_plus_platform_interface.WakelockPlusApi.toggle';

  setUp(() {
    // The player lets the screen sleep again when it goes
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMessageHandler(
      wakelock,
      (_) async => const StandardMessageCodec().encodeMessage(<Object?>[]),
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMessageHandler(wakelock, null);
  });

  tearDownAll(outside.dispose);

  Future<void> pump(WidgetTester tester, {bool tvMode = false}) async {
    container = ProviderContainer(
      overrides: [
        gCastServiceProvider.overrideWithValue(MockGCastService()),
        videoPlayerProvider('video').overrideWith((ref) => _Playing()),
        tvModeProvider.overrideWithValue(tvMode),
      ],
    );
    addTearDown(container.dispose);
    container.read(assetViewerProvider.notifier).setControls(true);
    await tester.pumpWidget(
      EasyLocalization(
        supportedLocales: locales.values.toList(),
        path: translationsPath,
        startLocale: locales.values.first,
        fallbackLocale: locales.values.first,
        saveLocale: false,
        useFallbackTranslations: true,
        assetLoader: const CodegenLoader(),
        child: UncontrolledProviderScope(
          container: container,
          child: Builder(
            builder: (context) => MaterialApp(
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              home: Scaffold(
                body: Column(
                  children: [
                    Focus(focusNode: outside, child: const SizedBox(height: 100)),
                    const VideoControls(videoPlayerName: 'video'),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  bool showing() => container.read(assetViewerProvider).showingControls;

  testWidgets('hide 5 s after they show while the video plays', (tester) async {
    await pump(tester);

    await tester.pump(const Duration(seconds: 4));
    expect(showing(), isTrue);
    await tester.pump(const Duration(seconds: 2));
    expect(showing(), isFalse);
  });

  testWidgets('a key inside the controls starts the 5 s again', (tester) async {
    await pump(tester);
    // The play button has the focus, as after Down in the viewer
    Focus.of(
      tester.element(find.descendant(of: find.byType(IconButton), matching: find.byType(AnimatedPlayPause))),
    ).requestFocus();
    await tester.pump();

    await tester.pump(const Duration(seconds: 3));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump(const Duration(seconds: 3));
    expect(showing(), isTrue, reason: '6 s after they showed, 3 s after the key');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump(const Duration(seconds: 4));
    expect(showing(), isTrue);
    await tester.pump(const Duration(milliseconds: 1100));
    expect(showing(), isFalse, reason: '5 s after the last key');
  });

  testWidgets('a key elsewhere does not keep them', (tester) async {
    await pump(tester);
    outside.requestFocus();
    await tester.pump();

    await tester.pump(const Duration(seconds: 3));
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.pump(const Duration(seconds: 2, milliseconds: 100));

    expect(showing(), isFalse);
  });

  testWidgets('the seek bar takes no focus on a TV, where left and right seek', (tester) async {
    await pump(tester, tvMode: true);
    expect(
      tester
          .widget<ExcludeFocus>(find.ancestor(of: find.byType(Slider), matching: find.byType(ExcludeFocus)).first)
          .excluding,
      isTrue,
    );
  });

  testWidgets('the seek bar takes the focus elsewhere, as before', (tester) async {
    await pump(tester);
    expect(
      tester
          .widget<ExcludeFocus>(find.ancestor(of: find.byType(Slider), matching: find.byType(ExcludeFocus)).first)
          .excluding,
      isFalse,
    );
  });
}
