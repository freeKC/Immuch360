// In the remote control layout an item always has the focus: a page that focuses nothing by itself gets its first
// item, an item of the page rather than the Back button of its app bar, and a page that focused one keeps it. A list
// that comes after loading takes the focus from the Back button the page had meanwhile, unless the user moved it.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/providers/infrastructure/tv.provider.dart';
import 'package:immich_mobile/routing/app_navigation_observer.dart';

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
}
