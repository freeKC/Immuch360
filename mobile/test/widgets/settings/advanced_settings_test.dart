import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/infrastructure/wikipedia/wikipedia_film_cache.dart';
import 'package:immich_mobile/infrastructure/wikipedia/wikipedia_film_client.dart';
import 'package:immich_mobile/platform/tv_api.g.dart';
import 'package:immich_mobile/platform/video_decoder_api.g.dart';
import 'package:immich_mobile/presentation/pages/video_decoders.page.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_tile.widget.dart';
import 'package:immich_mobile/presentation/widgets/drone/drone_import_tile.widget.dart';
import 'package:immich_mobile/providers/ai_immersive/ai_components.provider.dart';
import 'package:immich_mobile/providers/ai_immersive/relief_gate.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/video_source.provider.dart';
import 'package:immich_mobile/providers/drone/dji_link.provider.dart';
import 'package:immich_mobile/providers/infrastructure/immersive.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/wikipedia.provider.dart';
import 'package:immich_mobile/widgets/settings/advanced_settings.dart';

import '../../presentation/pages/drone/dji_link_fakes.dart';
import '../../presentation/widgets/ai_immersive/fake_ai_components_service.dart';
import '../../unit/presentation/presentation_context.dart';

void main() {
  late PresentationContext context;

  setUp(() async {
    context = await PresentationContext.create();
  });

  tearDown(() async {
    await context.dispose();
  });

  testWidgets('opens the video decoders of the device from the troubleshooting settings', (tester) async {
    await tester.pumpTestWidget(
      context,
      const AdvancedSettings(),
      overrides: [
        videoDecodersProvider.overrideWith(
          (ref) async => [
            DecoderInfo(
              name: 'c2.qti.hevc.decoder',
              codec: 'video/hevc',
              hardware: true,
              maxWidth: 8192,
              maxHeight: 4320,
              maxFrameRate: 30,
            ),
          ],
        ),
      ],
    );

    final entry = find.text('Video decoders of this device');
    expect(entry, findsOneWidget);
    expect(
      find.text('What this device decodes, by codec and size, to understand why a 360° video stutters'),
      findsOneWidget,
    );

    await tester.tap(entry);
    await tester.pumpAndSettle();

    expect(find.byType(VideoDecodersPage), findsOneWidget);
    expect(find.text('c2.qti.hevc.decoder'), findsOneWidget);
  });

  group('DJI drones (experimental)', () {
    final djiSwitch = find.descendant(
      of: find.byKey(const Key('advanced_settings_dji_import')),
      matching: find.byType(SwitchListTile),
    );

    /// The page on a device that offers the DJI drone page: an Android phone or tablet, not the Quest build or a TV
    Future<void> pumpOnPhone(WidgetTester tester) async {
      await tester.pumpTestWidget(
        context,
        const AdvancedSettings(),
        overrides: [droneImportSupportedProvider.overrideWithValue(true)],
      );
      await tester.scrollUntilVisible(djiSwitch, 100, scrollable: find.byType(Scrollable).first);
    }

    testWidgets('reads on by default', (tester) async {
      await pumpOnPhone(tester);

      expect(find.text('DJI drones (experimental)'), findsOneWidget);
      expect(tester.widget<SwitchListTile>(djiSwitch).value, isTrue);
      expect(SettingsRepository.instance.appConfig.djiImportEnabled, isTrue);
    });

    testWidgets('turns off and on again', (tester) async {
      await pumpOnPhone(tester);

      await tester.tap(djiSwitch);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(djiSwitch).value, isFalse);
      expect(SettingsRepository.instance.appConfig.djiImportEnabled, isFalse);

      await tester.tap(djiSwitch);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(djiSwitch).value, isTrue);
      expect(SettingsRepository.instance.appConfig.djiImportEnabled, isTrue);
    });

    testWidgets('is not offered where the DJI drone page is not', (tester) async {
      await tester.pumpTestWidget(
        context,
        const AdvancedSettings(),
        overrides: [droneImportSupportedProvider.overrideWithValue(false)],
      );

      expect(find.byKey(const Key('advanced_settings_dji_import')), findsNothing);
    });
  });

  group('Film details from Wikipedia (experimental)', () {
    final wikipediaSwitch = find.descendant(
      of: find.byKey(const Key('advanced_settings_film_wikipedia')),
      matching: find.byType(SwitchListTile),
    );

    testWidgets('reads on by default, on every screen, and turns off, the kept articles with it', (tester) async {
      final cache = MemoryWikipediaFilmCache();
      await cache.write('kept', null);
      final client = WikipediaFilmClient(
        client: MockClient((request) async => http.Response('{}', 500)),
        userAgent: WikipediaFilmClient.userAgentFor('test'),
        cache: cache,
      );
      await tester.pumpTestWidget(
        context,
        const AdvancedSettings(),
        overrides: [
          aiComponentsServiceProvider.overrideWithValue(FakeAiComponentsService()),
          wikipediaFilmClientProvider.overrideWith((ref) async => client),
        ],
      );
      await tester.scrollUntilVisible(wikipediaSwitch, 100, scrollable: find.byType(Scrollable).first);
      await tester.ensureVisible(wikipediaSwitch);
      await tester.pumpAndSettle();
      expect(find.text('Film details from Wikipedia'), findsOneWidget);
      expect(tester.widget<SwitchListTile>(wikipediaSwitch).value, isTrue);
      expect(SettingsRepository.instance.appConfig.viewer.filmWikipedia, isTrue);

      await tester.tap(wikipediaSwitch);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(wikipediaSwitch).value, isFalse);
      expect(SettingsRepository.instance.appConfig.viewer.filmWikipedia, isFalse);
      expect(await cache.read('kept'), isNull, reason: 'off, the articles kept on the device are deleted');
    });
  });

  group('3D by file name (experimental)', () {
    final flat3dSwitch = find.descendant(
      of: find.byKey(const Key('advanced_settings_flat_3d')),
      matching: find.byType(SwitchListTile),
    );

    /// The page on a Meta Quest, the only device with the immersive viewer, in the build of the phones: the AI settings
    /// of the headset show their switches only
    Future<void> pumpOnQuest(WidgetTester tester) async {
      await tester.pumpTestWidget(
        context,
        const AdvancedSettings(),
        overrides: [
          isHorizonOsProvider.overrideWith((ref) => true),
          appFlavorProvider.overrideWithValue(null),
          aiComponentsServiceProvider.overrideWithValue(FakeAiComponentsService()),
        ],
      );
      await tester.scrollUntilVisible(flat3dSwitch, 100, scrollable: find.byType(Scrollable).first);
      // Whole on screen, whatever the switches above it
      await tester.ensureVisible(flat3dSwitch);
      await tester.pumpAndSettle();
    }

    testWidgets('reads on by default, and says which names it reads', (tester) async {
      await pumpOnQuest(tester);

      expect(find.text('3D by file name (experimental)'), findsOneWidget);
      expect(
        find.text(
          'Videos named _SBS, _HSBS, _LR, _TB, _OU or Half-SBS, and photos named _TB, _OU or _HTB, open in 3D on a '
          'flat screen with View in 3D',
        ),
        findsOneWidget,
      );
      expect(tester.widget<SwitchListTile>(flat3dSwitch).value, isTrue);
      expect(SettingsRepository.instance.appConfig.viewer.flat3dByName, isTrue);
    });

    testWidgets('turns off and on again', (tester) async {
      await pumpOnQuest(tester);

      await tester.tap(flat3dSwitch);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(flat3dSwitch).value, isFalse);
      expect(SettingsRepository.instance.appConfig.viewer.flat3dByName, isFalse);

      await tester.tap(flat3dSwitch);
      await tester.pumpAndSettle();
      expect(SettingsRepository.instance.appConfig.viewer.flat3dByName, isTrue);
    });

    testWidgets('is not offered on a phone, which has no immersive viewer', (tester) async {
      await tester.pumpTestWidget(
        context,
        const AdvancedSettings(),
        overrides: [isHorizonOsProvider.overrideWith((ref) => false)],
      );

      expect(find.byKey(const Key('advanced_settings_flat_3d')), findsNothing);
    });
  });

  group('Sharper flat screens (experimental)', () {
    final sharpSwitch = find.descendant(
      of: find.byKey(const Key('advanced_settings_sharp_screens')),
      matching: find.byType(SwitchListTile),
    );

    /// The page on a Meta Quest, the only device with the immersive viewer, in the build of the phones
    Future<void> pumpOnQuest(WidgetTester tester) async {
      await tester.pumpTestWidget(
        context,
        const AdvancedSettings(),
        overrides: [
          isHorizonOsProvider.overrideWith((ref) => true),
          appFlavorProvider.overrideWithValue(null),
          aiComponentsServiceProvider.overrideWithValue(FakeAiComponentsService()),
        ],
      );
      await tester.scrollUntilVisible(sharpSwitch, 100, scrollable: find.byType(Scrollable).first);
      // The whole tile on screen, its two line subtitle included, for the taps at its center
      await tester.ensureVisible(sharpSwitch);
      await tester.pumpAndSettle();
    }

    testWidgets('reads on by default, and says what it changes', (tester) async {
      await pumpOnQuest(tester);

      expect(find.text('Sharper flat screens (experimental)'), findsOneWidget);
      expect(
        find.text(
          'On a Meta Quest, the photos and videos of a flat screen go through the headset compositor, with its super '
          'sampling and sharpening. Off, they show as before.',
        ),
        findsOneWidget,
      );
      expect(tester.widget<SwitchListTile>(sharpSwitch).value, isTrue);
      expect(SettingsRepository.instance.appConfig.viewer.sharpFlatScreens, isTrue);
    });

    testWidgets('turns off and on again', (tester) async {
      await pumpOnQuest(tester);

      await tester.tap(sharpSwitch);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(sharpSwitch).value, isFalse);
      expect(SettingsRepository.instance.appConfig.viewer.sharpFlatScreens, isFalse);

      await tester.tap(sharpSwitch);
      await tester.pumpAndSettle();
      expect(SettingsRepository.instance.appConfig.viewer.sharpFlatScreens, isTrue);
    });

    testWidgets('is not offered on a phone, which has no immersive viewer', (tester) async {
      await tester.pumpTestWidget(
        context,
        const AdvancedSettings(),
        overrides: [isHorizonOsProvider.overrideWith((ref) => false)],
      );

      expect(find.byKey(const Key('advanced_settings_sharp_screens')), findsNothing);
    });
  });

  group('Gaussian splats (experimental)', () {
    final splatSwitch = find.descendant(
      of: find.byKey(const Key('advanced_settings_gaussian_splats')),
      matching: find.byType(SwitchListTile),
    );
    final largeSwitch = find.descendant(
      of: find.byKey(const Key('advanced_settings_large_splats')),
      matching: find.byType(SwitchListTile),
    );

    /// The page on a Meta Quest, the only device with the immersive viewer, in a GitHub build
    Future<void> pumpOnQuest(WidgetTester tester) async {
      await tester.pumpTestWidget(
        context,
        const AdvancedSettings(),
        overrides: [
          isHorizonOsProvider.overrideWith((ref) => true),
          splatsInThisBuildProvider.overrideWith((ref) => true),
          appFlavorProvider.overrideWithValue('quest'),
          aiComponentsServiceProvider.overrideWithValue(FakeAiComponentsService()),
        ],
      );
      await tester.scrollUntilVisible(largeSwitch, 100, scrollable: find.byType(Scrollable).first);
      await tester.ensureVisible(splatSwitch);
      await tester.pumpAndSettle();
    }

    testWidgets('Gaussian splats reads on by default, Large splats off, and they say what they change', (tester) async {
      await pumpOnQuest(tester);

      expect(find.text('Gaussian splats (experimental)'), findsOneWidget);
      expect(
        find.text(
          'Lists the .spz and .ply splats of the shares and opens them on a Meta Quest 3 or 3S\n'
          'Gaussian splats use an experimental API of the Meta Spatial SDK, which Meta neither supports nor warrants: '
          "any defect is Immuch360's own.",
        ),
        findsOneWidget,
      );
      expect(find.text('Large splats (experimental)'), findsOneWidget);
      expect(tester.widget<SwitchListTile>(splatSwitch).value, isTrue);
      expect(tester.widget<SwitchListTile>(largeSwitch).value, isFalse);
      await tester.ensureVisible(largeSwitch);
      await tester.pumpAndSettle();
      expect(
        find.text('Shows up to 1,000,000 gaussians instead of 300,000: a large splat may stutter'),
        findsOneWidget,
      );
    });

    testWidgets('Gaussian splats turns off, Large splats going with it; Large splats turns on', (tester) async {
      await pumpOnQuest(tester);

      await tester.tap(splatSwitch);
      await tester.pumpAndSettle();
      expect(SettingsRepository.instance.appConfig.viewer.gaussianSplats, isFalse);
      expect(find.byKey(const Key('advanced_settings_large_splats')), findsNothing);

      await tester.tap(splatSwitch);
      await tester.pumpAndSettle();
      expect(SettingsRepository.instance.appConfig.viewer.gaussianSplats, isTrue);
      await tester.ensureVisible(largeSwitch);
      await tester.pumpAndSettle();
      await tester.tap(largeSwitch);
      await tester.pumpAndSettle();
      expect(SettingsRepository.instance.appConfig.viewer.largeSplats, isTrue);
    });

    testWidgets('are not offered in the build of the Meta Horizon Store', (tester) async {
      await tester.pumpTestWidget(
        context,
        const AdvancedSettings(),
        overrides: [
          isHorizonOsProvider.overrideWith((ref) => true),
          splatsInThisBuildProvider.overrideWith((ref) => false),
          appFlavorProvider.overrideWithValue('quest'),
          aiComponentsServiceProvider.overrideWithValue(FakeAiComponentsService()),
        ],
      );
      final scrollable = find.byType(Scrollable).first;
      // Sharper flat screens, the setting right before the splats, stays
      await tester.scrollUntilVisible(
        find.byKey(const Key('advanced_settings_sharp_screens')),
        100,
        scrollable: scrollable,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('advanced_settings_gaussian_splats')), findsNothing);
      // Then the settings of the AI relief, which come right after the splats: none on the way
      await tester.scrollUntilVisible(
        find.byKey(const Key('advanced_settings_ai_enabled')),
        50,
        scrollable: scrollable,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('advanced_settings_gaussian_splats')), findsNothing);
      expect(find.byKey(const Key('advanced_settings_large_splats')), findsNothing);
    });

    testWidgets('on a phone or a tablet: the splat viewer, its words and its caps, no graphics card switch', (
      tester,
    ) async {
      await tester.pumpTestWidget(
        context,
        const AdvancedSettings(),
        overrides: [isHorizonOsProvider.overrideWith((ref) => false)],
      );
      await tester.scrollUntilVisible(largeSwitch, 100, scrollable: find.byType(Scrollable).first);
      await tester.ensureVisible(splatSwitch);
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Lists the .spz and .ply splats of your shares and folders and the splat scenes of your timeline, and opens '
          'them in 3D, to move through',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('Meta Spatial SDK'), findsNothing);
      await tester.ensureVisible(largeSwitch);
      await tester.pumpAndSettle();
      expect(find.text('Shows up to 500,000 gaussians instead of 150,000: a large splat may stutter'), findsOneWidget);
      expect(tester.widget<SwitchListTile>(largeSwitch).value, isFalse);
      expect(find.byKey(const Key('advanced_settings_splat_gpu')), findsNothing);
    });

    testWidgets('are not offered on a TV, which has no splat viewer', (tester) async {
      await tester.pumpTestWidget(
        context,
        const AdvancedSettings(),
        overrides: [
          isHorizonOsProvider.overrideWith((ref) => false),
          tvDeviceProvider.overrideWithValue(TvDeviceInfo(isTelevision: true, isLowRamDevice: false)),
        ],
      );

      expect(find.byKey(const Key('advanced_settings_gaussian_splats')), findsNothing);
      expect(find.byKey(const Key('advanced_settings_large_splats')), findsNothing);
    });

    testWidgets('on a Windows computer: Gaussian splats and the graphics card switch, on by default, no Large splats', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final gpuSwitch = find.descendant(
        of: find.byKey(const Key('advanced_settings_splat_gpu')),
        matching: find.byType(SwitchListTile),
      );
      await tester.pumpTestWidget(context, const AdvancedSettings());
      await tester.scrollUntilVisible(gpuSwitch, 100, scrollable: find.byType(Scrollable).first);
      await tester.ensureVisible(splatSwitch);
      await tester.pumpAndSettle();

      expect(tester.widget<SwitchListTile>(splatSwitch).value, isTrue);
      expect(find.byKey(const Key('advanced_settings_large_splats')), findsNothing);
      await tester.ensureVisible(gpuSwitch);
      await tester.pumpAndSettle();
      // Review of 2 November 2026: labelled experimental, and about the splats only (it moves the splats' WebView2)
      expect(find.text('Splats on the more powerful graphics card (experimental)'), findsOneWidget);
      expect(tester.widget<SwitchListTile>(gpuSwitch).value, isTrue);
      await tester.tap(gpuSwitch);
      await tester.pumpAndSettle();
      expect(SettingsRepository.instance.appConfig.viewer.highPerformanceGpu, isFalse);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('on a computer: Keep every gaussian, experimental, off by default (lot SVC); not on a phone', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final keepSwitch = find.descendant(
        of: find.byKey(const Key('advanced_settings_keep_all_gaussians')),
        matching: find.byType(SwitchListTile),
      );
      await tester.pumpTestWidget(context, const AdvancedSettings());
      await tester.scrollUntilVisible(keepSwitch, 100, scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();

      expect(find.text('Keep every gaussian (experimental)'), findsOneWidget);
      expect(find.byKey(const Key('advanced_settings_splat_gpu')), findsNothing, reason: 'Windows only');
      expect(tester.widget<SwitchListTile>(keepSwitch).value, isFalse);
      await tester.tap(keepSwitch);
      await tester.pumpAndSettle();
      expect(SettingsRepository.instance.appConfig.viewer.keepAllGaussians, isTrue);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('the mark of saved splat scenes: on by default on a phone and on the Quest, gone with the splats', (
      tester,
    ) async {
      final markSwitch = find.descendant(
        of: find.byKey(const Key('advanced_settings_mark_splat_photos')),
        matching: find.byType(SwitchListTile),
      );
      await tester.pumpTestWidget(
        context,
        const AdvancedSettings(),
        overrides: [isHorizonOsProvider.overrideWith((ref) => false)],
      );
      await tester.scrollUntilVisible(markSwitch, 100, scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      expect(find.text('Mark the photos of saved splat scenes'), findsOneWidget);
      expect(find.text('A small 3D sign in a corner tells them apart in Immich and other apps'), findsOneWidget);
      expect(tester.widget<SwitchListTile>(markSwitch).value, isTrue);
      await tester.tap(markSwitch);
      await tester.pumpAndSettle();
      expect(SettingsRepository.instance.appConfig.viewer.markSplatPhotos, isFalse);

      await tester.scrollUntilVisible(splatSwitch, -100, scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      await tester.tap(splatSwitch);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('advanced_settings_mark_splat_photos')), findsNothing);
    });

    testWidgets('the Quest of a GitHub build has the mark too', (tester) async {
      await pumpOnQuest(tester);
      await tester.scrollUntilVisible(
        find.byKey(const Key('advanced_settings_mark_splat_photos')),
        100,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Mark the photos of saved splat scenes'), findsOneWidget);
    });

    testWidgets('a phone has no Keep every gaussian: its caps stay', (tester) async {
      await tester.pumpTestWidget(
        context,
        const AdvancedSettings(),
        overrides: [isHorizonOsProvider.overrideWith((ref) => false)],
      );
      await tester.scrollUntilVisible(largeSwitch, 100, scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('advanced_settings_keep_all_gaussians')), findsNothing);
    });
  });

  group('DJI live video (experimental)', () {
    final linkSwitch = find.descendant(
      of: find.byKey(const Key('advanced_settings_dji_link')),
      matching: find.byType(SwitchListTile),
    );

    /// The page on a device that offers the DJI live video: an Android phone, tablet or headset, not a TV
    Future<void> pumpWhereSupported(WidgetTester tester, {FakeDjiLinkApi? api}) async {
      await tester.pumpTestWidget(
        context,
        const AdvancedSettings(),
        overrides: [
          djiLinkSupportedProvider.overrideWithValue(true),
          djiLinkApiProvider.overrideWithValue(api ?? FakeDjiLinkApi()),
        ],
      );
      await tester.scrollUntilVisible(linkSwitch, 100, scrollable: find.byType(Scrollable).first);
    }

    testWidgets('reads on by default', (tester) async {
      await pumpWhereSupported(tester);

      expect(find.text('DJI live video (experimental)'), findsOneWidget);
      expect(tester.widget<SwitchListTile>(linkSwitch).value, isTrue);
      expect(SettingsRepository.instance.appConfig.djiLinkEnabled, isTrue);
    });

    testWidgets('turns off and on again, and tells the native side each time', (tester) async {
      final api = FakeDjiLinkApi();
      await pumpWhereSupported(tester, api: api);

      await tester.tap(linkSwitch);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(linkSwitch).value, isFalse);
      expect(SettingsRepository.instance.appConfig.djiLinkEnabled, isFalse);

      await tester.tap(linkSwitch);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(linkSwitch).value, isTrue);
      expect(SettingsRepository.instance.appConfig.djiLinkEnabled, isTrue);
      // With the setting off, plugging the remote never opens the app
      expect(api.liveSettingSets, [false, true]);
    });

    testWidgets('on a TV: on by default with the words of a TV, and no import from a drone', (tester) async {
      await tester.pumpTestWidget(
        context,
        const AdvancedSettings(),
        overrides: [
          tvDeviceProvider.overrideWithValue(TvDeviceInfo(isTelevision: true, isLowRamDevice: false)),
          tvModeProvider.overrideWithValue(true),
          djiLinkApiProvider.overrideWithValue(FakeDjiLinkApi()),
        ],
      );
      await tester.scrollUntilVisible(linkSwitch, 100, scrollable: find.byType(Scrollable).first);
      expect(tester.widget<SwitchListTile>(linkSwitch).value, isTrue);
      expect(
        find.text(
          'The live picture of a DJI drone that a phone sends on this Wi-Fi. Nothing here can move the drone. '
          'On by default.',
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('advanced_settings_dji_import')), findsNothing);
    });

    testWidgets('is not offered on a device that has no cable to a remote controller', (tester) async {
      await tester.pumpTestWidget(
        context,
        const AdvancedSettings(),
        overrides: [djiLinkSupportedProvider.overrideWithValue(false)],
      );

      expect(find.byKey(const Key('advanced_settings_dji_link')), findsNothing);
    });
  });
}
