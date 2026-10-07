// The remote control layout around the app: Flutter's directional navigation, the overscan margins of the TV
// guidelines, channel up and down for pages, up and down out of a text field, and the focus always highlighted.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_focus_ring.widget.dart';
import 'package:immich_mobile/presentation/widgets/tv/tv_shell.widget.dart';

void main() {
  Future<void> pump(WidgetTester tester, Widget home, {bool tvMode = true}) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => tvMode ? TvShell(child: child!) : child!,
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
}
