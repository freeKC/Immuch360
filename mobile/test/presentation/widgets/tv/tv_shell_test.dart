// The remote control layout around the app: Flutter's directional navigation, the overscan margins of the TV
// guidelines, channel up and down for pages, up and down out of a text field and out of a group of radio buttons, and
// the focus always highlighted.

import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_focus_ring.widget.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_shell.widget.dart';

void main() {
  Future<void> pump(WidgetTester tester, Widget home, {bool tvMode = true}) async {
    await tester.pumpWidget(
      MaterialApp(
        // As main.dart does
        builder: (context, child) => TvShell(enabled: tvMode, child: child!),
        home: home,
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('directional navigation and overscan margins of at least 48 x 27', (tester) async {
    late MediaQueryData media;
    await pump(
      tester,
      Builder(
        builder: (context) {
          media = MediaQuery.of(context);
          return const SizedBox.shrink();
        },
      ),
    );

    expect(media.navigationMode, NavigationMode.directional);
    expect(media.padding, const EdgeInsets.symmetric(horizontal: 48, vertical: 27));
    expect(media.viewPadding, const EdgeInsets.symmetric(horizontal: 48, vertical: 27));
    expect(find.byType(TvFocusRing), findsOneWidget);
  });

  testWidgets('off, it hands the screen, the keys and the focus down as they are, without a ring', (tester) async {
    const system = MediaQueryData(size: Size(960, 540), padding: EdgeInsets.only(top: 40));
    late MediaQueryData media;
    final before = FocusManager.instance.highlightStrategy;
    await tester.pumpWidget(
      MediaQuery(
        data: system,
        child: TvShell(
          enabled: false,
          child: Builder(
            builder: (context) {
              media = MediaQuery.of(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );

    expect(media, system);
    expect(FocusManager.instance.highlightStrategy, before);
    expect(find.byType(CustomPaint), findsNothing, reason: 'no ring painter');
  });

  testWidgets('keeps a larger system padding', (tester) async {
    late MediaQueryData media;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(960, 540), padding: EdgeInsets.only(top: 40)),
        child: TvShell(
          child: Builder(
            builder: (context) {
              media = MediaQuery.of(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );

    expect(media.padding, const EdgeInsets.fromLTRB(48, 40, 48, 27));
  });

  testWidgets('the focus highlight always shows while it is there, and is given back after', (tester) async {
    final before = FocusManager.instance.highlightStrategy;
    await pump(tester, const SizedBox.shrink());
    expect(FocusManager.instance.highlightStrategy, FocusHighlightStrategy.alwaysTraditional);

    await pump(tester, const SizedBox.shrink(), tvMode: false);
    expect(FocusManager.instance.highlightStrategy, before);
  });

  testWidgets('channel down and up scroll the focused list by a page', (tester) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await pump(
      tester,
      Scaffold(
        body: ListView(
          controller: controller,
          children: [
            ListTile(autofocus: true, title: const Text('first'), onTap: () {}),
            for (var i = 0; i < 100; i++) ListTile(title: Text('row $i'), onTap: () {}),
          ],
        ),
      ),
    );
    expect(controller.offset, 0);

    await tester.sendKeyEvent(LogicalKeyboardKey.channelDown);
    await tester.pumpAndSettle();
    final page = controller.offset;
    expect(page, greaterThan(200), reason: 'about a screen');

    await tester.sendKeyEvent(LogicalKeyboardKey.channelUp);
    await tester.pumpAndSettle();
    expect(controller.offset, lessThan(page));
  });

  for (final (key, target) in [(LogicalKeyboardKey.arrowDown, 'below'), (LogicalKeyboardKey.arrowUp, 'above')]) {
    testWidgets('${key.keyLabel} leaves a text field that has the focus', (tester) async {
      final field = FocusNode();
      addTearDown(field.dispose);
      await pump(
        tester,
        Scaffold(
          body: Column(
            children: [
              ElevatedButton(onPressed: () {}, child: const Text('above')),
              TextField(focusNode: field),
              ElevatedButton(onPressed: () {}, child: const Text('below')),
            ],
          ),
        ),
      );
      field.requestFocus();
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(key);
      await tester.pumpAndSettle();

      expect(field.hasFocus, isFalse);
      expect(Focus.of(tester.element(find.text(target))).hasFocus, isTrue);
    });
  }

  testWidgets('out of the remote control layout a text field keeps up and down for its caret', (tester) async {
    final field = FocusNode();
    addTearDown(field.dispose);
    await pump(
      tester,
      Scaffold(
        body: Column(
          children: [
            TextField(focusNode: field),
            ElevatedButton(onPressed: () {}, child: const Text('below')),
          ],
        ),
      ),
      tvMode: false,
    );
    field.requestFocus();
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();

    expect(field.hasFocus, isTrue);
  });

  group('a group of radio buttons', () {
    late String? picked;

    Widget radios() => StatefulBuilder(
      builder: (context, setState) => Scaffold(
        body: Column(
          children: [
            RadioGroup<String>(
              groupValue: picked,
              onChanged: (value) => setState(() => picked = value),
              child: const Column(
                children: [
                  RadioListTile<String>(key: Key('first'), value: 'first', title: Text('first')),
                  RadioListTile<String>(key: Key('second'), value: 'second', title: Text('second')),
                  RadioListTile<String>(key: Key('third'), value: 'third', title: Text('third')),
                ],
              ),
            ),
            ElevatedButton(onPressed: () {}, child: const Text('below')),
          ],
        ),
      ),
    );

    bool focused(WidgetTester tester, String text) => Focus.of(tester.element(find.text(text))).hasFocus;

    setUp(() => picked = 'first');

    testWidgets('the arrows move the focus through the choices and out of the group, OK picks one', (tester) async {
      await pump(tester, radios());
      Focus.of(tester.element(find.text('first'))).requestFocus();
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(focused(tester, 'second'), isTrue);
      expect(picked, 'first', reason: 'a move is no choice');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(picked, 'first', reason: 'nor are left and right');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(focused(tester, 'below'), isTrue, reason: 'the focus leaves the group');
      expect(picked, 'first');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(focused(tester, 'third'), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(picked, 'third', reason: 'OK picks the choice that has the focus');
      expect(focused(tester, 'third'), isTrue);
    });

    testWidgets('out of the remote control layout the arrows keep choosing, as Flutter does', (tester) async {
      await pump(tester, radios(), tvMode: false);
      Focus.of(tester.element(find.text('first'))).requestFocus();
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();

      expect(picked, 'second');
    });
  });

  group('turning the remote control layout on or off', () {
    late int splashStarts;

    setUp(() => splashStarts = 0);

    /// An app with a splash screen that starts the session and leaves for Home, and a settings page with a state
    Future<RootStackRouter> pumpApp(WidgetTester tester, ValueNotifier<bool> tvMode) async {
      final router = RootStackRouter.build(
        routes: [
          AutoRoute(
            path: '/',
            initial: true,
            page: PageInfo('Splash', builder: (_) => _Splash(onStart: () => splashStarts++)),
          ),
          AutoRoute(
            path: '/home',
            page: PageInfo('Home', builder: (_) => const Scaffold(body: Text('home'))),
          ),
          AutoRoute(
            path: '/settings',
            page: PageInfo('Settings', builder: (_) => const _Settings()),
          ),
        ],
      );
      await tester.pumpWidget(
        ValueListenableBuilder<bool>(
          valueListenable: tvMode,
          builder: (context, tv, _) => MaterialApp.router(
            // As main.dart does
            builder: (context, child) => TvShell(enabled: tv, child: child!),
            // As main.dart does with a link that is not one of Immich: to its path
            routerConfig: router.config(deepLinkBuilder: (link) => DeepLink.path(link.path)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return router;
    }

    for (final start in [false, true]) {
      testWidgets('${start ? 'on a TV' : 'on a phone'} the open page takes the other layout, nothing starts again', (
        tester,
      ) async {
        final tvMode = ValueNotifier(start);
        addTearDown(tvMode.dispose);
        final strategy = FocusManager.instance.highlightStrategy;
        final router = await pumpApp(tester, tvMode);
        expect(splashStarts, 1);
        unawaited(router.push(const PageRouteInfo('Settings')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Preferences'));
        await tester.pumpAndSettle();
        final routes = router.stackData.map((route) => route.name).toList();
        expect(routes, ['Home', 'Settings']);

        for (final on in [!start, start, !start]) {
          tvMode.value = on;
          await tester.pumpAndSettle();

          expect(router.stackData.map((route) => route.name), routes, reason: 'no splash screen pushed');
          expect(splashStarts, 1, reason: 'no second start of the session');
          expect(find.text('Preferences shown'), findsOneWidget, reason: 'the page keeps its state');
          expect(find.text(on ? 'directional' : 'traditional'), findsOneWidget, reason: 'in the other layout');
          expect(FocusManager.instance.highlightStrategy, on ? FocusHighlightStrategy.alwaysTraditional : strategy);
        }
      });
    }
  });
}

/// Starts the session once, then leaves for Home as the splash screen of the app does
class _Splash extends StatefulWidget {
  const _Splash({required this.onStart});

  final VoidCallback onStart;

  @override
  State<_Splash> createState() => _SplashState();
}

class _SplashState extends State<_Splash> {
  @override
  void initState() {
    super.initState();
    widget.onStart();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(context.router.replace(const PageRouteInfo('Home')));
      }
    });
  }

  @override
  Widget build(BuildContext context) => const Scaffold(body: Text('splash'));
}

/// Shows its first section until Preferences is picked, as the two panes of the settings do, and the navigation mode
class _Settings extends StatefulWidget {
  const _Settings();

  @override
  State<_Settings> createState() => _SettingsState();
}

class _SettingsState extends State<_Settings> {
  var _preferences = false;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Column(
      children: [
        TextButton(onPressed: () => setState(() => _preferences = true), child: const Text('Preferences')),
        Text(_preferences ? 'Preferences shown' : 'Advanced shown'),
        Text(MediaQuery.navigationModeOf(context).name),
      ],
    ),
  );
}
