import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/platform/video_decoder_api.g.dart';
import 'package:immich_mobile/presentation/pages/video_decoders.page.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_link_tile.widget.dart';
import 'package:immich_mobile/presentation/widgets/drone/drone_import_tile.widget.dart';
import 'package:immich_mobile/providers/asset_viewer/video_source.provider.dart';
import 'package:immich_mobile/providers/drone/dji_link.provider.dart';
import 'package:immich_mobile/widgets/settings/advanced_settings.dart';

import '../../presentation/pages/drone/dji_link_fakes.dart';
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
