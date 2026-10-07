// The one focus ring of the remote control layout: around the focused widget, moving with it, and absent for a focus
// scope, a widget that covers the screen (the key catchers of the viewers) and a widget under NoFocusRing.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_focus_ring.widget.dart';

void main() {
  Future<void> pump(WidgetTester tester, Widget body) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => TvFocusRing(child: child!),
        home: Scaffold(body: body),
      ),
    );
    await tester.pumpAndSettle();
  }

  Rect? ring(WidgetTester tester) => tester.state<TvFocusRingState>(find.byType(TvFocusRing)).ringRect;

  Widget button(String name, FocusNode node) => SizedBox(
    width: 120,
    height: 60,
    child: TextButton(key: Key(name), focusNode: node, onPressed: () {}, child: Text(name)),
  );

  testWidgets('frames the focused widget, and follows the focus to the next one in a short ease', (tester) async {
    final first = FocusNode();
    final second = FocusNode();
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    await pump(
      tester,
      Column(children: [button('first', first), const SizedBox(height: 100), button('second', second)]),
    );
    expect(ring(tester), isNull, reason: 'nothing has the focus yet');

    first.requestFocus();
    await tester.pumpAndSettle();
    expect(ring(tester), tester.getRect(find.byKey(const Key('first'))));

    second.requestFocus();
    // The focus moves in a microtask after the first frame, the ease starts on the next one
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    final moving = ring(tester)!;
    final from = tester.getRect(find.byKey(const Key('first')));
    final to = tester.getRect(find.byKey(const Key('second')));
    expect(moving.top, greaterThan(from.top), reason: 'on its way');
    expect(moving.top, lessThan(to.top));

    await tester.pumpAndSettle();
    expect(ring(tester), to);
  });

  testWidgets('moves with the focused widget as it scrolls', (tester) async {
    final node = FocusNode();
    final controller = ScrollController();
    addTearDown(node.dispose);
    addTearDown(controller.dispose);
    await pump(
      tester,
      ListView(
        controller: controller,
        children: [const SizedBox(height: 200), button('tile', node), const SizedBox(height: 2000)],
      ),
    );
    node.requestFocus();
    await tester.pumpAndSettle();
    final before = ring(tester)!;

    controller.jumpTo(50);
    await tester.pump();
    await tester.pump();

    expect(ring(tester), before.translate(0, -50));
    expect(ring(tester), tester.getRect(find.byKey(const Key('tile'))));
  });

  testWidgets('no ring around a focus scope', (tester) async {
    final scope = FocusScopeNode();
    addTearDown(scope.dispose);
    await pump(tester, FocusScope(node: scope, child: const SizedBox(width: 100, height: 100)));

    scope.requestFocus();
    await tester.pumpAndSettle();

    expect(FocusManager.instance.primaryFocus, scope);
    expect(ring(tester), isNull);
  });

  testWidgets('no ring around a widget that covers the screen: a viewer catching the keys', (tester) async {
    final node = FocusNode();
    addTearDown(node.dispose);
    await pump(tester, Focus(focusNode: node, child: const SizedBox.expand()));

    node.requestFocus();
    await tester.pumpAndSettle();

    expect(node.hasPrimaryFocus, isTrue);
    expect(ring(tester), isNull);
  });

  testWidgets('no ring under NoFocusRing', (tester) async {
    final marked = FocusNode();
    final plain = FocusNode();
    addTearDown(marked.dispose);
    addTearDown(plain.dispose);
    await pump(
      tester,
      Column(
        children: [
          NoFocusRing(child: button('marked', marked)),
          button('plain', plain),
        ],
      ),
    );

    marked.requestFocus();
    await tester.pumpAndSettle();
    expect(ring(tester), isNull);

    plain.requestFocus();
    await tester.pumpAndSettle();
    expect(ring(tester), tester.getRect(find.byKey(const Key('plain'))));
  });

  testWidgets('draws nothing once the focused widget is gone', (tester) async {
    final node = FocusNode();
    addTearDown(node.dispose);
    await pump(tester, button('only', node));
    node.requestFocus();
    await tester.pumpAndSettle();
    expect(ring(tester), isNotNull);

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => TvFocusRing(child: child!),
        home: const Scaffold(body: SizedBox.shrink()),
      ),
    );
    await tester.pumpAndSettle();

    expect(ring(tester), isNull);
  });
}
