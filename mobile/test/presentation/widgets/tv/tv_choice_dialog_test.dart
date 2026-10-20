// The dialog of choices of the remote control layout: it keeps the focus whatever the arrows, the current choice is
// marked and has the focus first, OK gives back the choice and Back gives back nothing.

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
}
