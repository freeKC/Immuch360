// The previous and next chevrons of a flat photo on a computer (design 4.3 and 4.7): they show while the mouse moves
// over the viewer and hide 3 s after it stops, only where there is a page to go to; a click turns the page; they take
// no focus (the arrows do the same) and are named for screen readers; the photo under them keeps its taps.

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/constants/locales.dart';
import 'package:immich_mobile/desktop/window/hover_chevrons.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';

void main() {
  late int page;
  late int lastPage;
  late int photoTaps;

  setUp(() {
    page = 0;
    lastPage = 2;
    photoTaps = 0;
  });

  Future<void> pumpChevrons(WidgetTester tester, {bool highContrast = false}) async {
    await tester.pumpWidget(
      EasyLocalization(
        supportedLocales: locales.values.toList(),
        path: translationsPath,
        startLocale: locales.values.first,
        fallbackLocale: locales.values.first,
        saveLocale: false,
        useFallbackTranslations: true,
        assetLoader: const CodegenLoader(),
        child: Builder(
          builder: (context) => MaterialApp(
            localizationsDelegates: context.localizationDelegates,
            supportedLocales: context.supportedLocales,
            locale: context.locale,
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(highContrast: highContrast),
              child: child!,
            ),
            home: Scaffold(
              body: withDesktopPageChevrons(
                GestureDetector(
                  onTap: () => photoTaps++,
                  child: const ColoredBox(
                    color: Colors.black,
                    child: Center(child: Text('photo')),
                  ),
                ),
                canNavigate: (direction) => page + direction >= 0 && page + direction <= lastPage,
                onNavigate: (direction) => page += direction,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<TestGesture> hover(WidgetTester tester, Offset at) async {
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(at);
    await tester.pumpAndSettle();
    return mouse;
  }

  double opacityOf(WidgetTester tester, String key) => tester
      .widget<AnimatedOpacity>(find.ancestor(of: find.byKey(Key(key)), matching: find.byType(AnimatedOpacity)))
      .opacity;

  testWidgets('hidden until the mouse moves, then only where there is a page', (tester) async {
    await pumpChevrons(tester);
    expect(opacityOf(tester, 'desktop_chevron_previous'), 0);
    expect(opacityOf(tester, 'desktop_chevron_next'), 0);

    await hover(tester, tester.getCenter(find.text('photo')));
    // The first page has nothing before it
    expect(opacityOf(tester, 'desktop_chevron_previous'), 0);
    expect(opacityOf(tester, 'desktop_chevron_next'), 1);
  });

  testWidgets('a click turns the page, and the chevrons follow it', (tester) async {
    await pumpChevrons(tester);
    final mouse = await hover(tester, tester.getCenter(find.text('photo')));

    await tester.tap(find.byKey(const Key('desktop_chevron_next')));
    await tester.pumpAndSettle();
    expect(page, 1);
    expect(opacityOf(tester, 'desktop_chevron_previous'), 1);

    await tester.tap(find.byKey(const Key('desktop_chevron_next')));
    await tester.pumpAndSettle();
    expect(page, 2);
    await mouse.moveBy(const Offset(1, 0));
    await tester.pumpAndSettle();
    expect(opacityOf(tester, 'desktop_chevron_next'), 0, reason: 'the last page');
    expect(photoTaps, 0, reason: 'the clicks went to the chevrons only');
  });

  testWidgets('they hide 3 s after the mouse stops, not while it is on one of them', (tester) async {
    await pumpChevrons(tester);
    final mouse = await hover(tester, tester.getCenter(find.text('photo')));
    await tester.pump(const Duration(seconds: 2));
    expect(opacityOf(tester, 'desktop_chevron_next'), 1);
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(opacityOf(tester, 'desktop_chevron_next'), 0);

    await mouse.moveTo(tester.getCenter(find.text('photo')) + const Offset(5, 5));
    await tester.pumpAndSettle();
    await mouse.moveTo(tester.getCenter(find.byKey(const Key('desktop_chevron_next'))));
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
    expect(opacityOf(tester, 'desktop_chevron_next'), 1);
  });

  testWidgets('hidden, they let the clicks through to the photo', (tester) async {
    await pumpChevrons(tester);
    await tester.tapAt(tester.getCenter(find.byKey(const Key('desktop_chevron_next'))));
    await tester.pumpAndSettle();
    expect(page, 0);
    expect(photoTaps, 1);
  });

  testWidgets('a touch shows nothing: a finger swipes', (tester) async {
    await pumpChevrons(tester);
    await tester.tap(find.text('photo'));
    await tester.pumpAndSettle();
    expect(opacityOf(tester, 'desktop_chevron_next'), 0);
    expect(photoTaps, 1);
  });

  testWidgets('named for screen readers, out of the Tab order', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpChevrons(tester);
    SemanticsFinder named(String name) => find.semantics.byPredicate((node) => node.tooltip == name);
    expect(named('Next'), findsNothing, reason: 'hidden chevrons are not announced');
    await hover(tester, tester.getCenter(find.text('photo')));
    expect(find.byTooltip('Next'), findsOneWidget);
    expect(find.byTooltip('Previous'), findsOneWidget);
    expect(named('Next'), findsOne);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    final focused = FocusManager.instance.primaryFocus?.context;
    expect(focused?.findAncestorWidgetOfExactType<IconButton>(), isNull);
    semantics.dispose();
  });

  testWidgets('high contrast draws them on black with a white ring', (tester) async {
    await pumpChevrons(tester, highContrast: true);
    await hover(tester, tester.getCenter(find.text('photo')));
    final button = tester.widget<IconButton>(find.byKey(const Key('desktop_chevron_next')));
    expect(button.style?.backgroundColor?.resolve({}), Colors.black);
    expect(button.style?.side?.resolve({})?.color, Colors.white);
  });
}
