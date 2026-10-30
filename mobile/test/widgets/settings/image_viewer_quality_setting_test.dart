// The Photos group of the viewer settings. On a TV (the remote control layout) it also offers "Show photo date and
// time", on by default: the date and time of a photo at the bottom left of the viewer, with its controls. A phone keeps
// the group as it was.

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/widgets/settings/asset_viewer_settings/image_viewer_quality_setting.dart';

import '../../unit/presentation/presentation_context.dart';

void main() {
  late PresentationContext context;

  setUp(() async {
    context = await PresentationContext.create();
  });

  tearDown(() async {
    await context.dispose();
  });

  final dateSwitch = find.widgetWithText(SwitchListTile, 'Show photo date and time');

  testWidgets('on a TV the Photos group offers "Show photo date and time", on by default', (tester) async {
    await tester.pumpTestWidget(
      context,
      const ImageViewerQualitySetting(),
      overrides: [tvModeProvider.overrideWithValue(true)],
    );

    expect(dateSwitch, findsOneWidget);
    expect(find.text('At the bottom left of the photo, while the controls show'), findsOneWidget);
    expect(tester.widget<SwitchListTile>(dateSwitch).value, isTrue);
    expect(find.byType(SwitchListTile), findsNWidgets(2), reason: 'after "Load original image"');
  });

  testWidgets('on a TV it turns the date and time of the photos off and on', (tester) async {
    await tester.pumpTestWidget(
      context,
      const ImageViewerQualitySetting(),
      overrides: [tvModeProvider.overrideWithValue(true)],
    );

    await tester.tap(dateSwitch);
    await tester.pumpAndSettle();
    expect(SettingsRepository.instance.appConfig.viewer.tvShowDateTime, isFalse);
    expect(tester.widget<SwitchListTile>(dateSwitch).value, isFalse);

    await tester.tap(dateSwitch);
    await tester.pumpAndSettle();
    expect(SettingsRepository.instance.appConfig.viewer.tvShowDateTime, isTrue);
  });

  testWidgets('on a TV in French', (tester) async {
    await tester.pumpWidget(
      EasyLocalization(
        supportedLocales: locales.values.toList(),
        path: translationsPath,
        startLocale: const Locale('fr'),
        fallbackLocale: locales.values.first,
        saveLocale: false,
        useFallbackTranslations: true,
        assetLoader: const CodegenLoader(),
        child: ProviderScope(
          overrides: [...context.overrides, tvModeProvider.overrideWithValue(true)],
          child: Builder(
            builder: (context) => MaterialApp(
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              home: const Scaffold(body: ImageViewerQualitySetting()),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text("Afficher la date et l'heure de la photo"), findsOneWidget);
    expect(find.text('En bas à gauche de la photo, quand les commandes sont affichées'), findsOneWidget);
  });

  testWidgets('a phone keeps the Photos group as it was', (tester) async {
    await tester.pumpTestWidget(
      context,
      const ImageViewerQualitySetting(),
      overrides: [tvModeProvider.overrideWithValue(false)],
    );

    expect(dateSwitch, findsNothing);
    expect(find.byType(SwitchListTile), findsOneWidget, reason: '"Load original image" only');
  });
}
