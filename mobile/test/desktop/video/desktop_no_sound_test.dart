// "No sound" beside the controls of a video without any audio track, on a computer (desktop_audio_track_button.dart,
// MediaKitVideoPlayerController.noAudio): from the player's own track list once the file is open, nothing before; gone
// for a file with one audio track, the track menu instead for two. Its tooltip says why. The Quest's player, which
// shows the same button, never shows the mark.

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/desktop/video/desktop_audio_track_button.dart';
import 'package:immich_mobile/desktop/video/desktop_player.dart';
import 'package:immich_mobile/desktop/video/media_kit_controller_adapter.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/generated/translations.g.dart';
import 'package:native_video_player/native_video_player.dart';

import 'fake_playback_engine.dart';

const _file = '/videos/RatEX_motion_paysage_16x9 (1).mp4';

void main() {
  final t = StaticTranslations.instance;
  final mark = find.byKey(const Key('desktop_no_sound'));

  test('no audio: a video track listed and no audio one, once the file is open', () {
    const track = DesktopAudioTrack(id: '1', language: 'fre');
    expect(videoHasNoAudio(hasVideo: true, audioTracks: const []), isTrue);
    expect(videoHasNoAudio(hasVideo: true, audioTracks: const [track]), isFalse);
    expect(videoHasNoAudio(hasVideo: null, audioTracks: const []), isFalse, reason: 'not open: nothing known');
    expect(videoHasNoAudio(hasVideo: false, audioTracks: const []), isFalse, reason: 'not a video');
  });

  /// A controller of a fake player that loads the file a moment after it is asked to
  Future<(FakePlaybackEngine, MediaKitVideoPlayerController)> load(WidgetTester tester) async =>
      (await tester.runAsync(() async {
        final players = FakePlayers(onCreate: (engine) => engine.autoLoad = const Duration(minutes: 1, seconds: 45));
        final controller = MediaKitVideoPlayerController(pool: players.pool, resolve: (source) async => source.path);
        await controller.loadVideoSource(await VideoSource.init(path: _file, type: VideoSourceType.file));
        await Future<void>.delayed(Duration.zero);
        return (players.made.single, controller);
      }))!;

  Future<void> pump(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      EasyLocalization(
        supportedLocales: locales.values.toList(),
        path: translationsPath,
        startLocale: locales.values.first,
        fallbackLocale: locales.values.first,
        saveLocale: false,
        useFallbackTranslations: true,
        assetLoader: const CodegenLoader(),
        child: Builder(
          builder: (context) => MaterialApp(
            localizationsDelegates: context.localizationDelegates,
            supportedLocales: context.supportedLocales,
            locale: context.locale,
            home: Scaffold(body: Row(children: [child])),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final platform in [TargetPlatform.windows, TargetPlatform.linux, TargetPlatform.macOS]) {
    testWidgets('${platform.name}: a video without audio track says "No sound", with why in its tooltip', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = platform;
      final (engine, controller) = await load(tester);
      await pump(tester, DesktopAudioTrackButton(controller: controller));
      expect(engine.hasVideo.value, isTrue, reason: 'the file is open');
      expect(controller.noAudio.value, isTrue);
      expect(mark, findsOneWidget);
      expect(find.text(t.desktop_video_no_sound), findsOneWidget);
      expect(find.byTooltip(t.desktop_video_no_sound_tooltip), findsOneWidget);

      // One audio track: nothing to say, no menu either
      engine.audioTracks.value = const [DesktopAudioTrack(id: '1', language: 'fre', channels: 2)];
      await tester.pump();
      expect(controller.noAudio.value, isFalse);
      expect(mark, findsNothing);
      expect(find.byKey(const Key('desktop_audio_track')), findsNothing);

      // Two: the menu of the tracks
      engine.audioTracks.value = const [
        DesktopAudioTrack(id: '1', language: 'fre'),
        DesktopAudioTrack(id: '2', language: 'eng'),
      ];
      await tester.pump();
      expect(mark, findsNothing);
      expect(find.byKey(const Key('desktop_audio_track')), findsOneWidget);

      await tester.runAsync(() async => controller.dispose());
      debugDefaultTargetPlatformOverride = null;
    });
  }

  testWidgets('nothing is said before the tracks are known, and a new video starts without the mark', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final (engine, controller) = await load(tester);
    await pump(tester, DesktopAudioTrackButton(controller: controller));
    expect(mark, findsOneWidget);

    engine.autoLoad = null;
    await tester.runAsync(
      () async =>
          controller.loadVideoSource(await VideoSource.init(path: '/videos/next.mp4', type: VideoSourceType.file)),
    );
    await tester.pump();
    expect(engine.hasVideo.value, isNull, reason: 'the next file is not open yet');
    expect(mark, findsNothing);

    engine.audioTracks.value = const [DesktopAudioTrack(id: '1')];
    engine.load(const Duration(seconds: 10));
    await tester.pump();
    expect(mark, findsNothing, reason: 'it has sound');
    await tester.runAsync(() async => controller.dispose());
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('the Quest shows no mark on its player', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final (_, controller) = await load(tester);
    await pump(tester, DesktopAudioTrackButton(controller: controller));
    expect(controller.noAudio.value, isTrue);
    expect(mark, findsNothing);
    await tester.runAsync(() async => controller.dispose());
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('the mark alone follows what it is given', (tester) async {
    final silent = ValueNotifier(false);
    await pump(tester, DesktopNoSoundMark(noAudio: silent));
    expect(mark, findsNothing);
    silent.value = true;
    await tester.pump();
    expect(mark, findsOneWidget);
  });
}
