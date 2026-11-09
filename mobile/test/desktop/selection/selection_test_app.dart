// What the tests of the selection on a computer share: the window shell of the desktop (Control A and Escape) around a
// router, with the translations, and the keys held while a click is made.

import 'package:auto_route/auto_route.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/desktop/window/desktop_shell.dart';
import 'package:immich_mobile/desktop/window/full_screen.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:window_manager/window_manager.dart';

/// window_manager needs the runner: this one only remembers full screen
class FakeSelectionWindow extends DesktopWindow {
  bool fullScreen = false;

  @override
  Future<void> setFullScreen(bool fullScreen) async => this.fullScreen = fullScreen;

  @override
  Future<void> setPreventClose(bool preventClose) async {}

  @override
  Future<void> destroy() async {}

  @override
  void addListener(WindowListener listener) {}

  @override
  void removeListener(WindowListener listener) {}
}

/// [router] in the app of a computer: DesktopShell around the navigator, as main.dart does through desktopAppShell;
/// without the shell when [shell] is false (a phone)
Future<void> pumpSelectionApp(
  WidgetTester tester, {
  required RootStackRouter router,
  List<Override> overrides = const [],
  DesktopWindow? window,
  bool shell = true,
}) async {
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
        overrides: [desktopWindowProvider.overrideWithValue(window ?? FakeSelectionWindow()), ...overrides],
        child: Builder(
          builder: (context) => MaterialApp.router(
            debugShowCheckedModeBanner: false,
            routerConfig: router.config(),
            localizationsDelegates: context.localizationDelegates,
            supportedLocales: context.supportedLocales,
            locale: context.locale,
            builder: (context, child) => shell ? DesktopShell(child: child!) : child!,
          ),
        ),
      ),
    ),
  );
}

/// Holds [keys] down while [action] runs, then lets them go
Future<void> withKeys(WidgetTester tester, List<LogicalKeyboardKey> keys, Future<void> Function() action) async {
  for (final key in keys) {
    await tester.sendKeyDownEvent(key);
  }
  try {
    await action();
  } finally {
    for (final key in keys.reversed) {
      await tester.sendKeyUpEvent(key);
    }
  }
}

/// A click of the left button of a mouse on [finder]
Future<void> click(WidgetTester tester, Finder finder) => tester.tap(finder, kind: PointerDeviceKind.mouse);

/// A click of the right button of a mouse on [finder]
Future<void> rightClick(WidgetTester tester, Finder finder) =>
    tester.tap(finder, buttons: kSecondaryMouseButton, kind: PointerDeviceKind.mouse);

/// [key] with Control held (Command when [command]); whether the window took it
Future<bool> withShortcut(WidgetTester tester, LogicalKeyboardKey key, {bool command = false}) async {
  var handled = false;
  await withKeys(tester, [command ? LogicalKeyboardKey.metaLeft : LogicalKeyboardKey.controlLeft], () async {
    handled = await tester.sendKeyEvent(key);
  });
  return handled;
}
