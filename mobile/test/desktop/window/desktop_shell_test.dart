// The window of Immuch360 Desktop (design 1.8, 4.2 and 4.4): F11 anywhere and F in a viewer toggle full screen,
// Escape and the back button of a mouse leave it first, then close the viewer, a dialog keeps its own Escape, a letter
// typed in a text field stays there, leaving the viewer that went full screen leaves it, and the close button asks
// first while uploads or the share of the computer run.

import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/desktop/window/close_guard.dart';
import 'package:immich_mobile/desktop/window/desktop_shell.dart';
import 'package:immich_mobile/desktop/window/full_screen.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:window_manager/window_manager.dart';

/// window_manager needs the runner: this one records what the app asks of the window
class FakeDesktopWindow extends DesktopWindow {
  FakeDesktopWindow();

  final calls = <String>[];
  final listeners = <WindowListener>[];
  bool fullScreen = false;

  @override
  Future<void> setFullScreen(bool fullScreen) async {
    this.fullScreen = fullScreen;
    calls.add('fullScreen $fullScreen');
  }

  @override
  Future<void> setPreventClose(bool preventClose) async => calls.add('preventClose $preventClose');

  @override
  Future<void> destroy() async => calls.add('destroy');

  @override
  void addListener(WindowListener listener) => listeners.add(listener);

  @override
  void removeListener(WindowListener listener) => listeners.remove(listener);

  /// The close button of the window, with setPreventClose on
  void clickClose() {
    for (final listener in [...listeners]) {
      listener.onWindowClose();
    }
  }
}

/// A viewer: a page that takes the keys, with the full screen button of the desktop in its app bar
class _Viewer extends StatelessWidget {
  const _Viewer({required this.label, this.withField = false});

  final String label;
  final bool withField;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(label), actions: const [DesktopFullScreenButton()]),
    body: Focus(
      autofocus: true,
      child: Column(
        children: [
          Text('$label body'),
          if (withField) const TextField(key: Key('viewer_field')),
        ],
      ),
    ),
  );
}

void main() {
  late FakeDesktopWindow window;
  late GlobalKey<NavigatorState> navigatorKey;
  late Set<DesktopCloseReason> reasons;
  late int backs;

  setUp(() {
    window = FakeDesktopWindow();
    navigatorKey = GlobalKey<NavigatorState>();
    reasons = {};
    backs = 0;
  });

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  Future<void> pumpShell(WidgetTester tester) async {
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
            desktopWindowProvider.overrideWithValue(window),
            desktopNavigatorKeyProvider.overrideWithValue(navigatorKey),
            desktopCloseReasonsProvider.overrideWithValue(() => reasons),
            desktopBackProvider.overrideWithValue(() async {
              backs++;
              return navigatorKey.currentState!.maybePop();
            }),
          ],
          child: Builder(
            builder: (context) => MaterialApp(
              navigatorKey: navigatorKey,
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              builder: (context, child) => DesktopShell(child: child!),
              home: const Scaffold(
                body: Focus(
                  autofocus: true,
                  child: Column(
                    children: [
                      Text('grid'),
                      TextField(key: Key('search')),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  NavigatorState navigator() => navigatorKey.currentState!;

  /// Opens a viewer by its route name, as the router does
  Future<void> openViewer(WidgetTester tester, {String label = 'viewer', bool withField = false}) async {
    unawaited(
      navigator().push(
        MaterialPageRoute<void>(
          settings: const RouteSettings(name: AssetViewerRoute.name),
          builder: (_) => _Viewer(label: label, withField: withField),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  bool isFullScreen(WidgetTester tester) =>
      ProviderScope.containerOf(tester.element(find.byType(DesktopShell))).read(desktopFullScreenProvider);

  testWidgets('the window asks the app before closing', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await pumpShell(tester);
    expect(window.calls, ['preventClose true']);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('F11 goes full screen anywhere, Escape leaves it', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await pumpShell(tester);

    expect(await tester.sendKeyEvent(LogicalKeyboardKey.f11), isTrue);
    await tester.pump();
    expect(isFullScreen(tester), isTrue);
    expect(window.fullScreen, isTrue);

    expect(await tester.sendKeyEvent(LogicalKeyboardKey.escape), isTrue);
    await tester.pump();
    expect(isFullScreen(tester), isFalse);
    expect(window.calls, ['preventClose true', 'fullScreen true', 'fullScreen false']);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('F toggles full screen in a viewer only', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await pumpShell(tester);

    expect(await tester.sendKeyEvent(LogicalKeyboardKey.keyF), isFalse, reason: 'not a viewer');
    expect(isFullScreen(tester), isFalse);

    await openViewer(tester);
    expect(await tester.sendKeyEvent(LogicalKeyboardKey.keyF), isTrue);
    await tester.pump();
    expect(isFullScreen(tester), isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.pump();
    expect(isFullScreen(tester), isFalse);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a letter typed in a text field of a viewer stays in the field', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await pumpShell(tester);
    await openViewer(tester, withField: true);

    await tester.tap(find.byKey(const Key('viewer_field')));
    await tester.pump();
    // Not handled: the engine then gives the character to the text input
    expect(await tester.sendKeyEvent(LogicalKeyboardKey.keyF), isFalse);
    // Escape belongs to the field too (Flutter's own text editing actions answer it)
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(isFullScreen(tester), isFalse);
    expect(find.text('viewer body'), findsOneWidget, reason: 'Escape in the field does not close the viewer');
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Escape leaves full screen first, then closes the viewer; a dialog closes before both', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await pumpShell(tester);
    await openViewer(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.pumpAndSettle();
    expect(isFullScreen(tester), isTrue);

    unawaited(
      showDialog<void>(
        context: navigatorKey.currentContext!,
        builder: (context) => const AlertDialog(content: Text('a dialog')),
      ),
    );
    await tester.pumpAndSettle();
    expect(await tester.sendKeyEvent(LogicalKeyboardKey.escape), isTrue);
    await tester.pumpAndSettle();
    expect(find.text('a dialog'), findsNothing);
    expect(isFullScreen(tester), isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(isFullScreen(tester), isFalse);
    expect(find.text('viewer body'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('viewer body'), findsNothing);
    expect(find.text('grid'), findsOneWidget);

    expect(await tester.sendKeyEvent(LogicalKeyboardKey.escape), isFalse, reason: 'nothing to close on the grid');
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('leaving the viewer that went full screen leaves full screen', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await pumpShell(tester);
    await openViewer(tester);
    await tester.tap(find.byKey(const Key('desktop_full_screen')));
    await tester.pumpAndSettle();
    expect(isFullScreen(tester), isTrue);

    // The Close button of the viewer
    navigator().pop();
    await tester.pumpAndSettle();
    expect(isFullScreen(tester), isFalse);
    expect(window.fullScreen, isFalse);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a viewer that gives way to another keeps full screen', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await pumpShell(tester);
    await openViewer(tester, label: 'first');
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.pumpAndSettle();

    // The next photo of a network folder replaces the page
    unawaited(
      navigator().pushReplacement(
        MaterialPageRoute<void>(
          settings: const RouteSettings(name: NetworkPhotoRoute.name),
          builder: (_) => const _Viewer(label: 'second'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('second body'), findsOneWidget);
    expect(isFullScreen(tester), isTrue);

    // A 360° view opened without a route name, known by its full screen button, closes onto the photo
    unawaited(navigator().push(MaterialPageRoute<void>(builder: (_) => const _Viewer(label: 'sphere'))));
    await tester.pumpAndSettle();
    navigator().pop();
    await tester.pumpAndSettle();
    expect(isFullScreen(tester), isTrue);

    navigator().pop();
    await tester.pumpAndSettle();
    expect(find.text('grid'), findsOneWidget);
    expect(isFullScreen(tester), isFalse);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('full screen asked from the grid stays when a viewer closes', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await pumpShell(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    await tester.pumpAndSettle();
    await openViewer(tester);
    navigator().pop();
    await tester.pumpAndSettle();
    expect(isFullScreen(tester), isTrue);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('the system taking the window out of full screen is followed', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    await pumpShell(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.f11);
    await tester.pump();
    for (final listener in [...window.listeners]) {
      listener.onWindowLeaveFullScreen();
    }
    await tester.pump();
    expect(isFullScreen(tester), isFalse);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('the back button of a mouse leaves full screen, then goes back', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await pumpShell(tester);
    await openViewer(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.pumpAndSettle();

    final center = tester.getCenter(find.text('viewer body'));
    Future<void> clickBack() async {
      final gesture = await tester.startGesture(center, kind: PointerDeviceKind.mouse, buttons: kBackMouseButton);
      await gesture.up();
      await tester.pumpAndSettle();
    }

    await clickBack();
    expect(isFullScreen(tester), isFalse);
    expect(backs, 0);
    expect(find.text('viewer body'), findsOneWidget);

    await clickBack();
    expect(backs, 1);
    expect(find.text('viewer body'), findsNothing);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('the full screen button names what it does, for screen readers too', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final semantics = tester.ensureSemantics();
    await pumpShell(tester);
    await openViewer(tester);

    expect(find.byTooltip('Full screen'), findsOneWidget);
    expect(find.semantics.byPredicate((node) => node.tooltip == 'Full screen'), findsOne);
    await tester.tap(find.byKey(const Key('desktop_full_screen')));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Exit full screen'), findsOneWidget);
    expect(find.byIcon(Icons.fullscreen_exit_rounded), findsOneWidget);
    semantics.dispose();
    debugDefaultTargetPlatformOverride = null;
  });

  group('the close button of the window', () {
    testWidgets('closes at once when nothing runs', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await pumpShell(tester);
      window.clickClose();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(window.calls, contains('destroy'));
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('asks while uploads and the share run; Cancel keeps the app, Quit closes it', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      reasons = {DesktopCloseReason.uploads, DesktopCloseReason.computerShare};
      await pumpShell(tester);

      window.clickClose();
      await tester.pumpAndSettle();
      expect(find.text('Quit Immuch360 Desktop?'), findsOneWidget);
      expect(find.textContaining('Uploads are running'), findsOneWidget);
      expect(find.textContaining('This computer is shared on the network'), findsOneWidget);
      // Cancel has the focus: Enter never quits by surprise
      expect(
        FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<TextButton>()?.key,
        const Key('desktop_close_cancel'),
      );

      // A second click while the dialog shows opens no second dialog
      window.clickClose();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);

      await tester.tap(find.byKey(const Key('desktop_close_cancel')));
      await tester.pumpAndSettle();
      expect(window.calls, isNot(contains('destroy')));

      window.clickClose();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('desktop_close_quit')));
      await tester.pumpAndSettle();
      expect(window.calls, contains('destroy'));
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('the dialog follows Tab from Cancel to Quit', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      reasons = {DesktopCloseReason.uploads};
      await pumpShell(tester);
      window.clickClose();
      await tester.pumpAndSettle();

      Key? focusedButton() =>
          FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<TextButton>()?.key;
      expect(focusedButton(), const Key('desktop_close_cancel'));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(focusedButton(), const Key('desktop_close_quit'));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(window.calls, isNot(contains('destroy')));
      debugDefaultTargetPlatformOverride = null;
    });
  });
}
