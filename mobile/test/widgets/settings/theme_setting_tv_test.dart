// The Theme setting on a TV: Automatic is dark there, so only the Dark mode switch is offered, on until the user
// turns it off, which stores Light. Off a TV the Automatic switch is still there.

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/domain/models/settings_key.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/platform/tv_api.g.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/providers/theme.provider.dart';
import 'package:immich_mobile/widgets/settings/preference_settings/theme_setting.dart';

import '../../unit/presentation/presentation_context.dart';

void main() {
  late PresentationContext context;

  setUp(() async {
    context = await PresentationContext.create();
  });

  tearDown(() async {
    await context.dispose();
  });

  final automatic = find.widgetWithText(SwitchListTile, 'Automatic (Follow system setting)');
  final darkMode = find.widgetWithText(SwitchListTile, 'Dark mode');

  /// The setting alone, as the Preferences page shows it, in one scope with the device of the test
  Future<void> pumpSetting(WidgetTester tester, {required bool isTelevision}) async {
    await tester.pumpWidget(
      EasyLocalization(
        supportedLocales: locales.values.toList(),
        path: translationsPath,
        startLocale: locales.values.first,
        fallbackLocale: locales.values.first,
        saveLocale: false,
        useFallbackTranslations: true,
        assetLoader: const CodegenLoader(),
        child: ProviderScope(
          overrides: [
            ...context.overrides,
            tvDeviceProvider.overrideWithValue(TvDeviceInfo(isTelevision: isTelevision, isLowRamDevice: false)),
          ],
          child: Builder(
            builder: (context) => MaterialApp(
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              home: const Scaffold(body: SingleChildScrollView(child: ThemeSetting())),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  ThemeMode stored() => SettingsRepository.instance.appConfig.theme.mode;

  ThemeMode appMode(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.byType(ThemeSetting))).read(appThemeModeProvider);

  group('on a TV', () {
    testWidgets('nothing stored: no Automatic switch, Dark mode on, the app dark', (tester) async {
      await pumpSetting(tester, isTelevision: true);

      expect(stored(), ThemeMode.system);
      expect(automatic, findsNothing);
      expect(darkMode, findsOneWidget);
      expect(tester.widget<SwitchListTile>(darkMode).value, isTrue);
      expect(appMode(tester), ThemeMode.dark);
    });

    testWidgets('Dark mode off stores Light and the app turns light; on again stores Dark', (tester) async {
      await pumpSetting(tester, isTelevision: true);

      await tester.tap(darkMode);
      await tester.pumpAndSettle();
      expect(stored(), ThemeMode.light);
      expect(tester.widget<SwitchListTile>(darkMode).value, isFalse);
      expect(appMode(tester), ThemeMode.light);

      await tester.tap(darkMode);
      await tester.pumpAndSettle();
      expect(stored(), ThemeMode.dark);
      expect(tester.widget<SwitchListTile>(darkMode).value, isTrue);
      expect(appMode(tester), ThemeMode.dark);
    });

    testWidgets('a stored Light choice is kept and shown off', (tester) async {
      await tester.runAsync(() => SettingsRepository.instance.write(SettingsKey.themeMode, ThemeMode.light));
      await pumpSetting(tester, isTelevision: true);

      expect(tester.widget<SwitchListTile>(darkMode).value, isFalse);
      expect(appMode(tester), ThemeMode.light);
    });
  });

  group('off a TV', () {
    testWidgets('Automatic on and no Dark mode switch, as before', (tester) async {
      await pumpSetting(tester, isTelevision: false);

      expect(tester.widget<SwitchListTile>(automatic).value, isTrue);
      expect(darkMode, findsNothing);
      expect(appMode(tester), ThemeMode.system);
    });

    testWidgets('Automatic off shows Dark mode, which stores Dark or Light', (tester) async {
      await pumpSetting(tester, isTelevision: false);

      await tester.tap(automatic);
      await tester.pumpAndSettle();
      expect(darkMode, findsOneWidget);
      // The test platform is light
      expect(stored(), ThemeMode.light);

      await tester.tap(darkMode);
      await tester.pumpAndSettle();
      expect(stored(), ThemeMode.dark);
      expect(appMode(tester), ThemeMode.dark);
    });
  });
}
