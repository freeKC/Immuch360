// The rules of a selection by keyboard and mouse on a computer (lib/desktop/selection/desktop_selection.dart): what a
// click does with the keys held on Windows, Linux and macOS, the anchor of Shift clicks, what a right click puts in the
// selection, the menu, and the grid that Control A and Escape reach through the window shell: the page on top, the
// active tab, never under a dialog nor while typing, the menu closed before the selection is cleared and the selection
// cleared before full screen is left.

import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/desktop/selection/desktop_selection.dart';
import 'package:immich_mobile/routing/router.dart';

import 'selection_test_app.dart';

/// A grid as the rules see it, in memory
class _ListSelection implements DesktopSelectable<String> {
  _ListSelection(this.items);

  final List<String> items;
  final Set<String> selected = {};

  @override
  int get count => selected.length;

  @override
  bool get selecting => selected.isNotEmpty;

  @override
  bool get hasSelection => selected.isNotEmpty;

  @override
  bool isSelected(String item) => selected.contains(item);

  @override
  Future<List<String>> range(int from, int to) async => items.sublist(from, to + 1);

  @override
  void addAll(List<String> items) => selected.addAll(items);

  @override
  void toggle(String item) {
    if (!selected.remove(item)) {
      selected.add(item);
    }
  }

  @override
  Future<void> selectAll() async => selected.addAll(items);

  @override
  void clear() => selected.clear();
}

class _Picked extends FamilyNotifier<Set<String>, String> {
  @override
  Set<String> build(String arg) => const {};

  void set(Set<String> picked) => state = picked;
}

/// What each grid of these tests has selected, by its name
final _pickedProvider = NotifierProvider.family<_Picked, Set<String>, String>(_Picked.new);

/// The grid [name] of the page, whose selection is [_pickedProvider]
class _GridSelection implements DesktopSelectable<String> {
  _GridSelection(this._ref, this.name, this.items);

  final WidgetRef _ref;
  final String name;
  final List<String> items;

  Set<String> get _picked => _ref.read(_pickedProvider(name));

  void _set(Set<String> picked) => _ref.read(_pickedProvider(name).notifier).set(picked);

  @override
  int get count => _picked.length;

  @override
  bool get selecting => _picked.isNotEmpty;

  @override
  bool get hasSelection => _picked.isNotEmpty;

  @override
  bool isSelected(String item) => _picked.contains(item);

  @override
  Future<List<String>> range(int from, int to) async => items.sublist(from, to + 1);

  @override
  void addAll(List<String> items) => _set({..._picked, ...items});

  @override
  void toggle(String item) => _set(_picked.contains(item) ? ({..._picked}..remove(item)) : {..._picked, item});

  @override
  Future<void> selectAll() async => addAll(items);

  @override
  void clear() => _set(const {});
}

/// The items opened by a click, and the counts the entry of the menu acted on
final _opened = <String>[];
final _acted = <int>[];

/// A page with the grid [name] of six items, and a text field above it
class _GridPage extends ConsumerStatefulWidget {
  const _GridPage(this.name, {this.enabled = true});

  final String name;
  final bool enabled;

  @override
  ConsumerState<_GridPage> createState() => _GridPageState();
}

class _GridPageState extends ConsumerState<_GridPage> {
  late final _grid = _GridSelection(ref, widget.name, [for (var i = 0; i < 6; i++) '${widget.name}-$i']);

  @override
  Widget build(BuildContext context) {
    final picked = ref.watch(_pickedProvider(widget.name));
    return Scaffold(
      body: Focus(
        autofocus: true,
        child: Column(
          children: [
            TextField(key: Key('${widget.name}-field')),
            Expanded(
              child: DesktopSelectionScope<String>(
                selectable: _grid,
                empty: _pickedProvider(widget.name).select((picked) => picked.isEmpty),
                enabled: widget.enabled,
                menu: (context, ref) => [
                  DesktopSelectionMenuEntry(
                    key: const Key('act'),
                    icon: Icons.backup_outlined,
                    label: 'Act on ${ref.watch(_pickedProvider(widget.name)).length}',
                    onPressed: () => _acted.add(ref.read(_pickedProvider(widget.name)).length),
                  ),
                ],
                child: Wrap(
                  children: [
                    for (final (index, item) in _grid.items.indexed)
                      Builder(
                        builder: (context) => GestureDetector(
                          onTap: () {
                            final scope = DesktopSelectionScope.maybeOf<String>(context);
                            if (scope == null || !scope.click(index, item)) {
                              _opened.add(item);
                            }
                          },
                          onSecondaryTapUp: (details) => DesktopSelectionScope.maybeOf<String>(
                            context,
                          )?.openMenu(index, item, details.globalPosition),
                          child: SizedBox.square(dimension: 60, child: Text(picked.contains(item) ? '$item *' : item)),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

void main() {
  setUp(() {
    _opened.clear();
    _acted.clear();
  });

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  group('a click', () {
    testWidgets('on Windows and Linux: Control adds or takes out, Shift adds a range, plain opens or adds while '
        'selecting, right opens the menu', (tester) async {
      for (final platform in [TargetPlatform.windows, TargetPlatform.linux]) {
        debugDefaultTargetPlatformOverride = platform;
        expect(desktopClickOf(selecting: false), DesktopClick.open, reason: platform.name);
        expect(desktopClickOf(selecting: true), DesktopClick.toggle, reason: platform.name);
        expect(desktopClickOf(selecting: false, secondary: true), DesktopClick.menu, reason: platform.name);
        await withKeys(tester, [LogicalKeyboardKey.controlLeft], () async {
          expect(desktopClickOf(selecting: false), DesktopClick.toggle, reason: platform.name);
          expect(desktopAddKeyPressed(), isTrue);
        });
        await withKeys(tester, [LogicalKeyboardKey.shiftLeft], () async {
          expect(desktopClickOf(selecting: false), DesktopClick.range, reason: platform.name);
        });
        await withKeys(tester, [LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.shiftLeft], () async {
          expect(desktopClickOf(selecting: true), DesktopClick.range, reason: platform.name);
        });
        await withKeys(tester, [LogicalKeyboardKey.metaLeft], () async {
          expect(desktopClickOf(selecting: false), DesktopClick.open, reason: 'the Windows key selects nothing');
          expect(desktopAddKeyPressed(), isFalse);
        });
        expect(desktopAddKeyName(), 'Ctrl');
      }
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('on macOS: Command adds or takes out, Shift adds a range, Control click is the right click', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      expect(desktopClickOf(selecting: false), DesktopClick.open);
      await withKeys(tester, [LogicalKeyboardKey.metaLeft], () async {
        expect(desktopClickOf(selecting: false), DesktopClick.toggle);
        expect(desktopAddKeyPressed(), isTrue);
      });
      await withKeys(tester, [LogicalKeyboardKey.controlLeft], () async {
        expect(desktopClickOf(selecting: true), DesktopClick.menu);
        expect(desktopAddKeyPressed(), isFalse);
      });
      await withKeys(tester, [LogicalKeyboardKey.metaLeft, LogicalKeyboardKey.shiftLeft], () async {
        expect(desktopClickOf(selecting: false), DesktopClick.range);
      });
      expect(desktopAddKeyName(), '⌘');
      debugDefaultTargetPlatformOverride = null;
    });
  });

  group('the anchor', () {
    test('a Control click sets it, a Shift click adds from it to the item, downwards and upwards', () async {
      final grid = _ListSelection(['a', 'b', 'c', 'd', 'e', 'f', 'g']);
      final controller = DesktopSelectionController(grid);

      await controller.click(DesktopClick.toggle, 2, 'c');
      expect(controller.anchor, (index: 2, item: 'c'));
      await controller.click(DesktopClick.range, 5, 'f');
      expect(grid.selected, {'c', 'd', 'e', 'f'});
      expect(controller.anchor, (index: 2, item: 'c'), reason: 'a range leaves the anchor where it was');

      await controller.click(DesktopClick.range, 0, 'a');
      expect(grid.selected, {'a', 'b', 'c', 'd', 'e', 'f'});
    });

    test('without an anchor, a Shift click selects the item alone and anchors there', () async {
      final grid = _ListSelection(['a', 'b', 'c', 'd']);
      final controller = DesktopSelectionController(grid);

      await controller.click(DesktopClick.range, 2, 'c');
      expect(grid.selected, {'c'});
      expect(controller.anchor, (index: 2, item: 'c'));
      await controller.click(DesktopClick.range, 0, 'a');
      expect(grid.selected, {'a', 'b', 'c'});
    });

    test('goes once the selection is empty, and a long press can set it', () async {
      final grid = _ListSelection(['a', 'b', 'c', 'd']);
      final controller = DesktopSelectionController(grid);

      await controller.click(DesktopClick.toggle, 1, 'b');
      await controller.click(DesktopClick.toggle, 1, 'b');
      expect(grid.selected, isEmpty);
      expect(controller.anchor, isNull);
      await controller.click(DesktopClick.range, 3, 'd');
      expect(grid.selected, {'d'}, reason: 'no range from an item no longer selected');

      grid.selected.add('a');
      controller.anchorAt(0, 'a');
      await controller.click(DesktopClick.range, 2, 'c');
      expect(grid.selected, {'a', 'b', 'c', 'd'});
    });

    test('a right click keeps the selection on a selected item, replaces it on another, adds with Control', () {
      final grid = _ListSelection(['a', 'b', 'c', 'd']);
      final controller = DesktopSelectionController(grid);
      grid.selected.addAll({'a', 'b'});

      controller.prepareMenu(1, 'b', add: false);
      expect(grid.selected, {'a', 'b'});
      controller.prepareMenu(3, 'd', add: false);
      expect(grid.selected, {'d'});
      expect(controller.anchor, (index: 3, item: 'd'));
      controller.prepareMenu(2, 'c', add: true);
      expect(grid.selected, {'c', 'd'});
    });
  });

  group('the window', () {
    RootStackRouter router({bool enabled = true}) => RootStackRouter.build(
      routes: [
        AutoRoute(
          path: '/',
          initial: true,
          page: PageInfo('GridA', builder: (_) => _GridPage('a', enabled: enabled)),
        ),
        AutoRoute(
          path: '/b',
          page: PageInfo('GridB', builder: (_) => const _GridPage('b')),
        ),
        AutoRoute(
          path: '/tabs',
          page: PageInfo(
            TabShellRoute.name,
            builder: (_) =>
                AutoTabsRouter(routes: const [MainTimelineRoute(), LibraryRoute()], builder: (context, child) => child),
          ),
          children: [
            AutoRoute(
              path: 'photos',
              initial: true,
              page: PageInfo(MainTimelineRoute.name, builder: (_) => const _GridPage('photos')),
            ),
            AutoRoute(
              path: 'library',
              page: PageInfo(LibraryRoute.name, builder: (_) => const _GridPage('library')),
            ),
          ],
        ),
      ],
    );

    Set<String> picked(WidgetTester tester, String grid) =>
        ProviderScope.containerOf(tester.element(find.byType(MaterialApp))).read(_pickedProvider(grid));

    Future<void> controlClick(WidgetTester tester, String item) =>
        withKeys(tester, [LogicalKeyboardKey.controlLeft], () async {
          await click(tester, find.text(item));
          await tester.pumpAndSettle();
        });

    testWidgets('Control A selects the grid shown, twice stays all, Escape clears it; a page pushed over takes over', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final routes = router();
      await pumpSelectionApp(tester, router: routes);
      await tester.pumpAndSettle();

      expect(await withShortcut(tester, LogicalKeyboardKey.keyA), isTrue);
      await tester.pumpAndSettle();
      expect(picked(tester, 'a'), hasLength(6));
      await withShortcut(tester, LogicalKeyboardKey.keyA);
      await tester.pumpAndSettle();
      expect(picked(tester, 'a'), hasLength(6), reason: 'select all twice is no toggle');

      expect(await tester.sendKeyEvent(LogicalKeyboardKey.escape), isTrue);
      await tester.pumpAndSettle();
      expect(picked(tester, 'a'), isEmpty);

      unawaited(routes.pushPath('/b'));
      await tester.pumpAndSettle();
      await withShortcut(tester, LogicalKeyboardKey.keyA);
      await tester.pumpAndSettle();
      expect(picked(tester, 'b'), hasLength(6));
      expect(picked(tester, 'a'), isEmpty, reason: 'the page under it is not shown');

      await routes.maybePop();
      await tester.pumpAndSettle();
      await withShortcut(tester, LogicalKeyboardKey.keyA);
      await tester.pumpAndSettle();
      expect(picked(tester, 'a'), hasLength(6));
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('only the active tab of a tab shell, the other one staying built', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final routes = router();
      await pumpSelectionApp(tester, router: routes);
      unawaited(routes.pushPath('/tabs'));
      await tester.pumpAndSettle();

      AutoTabsRouter.of(tester.element(find.text('photos-0'))).setActiveIndex(1);
      await tester.pumpAndSettle();
      expect(find.text('photos-0', skipOffstage: false), findsOneWidget, reason: 'the first tab stays built');
      await withShortcut(tester, LogicalKeyboardKey.keyA);
      await tester.pumpAndSettle();
      expect(picked(tester, 'library'), hasLength(6));
      expect(picked(tester, 'photos'), isEmpty);

      AutoTabsRouter.of(tester.element(find.text('library-0 *'))).setActiveIndex(0);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(picked(tester, 'library'), hasLength(6), reason: 'the hidden tab keeps its selection');
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('Control A in a text field selects its text, not the grid; under a dialog, nothing', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await pumpSelectionApp(tester, router: router());
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const Key('a-field')), 'hello');
      await withShortcut(tester, LogicalKeyboardKey.keyA);
      await tester.pumpAndSettle();
      final field = tester.widget<EditableText>(find.byType(EditableText));
      expect(field.controller.selection, const TextSelection(baseOffset: 0, extentOffset: 5));
      expect(picked(tester, 'a'), isEmpty);

      FocusManager.instance.primaryFocus?.unfocus();
      unawaited(
        showDialog<void>(
          context: tester.element(find.text('a-0')),
          builder: (_) => const AlertDialog(content: Text('dialog')),
        ),
      );
      await tester.pumpAndSettle();
      await withShortcut(tester, LogicalKeyboardKey.keyA);
      await tester.pumpAndSettle();
      expect(picked(tester, 'a'), isEmpty);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('Escape clears the selection before it leaves full screen', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final window = FakeSelectionWindow();
      await pumpSelectionApp(tester, router: router(), window: window);
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.f11);
      await tester.pumpAndSettle();
      expect(window.fullScreen, isTrue);
      await controlClick(tester, 'a-1');
      expect(picked(tester, 'a'), {'a-1'});
      expect(_opened, isEmpty, reason: 'Control click selects without opening');

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(picked(tester, 'a'), isEmpty);
      expect(window.fullScreen, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(window.fullScreen, isFalse);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('a right click opens the menu of the whole selection; Escape closes the menu alone, then clears', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await pumpSelectionApp(tester, router: router());
      await tester.pumpAndSettle();
      await controlClick(tester, 'a-1');
      await controlClick(tester, 'a-3');

      await rightClick(tester, find.text('a-3 *'));
      await tester.pumpAndSettle();
      expect(find.text('Act on 2'), findsOneWidget);
      expect(find.byKey(const Key('desktop_selection_select_all')), findsOneWidget);
      expect(find.byKey(const Key('desktop_selection_clear')), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Act on 2')).dy,
        lessThan(tester.getTopLeft(find.byKey(const Key('desktop_selection_select_all'))).dy),
        reason: 'the actions of the grid first',
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Act on 2'), findsNothing);
      expect(picked(tester, 'a'), {'a-1', 'a-3'});

      await rightClick(tester, find.text('a-1 *'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Act on 2'));
      await tester.pumpAndSettle();
      expect(_acted, [2]);
      expect(find.text('Act on 2'), findsNothing, reason: 'the menu closes');

      await rightClick(tester, find.text('a-1 *'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('desktop_selection_select_all')));
      await tester.pumpAndSettle();
      expect(picked(tester, 'a'), hasLength(6));
      await rightClick(tester, find.text('a-0 *'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('desktop_selection_clear')));
      await tester.pumpAndSettle();
      expect(picked(tester, 'a'), isEmpty);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('a right click on an item outside the selection makes it the selection; with Control it joins', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await pumpSelectionApp(tester, router: router());
      await tester.pumpAndSettle();
      await controlClick(tester, 'a-1');
      await controlClick(tester, 'a-2');

      await rightClick(tester, find.text('a-4'));
      await tester.pumpAndSettle();
      expect(picked(tester, 'a'), {'a-4'});
      expect(find.text('Act on 1'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      await withKeys(tester, [LogicalKeyboardKey.controlLeft], () async {
        await rightClick(tester, find.text('a-5'));
        await tester.pumpAndSettle();
      });
      expect(picked(tester, 'a'), {'a-4', 'a-5'});
      expect(find.text('Act on 2'), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('a click on an item of the grid while the menu shows closes the menu only', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await pumpSelectionApp(tester, router: router());
      await tester.pumpAndSettle();
      await rightClick(tester, find.text('a-2'));
      await tester.pumpAndSettle();
      expect(find.text('Act on 1'), findsOneWidget);

      // To the left of the menu, which opens where the right click was
      await click(tester, find.text('a-0'));
      await tester.pumpAndSettle();
      expect(find.text('Act on 1'), findsNothing);
      expect(picked(tester, 'a'), {'a-2'});
      expect(_opened, isEmpty);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('a grid that does not select takes no click, no key and no right click', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      await pumpSelectionApp(tester, router: router(enabled: false));
      await tester.pumpAndSettle();
      expect(DesktopSelectionTargets.length, 0);

      await controlClick(tester, 'a-1');
      expect(_opened, ['a-1']);
      await withShortcut(tester, LogicalKeyboardKey.keyA);
      await rightClick(tester, find.text('a-2'));
      await tester.pumpAndSettle();
      expect(picked(tester, 'a'), isEmpty);
      expect(find.text('Act on 1'), findsNothing);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('on macOS: Command click and Command A select, Control click opens the menu', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      await pumpSelectionApp(tester, router: router());
      await tester.pumpAndSettle();

      await withKeys(tester, [LogicalKeyboardKey.metaLeft], () async {
        await click(tester, find.text('a-1'));
        await tester.pumpAndSettle();
      });
      expect(picked(tester, 'a'), {'a-1'});
      await withKeys(tester, [LogicalKeyboardKey.controlLeft], () async {
        await click(tester, find.text('a-3'));
        await tester.pumpAndSettle();
      });
      expect(picked(tester, 'a'), {'a-3'}, reason: 'a right click on an item outside the selection');
      expect(find.text('Act on 1'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      await withShortcut(tester, LogicalKeyboardKey.keyA);
      await tester.pumpAndSettle();
      expect(picked(tester, 'a'), {'a-3'}, reason: 'Control A is no shortcut on macOS');
      await withShortcut(tester, LogicalKeyboardKey.keyA, command: true);
      await tester.pumpAndSettle();
      expect(picked(tester, 'a'), hasLength(6));
      debugDefaultTargetPlatformOverride = null;
    });
  });
}
