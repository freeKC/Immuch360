// The Remote control layout setting: Automatic, On or Off, written at once; Android only.

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/domain/models/config/app_config.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/providers/infrastructure/settings.provider.dart';
import 'package:immich_mobile/widgets/settings/preference_settings/tv_layout_setting.dart';

void main() {
  testWidgets('offers Automatic, On and Off, the stored one selected', (tester) async {
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
          overrides: [appConfigProvider.overrideWithValue(const AppConfig(tvLayout: TvLayoutMode.on))],
          child: Builder(
            builder: (context) => MaterialApp(
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              home: const Scaffold(body: SingleChildScrollView(child: TvLayoutSetting())),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Remote control layout'), findsOneWidget);
    for (final label in ['Automatic', 'On', 'Off']) {
      expect(find.widgetWithText(RadioListTile<TvLayoutMode>, label), findsOneWidget, reason: label);
    }
    final selected = tester
        .widgetList<RadioListTile<TvLayoutMode>>(find.byType(RadioListTile<TvLayoutMode>))
        .where((tile) => tile.value == TvLayoutMode.on);
    expect(selected, hasLength(1));
    expect(RadioGroup.maybeOf<TvLayoutMode>(tester.element(find.text('On')))?.groupValue, TvLayoutMode.on);
  });
}
