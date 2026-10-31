import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/models/settings_key.dart';
import 'package:immich_mobile/domain/services/video_source_policy.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/platform/tv_api.g.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/widgets/settings/asset_viewer_settings/video_viewer_settings.dart';

import '../../unit/presentation/presentation_context.dart';

void main() {
  late PresentationContext context;

  setUp(() async {
    context = await PresentationContext.create();
  });

  tearDown(() async {
    await context.dispose();
  });

  final spatialSwitch = find.widgetWithText(SwitchListTile, 'Spatial 2.5D (experimental)');

  testWidgets('offers the Spatial 2.5D player on a phone, off by default', (tester) async {
    await tester.pumpTestWidget(
      context,
      // Scrolled as on the settings page: the group is taller than the test screen
      const SingleChildScrollView(child: VideoViewerSettings()),
      overrides: [isHorizonOsProvider.overrideWith((ref) => false)],
    );

    expect(spatialSwitch, findsOneWidget);
    expect(
      find.text(
        'Stereoscopic videos gain depth on a flat screen: the view follows your head, tracked with the front camera on '
        'the device only',
      ),
      findsOneWidget,
    );
    // On by default: the camera is still only used once the player is open
    expect(tester.widget<SwitchListTile>(spatialSwitch).value, isTrue);
    expect(SettingsRepository.instance.appConfig.viewer.spatial25d, isTrue);
  });

  testWidgets('turns the Spatial 2.5D player on and off', (tester) async {
    await tester.pumpTestWidget(
      context,
      // Scrolled as on the settings page: the group is taller than the test screen
      const SingleChildScrollView(child: VideoViewerSettings()),
      overrides: [isHorizonOsProvider.overrideWith((ref) => false)],
    );

    await tester.tap(spatialSwitch);
    await tester.pumpAndSettle();
    expect(SettingsRepository.instance.appConfig.viewer.spatial25d, isFalse);

    await tester.tap(spatialSwitch);
    await tester.pumpAndSettle();
    expect(SettingsRepository.instance.appConfig.viewer.spatial25d, isTrue);
  });

  testWidgets('leaves the Spatial 2.5D player out on a Meta Quest', (tester) async {
    await tester.pumpTestWidget(
      context,
      // Scrolled as on the settings page: the group is taller than the test screen
      const SingleChildScrollView(child: VideoViewerSettings()),
      overrides: [isHorizonOsProvider.overrideWith((ref) => true)],
    );

    expect(spatialSwitch, findsNothing);
    expect(find.byType(SwitchListTile), findsNWidgets(4), reason: 'the other video settings stay');
    expect(find.text('Video source'), findsOneWidget);
  });

  group('reverse thumbstick turn', () {
    final reverseSwitch = find.widgetWithText(SwitchListTile, 'Reverse thumbstick turn');

    testWidgets('offered on a Meta Quest, off by default', (tester) async {
      await tester.pumpTestWidget(
        context,
        // Scrolled as on the settings page: the group is taller than the test screen
        const SingleChildScrollView(child: VideoViewerSettings()),
        overrides: [isHorizonOsProvider.overrideWith((ref) => true)],
      );

      expect(reverseSwitch, findsOneWidget);
      expect(
        find.text('The right thumbstick of the immersive viewer turns photos and videos the other way'),
        findsOneWidget,
      );
      expect(tester.widget<SwitchListTile>(reverseSwitch).value, isFalse);
      expect(SettingsRepository.instance.appConfig.viewer.reverseThumbstickTurn, isFalse);
    });

    testWidgets('turned on and off', (tester) async {
      await tester.pumpTestWidget(
        context,
        // Scrolled as on the settings page: the group is taller than the test screen
        const SingleChildScrollView(child: VideoViewerSettings()),
        overrides: [isHorizonOsProvider.overrideWith((ref) => true)],
      );

      await tester.tap(reverseSwitch);
      await tester.pumpAndSettle();
      expect(SettingsRepository.instance.appConfig.viewer.reverseThumbstickTurn, isTrue);

      await tester.tap(reverseSwitch);
      await tester.pumpAndSettle();
      expect(SettingsRepository.instance.appConfig.viewer.reverseThumbstickTurn, isFalse);
    });

    testWidgets('left out on a phone, which has no thumbstick', (tester) async {
      await tester.pumpTestWidget(
        context,
        // Scrolled as on the settings page: the group is taller than the test screen
        const SingleChildScrollView(child: VideoViewerSettings()),
        overrides: [isHorizonOsProvider.overrideWith((ref) => false)],
      );

      expect(reverseSwitch, findsNothing);
    });
  });

  group('looping', () {
    final loopSwitch = find.widgetWithText(SwitchListTile, 'Looping');

    testWidgets('on by default on a phone, and stored as the phone setting', (tester) async {
      await tester.pumpTestWidget(context, const SingleChildScrollView(child: VideoViewerSettings()));
      expect(tester.widget<SwitchListTile>(loopSwitch).value, isTrue);

      await tester.tap(loopSwitch);
      await tester.pumpAndSettle();

      expect(SettingsRepository.instance.appConfig.viewer.loopVideo, isFalse);
      expect(SettingsRepository.instance.appConfig.viewer.loopVideoOnTv, isFalse, reason: 'untouched');
    });

    testWidgets('off by default on a TV, and stored as the TV setting', (tester) async {
      final tv = [tvDeviceProvider.overrideWithValue(TvDeviceInfo(isTelevision: true, isLowRamDevice: false))];
      await tester.pumpTestWidget(context, const SingleChildScrollView(child: VideoViewerSettings()), overrides: tv);
      expect(tester.widget<SwitchListTile>(loopSwitch).value, isFalse);

      await tester.tap(loopSwitch);
      await tester.pumpAndSettle();

      expect(tester.widget<SwitchListTile>(loopSwitch).value, isTrue);
      expect(SettingsRepository.instance.appConfig.viewer.loopVideoOnTv, isTrue);
      expect(SettingsRepository.instance.appConfig.viewer.loopVideo, isTrue, reason: 'the phone setting is left alone');
    });
  });

  group('video source', () {
    final auto = find.widgetWithText(RadioListTile<VideoSourcePolicy>, 'The original when this device decodes it');
    final original = find.widgetWithText(RadioListTile<VideoSourcePolicy>, 'Always the original');
    final transcoded = find.widgetWithText(RadioListTile<VideoSourcePolicy>, 'Always the transcoded stream');

    VideoSourcePolicy? selected(WidgetTester tester) =>
        tester.widget<RadioGroup<VideoSourcePolicy>>(find.byType(RadioGroup<VideoSourcePolicy>)).groupValue;

    testWidgets('offers the three sources, the original within the decoders described', (tester) async {
      await tester.pumpTestWidget(context, const SingleChildScrollView(child: VideoViewerSettings()));

      expect(find.text('Video source'), findsOneWidget);
      expect(find.text('Which file plays when the server has a transcoded copy'), findsOneWidget);
      expect(auto, findsOneWidget);
      expect(original, findsOneWidget);
      expect(transcoded, findsOneWidget);
      expect(
        find.text(
          'The original plays when its codec and size are within what this device decodes, otherwise the server\'s '
          'transcoded stream plays',
        ),
        findsOneWidget,
      );
      expect(find.text('Force original video'), findsNothing, reason: 'the sources replace the former switch');
    });

    testWidgets('selects the source the former switch stands for on a phone until one is picked', (tester) async {
      final phone = [isHorizonOsProvider.overrideWith((ref) => false)];
      await tester.pumpTestWidget(context, const SingleChildScrollView(child: VideoViewerSettings()), overrides: phone);
      expect(selected(tester), VideoSourcePolicy.alwaysTranscoded);

      await SettingsRepository.instance.write(SettingsKey.viewerLoadOriginalVideo, true);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpTestWidget(context, const SingleChildScrollView(child: VideoViewerSettings()), overrides: phone);
      expect(selected(tester), VideoSourcePolicy.preferOriginalWithinDecoder);
    });

    testWidgets('selects the source of the immersive viewer on a Meta Quest until one is picked', (tester) async {
      final quest = [isHorizonOsProvider.overrideWith((ref) => true)];
      for (final loadOriginalVideo in [false, true]) {
        await SettingsRepository.instance.write(SettingsKey.viewerLoadOriginalVideo, loadOriginalVideo);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpTestWidget(
          context,
          const SingleChildScrollView(child: VideoViewerSettings()),
          overrides: quest,
        );

        expect(selected(tester), VideoSourcePolicy.preferOriginalWithinDecoder, reason: 'switch $loadOriginalVideo');
      }
      expect(SettingsRepository.instance.appConfig.viewer.videoSource, isNull, reason: 'nothing picked yet');
    });

    testWidgets('stores the source shown when the user taps it before picking any', (tester) async {
      for (final (isHorizonOs, tile, policy) in [
        (true, auto, VideoSourcePolicy.preferOriginalWithinDecoder),
        (false, transcoded, VideoSourcePolicy.alwaysTranscoded),
      ]) {
        await SettingsRepository.instance.write(SettingsKey.viewerVideoSource, null);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpTestWidget(
          context,
          // Scrolled as on the settings page: the group is taller than the test screen
          const SingleChildScrollView(child: VideoViewerSettings()),
          overrides: [isHorizonOsProvider.overrideWith((ref) => isHorizonOs)],
        );
        expect(selected(tester), policy);

        await tester.ensureVisible(tile);
        await tester.tap(tile);
        await tester.pumpAndSettle();

        expect(selected(tester), policy, reason: 'Horizon OS $isHorizonOs');
        expect(SettingsRepository.instance.appConfig.viewer.videoSource, policy, reason: 'Horizon OS $isHorizonOs');
        // Every player of the device now follows it: on a Meta Quest, the in-app player too
        expect(SettingsRepository.instance.appConfig.viewer.videoSourcePolicy, policy);
        expect(SettingsRepository.instance.appConfig.viewer.immersiveVideoSourcePolicy, policy);

        // Once picked, a tap on it changes nothing
        await tester.tap(tile);
        await tester.pumpAndSettle();
        expect(selected(tester), policy);
        expect(SettingsRepository.instance.appConfig.viewer.videoSource, policy);
      }
    });

    testWidgets('keeps the source picked', (tester) async {
      await tester.pumpTestWidget(context, const SingleChildScrollView(child: VideoViewerSettings()));

      for (final (tile, policy) in [
        (original, VideoSourcePolicy.alwaysOriginal),
        (auto, VideoSourcePolicy.preferOriginalWithinDecoder),
        (transcoded, VideoSourcePolicy.alwaysTranscoded),
      ]) {
        await tester.ensureVisible(tile);
        await tester.tap(tile);
        await tester.pumpAndSettle();

        expect(selected(tester), policy);
        expect(SettingsRepository.instance.appConfig.viewer.videoSource, policy);
        expect(SettingsRepository.instance.appConfig.viewer.videoSourcePolicy, policy);
      }
    });
  });

  group('Remember where I stopped', () {
    final resumeSwitch = find.widgetWithText(SwitchListTile, 'Remember where I stopped');
    final threshold = find.byKey(const Key('resume_min_minutes'));

    Future<void> pumpSettings(WidgetTester tester) => tester.pumpTestWidget(
      context,
      const SingleChildScrollView(child: VideoViewerSettings()),
      overrides: [isHorizonOsProvider.overrideWith((ref) => false)],
    );

    testWidgets('on by default, for videos longer than 10 minutes', (tester) async {
      await pumpSettings(tester);

      expect(tester.widget<SwitchListTile>(resumeSwitch).value, isTrue);
      expect(
        find.text(
          'Long videos, such as films, resume where you left them and show how much you watched. Shorter ones always '
          'start from the beginning.',
        ),
        findsOneWidget,
      );
      expect(find.text('In videos longer than 10 min'), findsOneWidget);
      expect(tester.widget<Slider>(find.descendant(of: threshold, matching: find.byType(Slider))).value, 10);
    });

    testWidgets('the threshold goes from 0, every video, to 60 minutes by steps of 5', (tester) async {
      await pumpSettings(tester);
      final slider = tester.widget<Slider>(find.descendant(of: threshold, matching: find.byType(Slider)));

      expect(slider.min, 0);
      expect(slider.max, 60);
      expect(slider.divisions, 12);

      slider.onChanged!(0);
      await tester.pumpAndSettle();
      expect(find.text('In every video'), findsOneWidget);
      expect(SettingsRepository.instance.appConfig.viewer.resumeMinMinutes, 0);

      tester.widget<Slider>(find.descendant(of: threshold, matching: find.byType(Slider))).onChanged!(25);
      await tester.pumpAndSettle();
      expect(find.text('In videos longer than 25 min'), findsOneWidget);
      expect(SettingsRepository.instance.appConfig.viewer.resumeMinMinutes, 25);
    });

    testWidgets('off, the threshold goes and nothing is remembered', (tester) async {
      await pumpSettings(tester);

      await tester.tap(resumeSwitch);
      await tester.pumpAndSettle();

      expect(SettingsRepository.instance.appConfig.viewer.resumeVideos, isFalse);
      expect(threshold, findsNothing);
    });
  });
}
