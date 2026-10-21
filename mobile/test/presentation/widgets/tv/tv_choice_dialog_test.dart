// The dialog of choices of the remote control layout: it keeps the focus whatever the arrows, the current choice is
// marked and has the focus first, OK gives back the choice and Back gives back nothing. A long list (the cities of a
// library) is built lazily and opens on the current choice.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_choice_dialog.widget.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_shell.widget.dart';

enum _Fruit { apple, banana, cherry }

void main() {
  late List<_Fruit?> answers;

  setUp(() => answers = []);

  /// A page with a button that asks for a fruit, and buttons all around it where a menu would let the focus go
  Future<void> pumpPage(WidgetTester tester, {_Fruit? current = _Fruit.banana}) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        // As main.dart does
        builder: (context, child) => TvShell(enabled: true, child: child!),
        home: Scaffold(
          body: Builder(
            builder: (context) => Column(
              children: [
                TextButton(onPressed: () {}, child: const Text('above')),
                Row(
                  children: [
                    TextButton(onPressed: () {}, child: const Text('left')),
                    TextButton(
                      onPressed: () async => answers.add(
                        await showTvChoiceDialog<_Fruit?>(
                          context: context,
                          title: 'Pick a fruit',
                          current: current,
                          choices: [
                            for (final fruit in _Fruit.values)
                              TvChoice(
                                value: fruit,
                                label: fruit.name,
                                icon: fruit == _Fruit.cherry ? Icons.star : null,
                                key: ValueKey(fruit),
                              ),
                          ],
                        ),
                      ),
                      child: const Text('ask'),
                    ),
                    TextButton(onPressed: () {}, child: const Text('right')),
                  ],
                ),
                TextButton(onPressed: () {}, child: const Text('below')),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    Focus.of(tester.element(find.text('ask'))).requestFocus();
    await tester.pumpAndSettle();
  }

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pumpAndSettle();
  }

  bool focusedIn(Finder finder) {
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused == null) {
      return false;
    }
    return finder.evaluate().any((element) {
      var found = element == focused;
      if (!found) {
        focused.visitAncestorElements((ancestor) {
          found = ancestor == element;
          return !found;
        });
      }
      return found;
    });
  }

  ListTile tile(WidgetTester tester, _Fruit fruit) => tester.widget<ListTile>(find.byKey(ValueKey(fruit)));

  testWidgets('the current choice is marked and focused, and the arrows stay in the dialog', (tester) async {
    await pumpPage(tester);
    await press(tester, LogicalKeyboardKey.select);

    expect(find.text('Pick a fruit'), findsOneWidget);
    expect(tile(tester, _Fruit.banana).selected, isTrue);
    expect(tile(tester, _Fruit.apple).selected, isFalse);
    expect(focusedIn(find.byKey(const ValueKey(_Fruit.banana))), isTrue);

    for (final key in [
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.arrowLeft,
      LogicalKeyboardKey.arrowUp,
      LogicalKeyboardKey.arrowRight,
    ]) {
      for (var i = 0; i < _Fruit.values.length + 1; i++) {
        await press(tester, key);
        expect(focusedIn(find.byType(SimpleDialog)), isTrue, reason: '$key ${i + 1}');
      }
    }
    expect(answers, isEmpty);
  });

  testWidgets('OK gives back the focused choice, and the focus goes back to the button', (tester) async {
    await pumpPage(tester);
    await press(tester, LogicalKeyboardKey.select);
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(focusedIn(find.byKey(const ValueKey(_Fruit.cherry))), isTrue);

    await press(tester, LogicalKeyboardKey.select);

    expect(find.byType(SimpleDialog), findsNothing);
    expect(answers, [_Fruit.cherry]);
    expect(focusedIn(find.widgetWithText(TextButton, 'ask')), isTrue);
  });

  testWidgets('Back gives back nothing', (tester) async {
    await pumpPage(tester);
    await press(tester, LogicalKeyboardKey.select);
    await press(tester, LogicalKeyboardKey.arrowUp);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.byType(SimpleDialog), findsNothing);
    expect(answers, [null]);
  });

  testWidgets('with no current choice, the first one has the focus and none is marked', (tester) async {
    await pumpPage(tester, current: null);
    await press(tester, LogicalKeyboardKey.select);

    expect(focusedIn(find.byKey(const ValueKey(_Fruit.apple))), isTrue);
    expect(_Fruit.values.map((fruit) => tile(tester, fruit).selected), everyElement(isFalse));
  });

  testWidgets('the labels stay aligned when only some choices have an icon', (tester) async {
    await pumpPage(tester);
    await press(tester, LogicalKeyboardKey.select);

    expect(find.descendant(of: find.byKey(const ValueKey(_Fruit.cherry)), matching: find.byIcon(Icons.star)), findsOne);
    expect(tester.getTopLeft(find.text('apple')).dx, tester.getTopLeft(find.text('cherry')).dx);
  });

  group('a long list', () {
    late List<int?> numbers;

    setUp(() => numbers = []);

    /// A page with a button that asks for one of [count] numbers, [current] the current one
    Future<void> pumpNumbers(WidgetTester tester, {int count = 500, int? current = 400}) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => TvShell(enabled: true, child: child!),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                autofocus: true,
                onPressed: () async => numbers.add(
                  await showTvChoiceDialog<int?>(
                    context: context,
                    title: 'Pick a number',
                    current: current,
                    choices: [for (var i = 0; i < count; i++) TvChoice(value: i, label: 'number $i', key: ValueKey(i))],
                  ),
                ),
                child: const Text('ask'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await press(tester, LogicalKeyboardKey.select);
    }

    /// Whether the tile of [number] is built and whole inside the list
    bool visible(WidgetTester tester, int number) {
      final tile = find.byKey(ValueKey(number));
      if (tile.evaluate().isEmpty) {
        return false;
      }
      final list = tester.getRect(find.byType(ListView));
      final rect = tester.getRect(tile);
      return rect.top >= list.top && rect.bottom <= list.bottom;
    }

    testWidgets('only the tiles around the screen are built, the current one in view with the focus', (tester) async {
      await pumpNumbers(tester);

      expect(find.byType(ListTile).evaluate().length, lessThan(40));
      expect(find.byKey(const ValueKey(0)), findsNothing);
      expect(visible(tester, 400), isTrue);
      expect(focusedIn(find.byKey(const ValueKey(400))), isTrue);
      expect(tester.widget<ListTile>(find.byKey(const ValueKey(400))).selected, isTrue);
    });

    testWidgets('the arrows move through the list and stay in the dialog, OK gives back the number', (tester) async {
      await pumpNumbers(tester);

      for (var i = 0; i < 12; i++) {
        await press(tester, LogicalKeyboardKey.arrowDown);
      }
      expect(focusedIn(find.byKey(const ValueKey(412))), isTrue);
      expect(visible(tester, 412), isTrue, reason: 'scrolled with the focus');
      await press(tester, LogicalKeyboardKey.arrowLeft);
      await press(tester, LogicalKeyboardKey.arrowRight);
      expect(focusedIn(find.byType(Dialog)), isTrue);

      await press(tester, LogicalKeyboardKey.arrowUp);
      expect(focusedIn(find.byKey(const ValueKey(411))), isTrue);
      await press(tester, LogicalKeyboardKey.select);

      expect(find.byType(Dialog), findsNothing);
      expect(numbers, [411]);
    });

    testWidgets('the last choice opens in view, and Down stops there', (tester) async {
      await pumpNumbers(tester, current: 499);
      expect(visible(tester, 499), isTrue);
      expect(focusedIn(find.byKey(const ValueKey(499))), isTrue);

      await press(tester, LogicalKeyboardKey.arrowDown);
      expect(focusedIn(find.byKey(const ValueKey(499))), isTrue);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(numbers, [null]);
    });

    testWidgets('with no current choice, the list opens at the top on the first one', (tester) async {
      await pumpNumbers(tester, current: null);
      expect(visible(tester, 0), isTrue);
      expect(focusedIn(find.byKey(const ValueKey(0))), isTrue);
    });

    testWidgets('up to $tvChoiceDialogLazyAbove choices, the plain dialog', (tester) async {
      await pumpNumbers(tester, count: tvChoiceDialogLazyAbove, current: 3);
      expect(find.byType(SimpleDialog), findsOneWidget);
      expect(find.byType(ListTile), findsNWidgets(tvChoiceDialogLazyAbove));
    });
  });
}
