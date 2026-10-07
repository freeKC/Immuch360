// On a TV a link opens no web browser (Google Play criterion TV-WB): the address shows in a dialog, to be opened on a
// phone or a computer.

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/presentation/widgets/tv/open_url.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';

void main() {
  testWidgets('shows the address in a dialog instead of opening it', (tester) async {
    final results = <bool>[];
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
          overrides: [tvModeProvider.overrideWithValue(true)],
          child: Builder(
            builder: (context) => MaterialApp(
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              home: Builder(
                builder: (context) => TextButton(
                  onPressed: () async => results.add(await openUrl(context, Uri.parse('https://docs.immich.app'))),
                  child: const Text('link'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('link'));
    await tester.pumpAndSettle();

    expect(find.text('Open on another device'), findsOneWidget);
    expect(find.text('This TV cannot open web pages. Open this address on a phone or a computer:'), findsOneWidget);
    expect(find.text('https://docs.immich.app'), findsOneWidget);
    final close = find.widgetWithText(TextButton, 'Close');
    expect(Focus.of(tester.element(find.descendant(of: close, matching: find.text('Close')))).hasPrimaryFocus, isTrue);

    await tester.tap(close);
    await tester.pumpAndSettle();
    expect(find.text('Open on another device'), findsNothing);
    expect(results, [false], reason: 'nothing was launched');
  });
}
