// In the remote control layout an item always has the focus: a page that focuses nothing by itself gets its first
// item, an item of the page rather than the Back button of its app bar, and a page that focused one keeps it. A list
// that comes after loading takes the focus from the Back button the page had meanwhile, unless the user moved it. The
// keys that move or press wait while a route opens: before its first frame they would reach the page under it.

import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/providers/api.provider.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/routing/app_navigation_observer.dart';
import 'package:immich_mobile/routing/route_opening_key_gate.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/services/auth.service.dart';
import 'package:immich_mobile/services/local_auth.service.dart';
import 'package:immich_mobile/services/secure_storage.service.dart';
import 'package:mocktail/mocktail.dart';

import '../service.mocks.dart';

class _LocalAuthService extends Mock implements LocalAuthService {}

/// The app with the real navigation observer, in the remote control layout, and a button that pushes [page]
class _ObservedApp extends ConsumerStatefulWidget {
  const _ObservedApp({required this.page});

  final Widget page;

  @override
  ConsumerState<_ObservedApp> createState() => _ObservedAppState();
}

class _ObservedAppState extends ConsumerState<_ObservedApp> {
  late final _observer = AppNavigationObserver(ref: ref);

  @override
  Widget build(BuildContext context) => MaterialApp(
    navigatorObservers: [_observer],
    home: Builder(
      builder: (context) => Scaffold(
        body: TextButton(
          onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => widget.page)),
          child: const Text('open'),
        ),
      ),
    ),
  );
}

/// A page whose list comes once [list] completes, like a folder of a share: its first item asks for the focus when
/// [autofocusFirst]
class _LoadingPage extends StatelessWidget {
  const _LoadingPage({required this.list, this.autofocusFirst = true, this.onOpen});

  final Future<void> list;
  final bool autofocusFirst;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('folder'),
      actions: [IconButton(icon: const Icon(Icons.refresh), tooltip: 'Refresh', onPressed: () {})],
    ),
    body: FutureBuilder<void>(
      future: list,
      builder: (context, snapshot) => snapshot.connectionState == ConnectionState.done
          ? Column(
              children: [
                ListTile(autofocus: autofocusFirst, title: const Text('first folder'), onTap: onOpen ?? () {}),
                ListTile(title: const Text('second folder'), onTap: () {}),
              ],
            )
          : const Center(child: CircularProgressIndicator()),
    ),
  );
}

/// A page without an app bar whose list comes once [list] completes, like the 360° list: nothing to focus meanwhile
class _BarelessLoadingPage extends StatelessWidget {
  const _BarelessLoadingPage({required this.list});

  final Future<void> list;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: FutureBuilder<void>(
      future: list,
      builder: (context, snapshot) => snapshot.connectionState == ConnectionState.done
          ? Column(
              children: [
                ListTile(title: const Text('first item'), onTap: () {}),
                ListTile(title: const Text('second item'), onTap: () {}),
              ],
            )
          : const Center(child: CircularProgressIndicator()),
    ),
  );
}

/// A page like an album of the server on a TV: a header of [headerHeight] dp (400 by default) over its grid, whose
/// first tile is then under the bottom of the screen of a TV. Once [content] completes it shows, with the header when
/// [headerFirst] is false (the album page shows nothing until its album and its first tiles are read), else under the
/// header shown from the start.
class _TallHeaderPage extends StatelessWidget {
  const _TallHeaderPage({required this.content, this.headerFirst = false, this.headerHeight = 400});

  final Future<void> content;
  final bool headerFirst;
  final double headerHeight;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: FutureBuilder<void>(
      future: content,
      builder: (context, snapshot) {
        final loaded = snapshot.connectionState == ConnectionState.done;
        if (!loaded && !headerFirst) {
          return const SizedBox.shrink();
        }
        return CustomScrollView(
          slivers: [
            SliverAppBar(
              expandedHeight: headerHeight,
              pinned: true,
              leading: IconButton(icon: const Icon(Icons.arrow_back), tooltip: 'Back', onPressed: () {}),
              actions: [IconButton(icon: const Icon(Icons.slideshow_outlined), tooltip: 'Slideshow', onPressed: () {})],
              flexibleSpace: const FlexibleSpaceBar(background: ColoredBox(color: Colors.blueGrey)),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 60, child: Text('November 2024'))),
            if (loaded)
              SliverGrid.count(
                crossAxisCount: 4,
                children: [
                  for (var i = 0; i < 8; i++)
                    InkWell(
                      key: ValueKey('tile $i'),
                      onTap: () {},
                      child: Center(child: Text('tile $i')),
                    ),
                ],
              ),
          ],
        );
      },
    ),
  );
}

/// The app with the real navigation observer: "open" has the focus and pushes [page], "below" is under it. Each tap is
/// noted in [taps], and each key that reaches the first page in [keys].
class _OpenerApp extends ConsumerStatefulWidget {
  const _OpenerApp({required this.page, required this.taps, required this.keys});

  final Widget page;
  final List<String> taps;
  final List<KeyEvent> keys;

  @override
  ConsumerState<_OpenerApp> createState() => _OpenerAppState();
}

class _OpenerAppState extends ConsumerState<_OpenerApp> {
  late final _observer = AppNavigationObserver(ref: ref);

  @override
  Widget build(BuildContext context) => MaterialApp(
    navigatorObservers: [_observer],
    home: Builder(
      builder: (context) => Scaffold(
        body: Focus(
          onKeyEvent: (_, event) {
            widget.keys.add(event);
            return KeyEventResult.ignored;
          },
          child: Column(
            children: [
              TextButton(
                autofocus: true,
                onPressed: () {
                  widget.taps.add('open');
                  Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => widget.page)).ignore();
                },
                child: const Text('open'),
              ),
              TextButton(onPressed: () => widget.taps.add('below'), child: const Text('below')),
            ],
          ),
        ),
      ),
    ),
  );
}

/// A page with two items, the first one focused by itself; each key that reaches it is noted in [keys]
class _OpenedPage extends StatelessWidget {
  const _OpenedPage({required this.taps, required this.keys});

  final List<String> taps;
  final List<KeyEvent> keys;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Focus(
      onKeyEvent: (_, event) {
        keys.add(event);
        return KeyEventResult.ignored;
      },
      child: Column(
        children: [
          TextButton(autofocus: true, onPressed: () => taps.add('first'), child: const Text('first')),
          TextButton(onPressed: () => taps.add('second'), child: const Text('second')),
        ],
      ),
    ),
  );
}

/// A guard that lets the page through after an await, as the app's duplicate guard does
class _AsyncGuard extends AutoRouteGuard {
  @override
  Future<void> onNavigation(NavigationResolver resolver, StackRouter router) async => resolver.next(true);
}

void main() {
  Future<ModalRoute<void>> pushPage(WidgetTester tester, {bool autofocusSecond = false}) async {
    late ModalRoute<void> route;
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    route = MaterialPageRoute<void>(
      builder: (context) => Scaffold(
        body: Column(
          children: [
            const Text('a title'),
            TextButton(onPressed: () {}, child: const Text('first')),
            TextButton(autofocus: autofocusSecond, onPressed: () {}, child: const Text('second')),
          ],
        ),
      ),
    );
    navigator.push(route).ignore();
    await tester.pumpAndSettle();
    return route;
  }

  bool hasFocus(WidgetTester tester, String text) => Focus.of(tester.element(find.text(text))).hasPrimaryFocus;

  testWidgets('focuses the first item of a page that focuses nothing by itself', (tester) async {
    final route = await pushPage(tester);
    expect(hasFocus(tester, 'first'), isFalse);

    focusFirstItemIfNone(route);
    await tester.pump();

    expect(hasFocus(tester, 'first'), isTrue);
  });

  testWidgets('leaves the item a page focused by itself', (tester) async {
    final route = await pushPage(tester, autofocusSecond: true);
    expect(hasFocus(tester, 'second'), isTrue);

    focusFirstItemIfNone(route);
    await tester.pump();

    expect(hasFocus(tester, 'second'), isTrue);
  });

  testWidgets('does nothing for a route that is no longer the current one', (tester) async {
    final route = await pushPage(tester);
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('above')))).ignore();
    await tester.pumpAndSettle();

    focusFirstItemIfNone(route);
    await tester.pump();

    expect(find.text('first'), findsNothing);
  });

  group('through the navigation observer', () {
    bool hasFocus(WidgetTester tester, Finder finder) => Focus.of(tester.element(finder)).hasPrimaryFocus;
    final back = find.descendant(of: find.byType(BackButton), matching: find.byType(Icon));
    final refresh = find.descendant(of: find.byTooltip('Refresh'), matching: find.byType(Icon));

    Future<void> open(WidgetTester tester, Widget page) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [tvModeProvider.overrideWithValue(true)],
          child: _ObservedApp(page: page),
        ),
      );
      await tester.tap(find.text('open'));
      // The page and its transition, its list still loading
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    testWidgets('a list that comes after loading takes the focus from the Back button', (tester) async {
      final list = Completer<void>();
      var opened = 0;
      await open(tester, _LoadingPage(list: list.future, onOpen: () => opened++));
      expect(hasFocus(tester, back), isTrue, reason: 'nothing else to focus while the list loads');

      list.complete();
      await tester.pump();
      await tester.pump();

      expect(hasFocus(tester, find.text('first folder')), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect(opened, 1, reason: 'OK opens the first folder');
      expect(find.text('folder'), findsOneWidget, reason: 'and does not leave the page');
    });

    testWidgets('a list without an autofocus gets the focus on its first item', (tester) async {
      final list = Completer<void>();
      await open(tester, _LoadingPage(list: list.future, autofocusFirst: false));

      list.complete();
      await tester.pump();
      await tester.pump();

      expect(hasFocus(tester, find.text('first folder')), isTrue);
    });

    testWidgets('a page with nothing to focus while it loads, not even a bar, gets its first item once it shows', (
      tester,
    ) async {
      final list = Completer<void>();
      await open(tester, _BarelessLoadingPage(list: list.future));

      list.complete();
      await tester.pump();
      await tester.pump();

      expect(hasFocus(tester, find.text('first item')), isTrue, reason: 'not the page itself, which nothing shows');
    });

    testWidgets('an item of the page is focused rather than the Back button of its app bar', (tester) async {
      await open(tester, _LoadingPage(list: Future<void>.value(), autofocusFirst: false));
      await tester.pumpAndSettle();

      expect(hasFocus(tester, find.text('first folder')), isTrue);
    });

    testWidgets('where the user moved the focus while the list loaded, it stays', (tester) async {
      final list = Completer<void>();
      await open(tester, _LoadingPage(list: list.future));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      expect(hasFocus(tester, refresh), isTrue);

      list.complete();
      await tester.pump();
      await tester.pump();

      expect(hasFocus(tester, refresh), isTrue);
      expect(hasFocus(tester, find.text('first folder')), isFalse);
    });

    group('a page whose first item comes under the bottom of the screen (an album of the server)', () {
      final firstTile = find.byKey(const ValueKey('tile 0'));

      /// The screen of a TV, 960 x 540 dp
      void tvScreen(WidgetTester tester) {
        tester.view.physicalSize = const Size(1920, 1080);
        tester.view.devicePixelRatio = 2;
        addTearDown(tester.view.reset);
      }

      bool whollyOnScreen(WidgetTester tester, Finder finder) {
        final rect = tester.getRect(finder);
        return rect.top >= 0 && rect.bottom <= 540;
      }

      for (final headerFirst in [false, true]) {
        testWidgets(
          'its first tile takes the focus and comes into view (header ${headerFirst ? 'first' : 'with it'})',
          (tester) async {
            tvScreen(tester);
            final content = Completer<void>();
            await open(tester, _TallHeaderPage(content: content.future, headerFirst: headerFirst));
            content.complete();
            await tester.pump();
            await tester.pump();
            await tester.pumpAndSettle();

            expect(hasFocus(tester, find.text('tile 0')), isTrue, reason: 'OK opens it, Down goes on in the grid');
            expect(whollyOnScreen(tester, firstTile), isTrue, reason: 'scrolled up from under the screen');
          },
        );
      }

      testWidgets('read at once, it gets the focus too', (tester) async {
        tvScreen(tester);
        await open(tester, _TallHeaderPage(content: Future<void>.value()));
        await tester.pumpAndSettle();

        expect(hasFocus(tester, find.text('tile 0')), isTrue);
        expect(whollyOnScreen(tester, firstTile), isTrue);
      });

      testWidgets('a first tile already on the screen takes the focus where it is: the page does not scroll', (
        tester,
      ) async {
        tvScreen(tester);
        // Under a header of 300 dp the first tile shows its upper half at the bottom of the screen
        await open(tester, _TallHeaderPage(content: Future<void>.value(), headerHeight: 300));
        await tester.pumpAndSettle();

        expect(hasFocus(tester, find.text('tile 0')), isTrue);
        expect(tester.getRect(firstTile).center.dy, lessThan(540), reason: 'the tile shows');
        final scrollable = find.descendant(of: find.byType(CustomScrollView), matching: find.byType(Scrollable));
        expect(
          tester.state<ScrollableState>(scrollable).position.pixels,
          0,
          reason: 'the header stays whole, with the name of the album',
        );
      });
    });

    testWidgets('a list that comes while a dialog is open takes the focus once it closes', (tester) async {
      final list = Completer<void>();
      await open(tester, _LoadingPage(list: list.future));
      final pageContext = tester.element(find.text('folder'));
      unawaited(
        showDialog<void>(
          context: pageContext,
          builder: (context) => AlertDialog(
            content: TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('close')),
          ),
        ),
      );
      // The spinner of the page never settles
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      list.complete();
      await tester.pump();
      await tester.tap(find.text('close'));
      await tester.pumpAndSettle();

      expect(hasFocus(tester, find.text('first folder')), isTrue);
    });
  });

  group('the keys while a route opens', () {
    late List<String> taps;
    late List<KeyEvent> firstPageKeys;
    late List<KeyEvent> openedPageKeys;

    setUp(() {
      taps = [];
      firstPageKeys = [];
      openedPageKeys = [];
    });

    tearDown(RouteOpeningKeyGate.instance.reset);

    bool hasFocus(WidgetTester tester, String text) => Focus.of(tester.element(find.text(text))).hasPrimaryFocus;

    List<LogicalKeyboardKey> downs(List<KeyEvent> keys) => [
      for (final event in keys)
        if (event is KeyDownEvent) event.logicalKey,
    ];

    Future<void> pumpOpener(WidgetTester tester, {bool tvMode = true}) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [tvModeProvider.overrideWithValue(tvMode)],
          child: _OpenerApp(
            page: _OpenedPage(taps: taps, keys: openedPageKeys),
            taps: taps,
            keys: firstPageKeys,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(hasFocus(tester, 'open'), isTrue);
    }

    testWidgets('OK then Down and OK at once: nothing reaches the page left behind, the new page has the focus', (
      tester,
    ) async {
      await pumpOpener(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();

      expect(taps, ['open'], reason: 'the second OK opened nothing, below was never reached');
      expect(downs(firstPageKeys), [LogicalKeyboardKey.select]);
      expect(hasFocus(tester, 'first'), isTrue);

      // Once the page showed, the keys go to it
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(hasFocus(tester, 'second'), isTrue);
    });

    testWidgets('Back and the media keys go through while a route opens', (tester) async {
      await pumpOpener(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      for (final key in [
        LogicalKeyboardKey.arrowUp,
        LogicalKeyboardKey.channelDown,
        LogicalKeyboardKey.contextMenu,
        LogicalKeyboardKey.info,
        // Back of a keyboard; the remote's (goBack) is no held key either, but the test cannot send it
        LogicalKeyboardKey.escape,
        LogicalKeyboardKey.mediaPlayPause,
      ]) {
        await tester.sendKeyEvent(key);
      }
      await tester.pumpAndSettle();

      expect(downs(firstPageKeys), [
        LogicalKeyboardKey.select,
        LogicalKeyboardKey.escape,
        LogicalKeyboardKey.mediaPlayPause,
      ]);
    });

    testWidgets('the page, shoulder, next and previous keys wait too; the volume keys go through', (tester) async {
      await pumpOpener(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      // The zoom keys are held too, but the key maps of flutter_test cannot send them
      for (final key in [
        LogicalKeyboardKey.pageUp,
        LogicalKeyboardKey.pageDown,
        LogicalKeyboardKey.gameButtonLeft1,
        LogicalKeyboardKey.gameButtonRight1,
        LogicalKeyboardKey.mediaTrackNext,
        LogicalKeyboardKey.mediaTrackPrevious,
        LogicalKeyboardKey.audioVolumeUp,
      ]) {
        await tester.sendKeyEvent(key);
      }
      await tester.pumpAndSettle();

      expect(downs(firstPageKeys), [LogicalKeyboardKey.select, LogicalKeyboardKey.audioVolumeUp]);
      expect(openedPageKeys.whereType<KeyDownEvent>(), isEmpty);
    });

    testWidgets(
      'OK held on the item that opened a page: its repeats never press the new page, its release reaches it',
      (tester) async {
        await pumpOpener(tester);

        await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
        await tester.pumpAndSettle();
        expect(hasFocus(tester, 'first'), isTrue);
        expect(RouteOpeningKeyGate.instance.holds, isFalse, reason: 'the page showed: nothing is held any more');
        for (var i = 0; i < 5; i++) {
          await tester.sendKeyRepeatEvent(LogicalKeyboardKey.select);
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(taps, ['open'], reason: 'build 30 pressed first at the repeat rate');
        await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
        await tester.pump();
        expect(
          [for (final event in openedPageKeys) (event.runtimeType, event.logicalKey)],
          [(KeyUpEvent, LogicalKeyboardKey.select)],
        );

        // The next press is a press on the new page
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        await tester.pump();
        expect(taps, ['open', 'first']);
      },
    );

    testWidgets('a press dropped is dropped whole; the release of the OK that opened the page reaches it', (
      tester,
    ) async {
      await pumpOpener(tester);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(hasFocus(tester, 'first'), isTrue);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
      await tester.pump();

      expect(hasFocus(tester, 'first'), isTrue, reason: 'the repeat of a dropped Down moves nothing');
      expect(
        [for (final event in openedPageKeys) (event.runtimeType, event.logicalKey)],
        [(KeyUpEvent, LogicalKeyboardKey.select)],
      );
      expect(firstPageKeys.whereType<KeyDownEvent>().map((event) => event.logicalKey), [LogicalKeyboardKey.select]);
    });

    testWidgets('never longer than half a second, should the first frame not come', (tester) async {
      await pumpOpener(tester);
      final route = ModalRoute.of(tester.element(find.text('open')))!;
      RouteOpeningKeyGate.instance.opening(route);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(hasFocus(tester, 'open'), isTrue);

      await tester.runAsync(() => Future<void>.delayed(RouteOpeningKeyGate.cap + const Duration(milliseconds: 100)));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(hasFocus(tester, 'below'), isTrue);
    });

    testWidgets('out of the remote control layout nothing is held', (tester) async {
      await pumpOpener(tester, tvMode: false);

      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();

      expect(downs(firstPageKeys), [LogicalKeyboardKey.select, LogicalKeyboardKey.arrowDown]);
    });

    testWidgets('a page of the router, shown a frame after it was asked for: OK then Down and OK at once', (
      tester,
    ) async {
      final router = RootStackRouter.build(
        routes: [
          AutoRoute(
            path: '/',
            initial: true,
            page: PageInfo(
              'FirstRoute',
              builder: (_) => Scaffold(
                body: Builder(
                  builder: (context) => Column(
                    children: [
                      TextButton(
                        autofocus: true,
                        onPressed: () {
                          taps.add('open');
                          unawaited(context.router.pushPath('/opened'));
                        },
                        child: const Text('open'),
                      ),
                      TextButton(onPressed: () => taps.add('below'), child: const Text('below')),
                    ],
                  ),
                ),
              ),
            ),
          ),
          AutoRoute(
            path: '/opened',
            guards: [_AsyncGuard()],
            page: PageInfo(
              'OpenedRoute',
              builder: (_) => _OpenedPage(taps: taps, keys: openedPageKeys),
            ),
          ),
        ],
      );
      final stop = holdKeysOnNewPages(router, () => true);
      addTearDown(stop);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [tvModeProvider.overrideWithValue(true)],
          child: Consumer(
            builder: (context, ref, _) => MaterialApp.router(
              routerConfig: router.config(navigatorObservers: () => [AppNavigationObserver(ref: ref)]),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(hasFocus(tester, 'open'), isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();

      expect(taps, ['open']);
      expect(router.stack.length, 2);
      expect(hasFocus(tester, 'first'), isTrue);
    });

    testWidgets('the app router holds the keys of each page it adds, in the remote control layout only', (
      tester,
    ) async {
      final remote = StateProvider<bool>((ref) => false);
      final container = ProviderContainer(
        overrides: [
          apiServiceProvider.overrideWithValue(MockApiService()),
          authServiceProvider.overrideWithValue(MockAuthService()),
          secureStorageServiceProvider.overrideWithValue(MockSecureStorageService()),
          localAuthServiceProvider.overrideWithValue(_LocalAuthService()),
          tvModeProvider.overrideWith((ref) => ref.watch(remote)),
        ],
      );
      addTearDown(container.dispose);
      // The router the app shows (main.dart), with nothing more done to it
      final router = container.read(appRouterProvider);
      final gate = RouteOpeningKeyGate.instance;

      unawaited(router.push(const ChangePasswordRoute()));
      await tester.idle();
      expect(router.stack.length, 1);
      expect(gate.holds, isFalse, reason: 'out of the remote control layout');

      container.read(remote.notifier).state = true;
      unawaited(router.push(const WelcomeRoute()));
      await tester.idle();
      expect(router.stack.length, 2);
      expect(gate.holds, isTrue, reason: 'held until the frame that shows the page');

      await tester.pump();
      expect(gate.holds, isFalse);
    });
  });
}
