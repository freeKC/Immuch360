// The app around the widgets of "Play on the TV" in their tests: the English texts, the providers given, a phone held
// upright

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';

/// A phone held upright
void playOnPhoneScreen(WidgetTester tester) {
  tester.view
    ..physicalSize = const Size(1080, 2400)
    ..devicePixelRatio = 2.7;
  addTearDown(tester.view.reset);
}

Future<void> pumpPlayOn(WidgetTester tester, Widget home, {List<Override> overrides = const []}) async {
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
        overrides: overrides,
        child: Builder(
          builder: (context) => MaterialApp(
            debugShowCheckedModeBanner: false,
            localizationsDelegates: context.localizationDelegates,
            supportedLocales: context.supportedLocales,
            locale: context.locale,
            home: home,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// A page with a button "open" that runs [open] with its context
Widget playOnOpener(Future<void> Function(BuildContext context) open) => Builder(
  builder: (context) => Scaffold(
    body: Center(
      child: TextButton(onPressed: () => open(context), child: const Text('open')),
    ),
  ),
);
