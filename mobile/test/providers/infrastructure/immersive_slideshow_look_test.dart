// The background and the transition of the photos of a flat screen chosen on the panel of the immersive viewer of the
// Meta Quest become the settings of the app (GitHub issue 19), through ImmersiveEvents.slideshowLookChanged; the
// settings give the viewer the names it reads (SlideshowLook.kt).

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/domain/models/headset_slideshow_look.dart';
import 'package:immich_mobile/domain/models/settings_key.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';

void main() {
  group('the session', () {
    late List<(SlideshowBackground, SlideshowTransition)> stored;
    late ImmersiveSession session;

    setUp(() {
      stored = [];
      session = ImmersiveSession(
        onSlideshowLookChanged: (background, transition) async => stored.add((background, transition)),
      );
    });

    test('stores the background and the transition chosen in the viewer', () async {
      final openingId = session.start(null);
      session.slideshowLookChanged(openingId, 'passthrough', 'crossFade');
      session.slideshowLookChanged(openingId, 'black', 'slide');
      await Future<void>.delayed(Duration.zero);
      expect(stored, [
        (SlideshowBackground.passthrough, SlideshowTransition.crossFade),
        (SlideshowBackground.black, SlideshowTransition.slide),
      ]);
    });

    test('an opening no longer followed still counts: the press was the user\'s', () async {
      final first = session.start(null);
      session.start(null);
      session.slideshowLookChanged(first, 'blurred', 'none');
      await Future<void>.delayed(Duration.zero);
      expect(stored, [(SlideshowBackground.blurred, SlideshowTransition.none)]);
    });

    test('a name this build does not know changes nothing', () async {
      final openingId = session.start(null);
      session.slideshowLookChanged(openingId, 'aurora', 'slide');
      session.slideshowLookChanged(openingId, 'black', 'zoom');
      await Future<void>.delayed(Duration.zero);
      expect(stored, isEmpty);
    });

    test('a failed write is only logged, and without a store nothing happens', () async {
      final failing = ImmersiveSession(onSlideshowLookChanged: (_, _) async => throw StateError('no database'));
      failing.slideshowLookChanged(1, 'black', 'slide');
      ImmersiveSession().slideshowLookChanged(1, 'black', 'slide');
      await Future<void>.delayed(Duration.zero);
    });
  });

  group('the settings', () {
    test('a blurred photo and a cross fade by default', () {
      expect(const AppConfig().viewer.headsetLook, const HeadsetSlideshowLook());
      expect(const AppConfig().viewer.slideshowBackground, isNull);
      expect(const AppConfig().viewer.slideshowTransition, SlideshowTransition.crossFade);
    });

    test('the frosted switch of build 49 turned off gives black until a background is picked', () {
      final config = AppConfig.fromEntries({SettingsKey.viewerFrostedFlatScreens: false});
      expect(config.viewer.headsetLook.background, SlideshowBackground.black);
      final picked = config.write(SettingsKey.viewerSlideshowBackground, SlideshowBackground.passthrough);
      expect(picked.viewer.headsetLook.background, SlideshowBackground.passthrough);
      expect(picked.read(SettingsKey.viewerSlideshowBackground), SlideshowBackground.passthrough);
    });

    test('the transition picked is read back', () {
      final config = const AppConfig().write(SettingsKey.viewerSlideshowTransition, SlideshowTransition.slide);
      expect(config.viewer.headsetLook.transition, SlideshowTransition.slide);
      expect(config.read(SettingsKey.viewerSlideshowTransition), SlideshowTransition.slide);
    });

    test('the names are those the viewer reads', () {
      expect(SlideshowBackground.values.map((value) => value.name), ['black', 'blurred', 'passthrough']);
      expect(SlideshowTransition.values.map((value) => value.name), ['none', 'crossFade', 'slide']);
      expect(HeadsetSlideshowLook.backgroundNamed('passthrough'), SlideshowBackground.passthrough);
      expect(HeadsetSlideshowLook.transitionNamed('crossFade'), SlideshowTransition.crossFade);
      expect(HeadsetSlideshowLook.backgroundNamed('frosted'), isNull);
    });
  });
}
