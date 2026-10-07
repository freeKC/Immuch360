// A tap target the remote reaches: the arrows give it the focus, OK (select, enter, game button A) taps it. Touch is
// unchanged, and the slight scale only shows once a key was used.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/presentation/widgets/tv/remote_focusable.widget.dart';

void main() {
  late List<String> taps;

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              for (final name in ['first', 'second'])
                RemoteFocusable(
                  key: Key(name),
                  onTap: () => taps.add(name),
                  onLongPress: () => taps.add('$name held'),
                  child: SizedBox(width: 100, height: 100, child: Text(name)),
                ),
            ],
          ),
        ),
      ),
    );
  }

  double scaleOf(WidgetTester tester, String name) => tester
      .widget<AnimatedScale>(find.descendant(of: find.byKey(Key(name)), matching: find.byType(AnimatedScale)))
      .scale;

  setUp(() => taps = []);

  testWidgets('the arrows reach it, and OK, enter and game button A tap it', (tester) async {
    await pump(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonA);

    expect(taps, ['first', 'second', 'second']);
  });

  testWidgets('touch taps and long presses as before', (tester) async {
    await pump(tester);

    await tester.tap(find.text('first'));
    await tester.longPress(find.text('second'));

    expect(taps, ['first', 'second held']);
  });

  testWidgets('grows a little while it shows the focus after a key, never after a touch', (tester) async {
    await pump(tester);

    await tester.tap(find.text('first'));
    await tester.pumpAndSettle();
    expect(scaleOf(tester, 'first'), 1);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(scaleOf(tester, 'first'), 1.04);
    expect(scaleOf(tester, 'second'), 1);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(scaleOf(tester, 'first'), 1);
    expect(scaleOf(tester, 'second'), 1.04);
  });

  testWidgets('takes the focus by itself when asked', (tester) async {
    final node = FocusNode();
    addTearDown(node.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: RemoteFocusable(onTap: () {}, autofocus: true, focusNode: node, child: const Text('only')),
      ),
    );
    await tester.pump();

    expect(node.hasPrimaryFocus, isTrue);
  });

  group('RemoteInitialFocus', () {
    Future<void> pumpRow(WidgetTester tester, {required bool enabled}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RemoteInitialFocus(
              enabled: enabled,
              child: Column(
                children: [
                  // A tile with a button inside: the tile is the first item, though its button comes first in the
                  // focus tree
                  ListTile(
                    title: const Text('tile'),
                    trailing: IconButton(onPressed: () {}, icon: const Icon(Icons.edit)),
                    onTap: () {},
                  ),
                  TextButton(onPressed: () {}, child: const Text('below')),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('focuses the top item once', (tester) async {
      await pumpRow(tester, enabled: true);

      final focused = FocusManager.instance.primaryFocus!.context!;
      expect(focused.findAncestorWidgetOfExactType<ListTile>(), isNotNull);
      expect(focused.findAncestorWidgetOfExactType<IconButton>(), isNull, reason: 'the tile, not its button');
    });

    testWidgets('does nothing when not enabled', (tester) async {
      await pumpRow(tester, enabled: false);

      expect(FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<ListTile>(), isNull);
    });
  });
}
