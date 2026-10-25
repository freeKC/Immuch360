// The warnings over the drone's picture come and go (FreeKC's rule of 25 October): in over 250 ms, held until 5 s,
// out over 0.8 s, then gone from the layout; a new kind or a key or a tap brings them back; an error that needs an
// action stays. The pure rule, then the widget that follows it. The same numbers as TransientText on the native side.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_live_transient.dart';

void main() {
  group('the rule', () {
    test('in over 250 ms, held until 5 s, out over 0.8 s, then nothing', () {
      double at(int ms) => djiTransientOpacity(Duration(milliseconds: ms));
      expect(at(-1), 0);
      expect(at(0), 0);
      expect(at(125), closeTo(0.5, 1e-9));
      expect(at(250), 1);
      expect(at(4000), 1);
      expect(at(5000), 1);
      expect(at(5400), closeTo(0.5, 1e-9));
      expect(at(5800), 0);
      expect(at(60000), 0);
      // An error that needs an action: always there
      expect(djiTransientOpacity(const Duration(minutes: 1), keep: true), 1);
      // About 4 to 6 s on the screen, as asked
      expect(djiTransientHold, const Duration(seconds: 5));
      expect(djiTransientHold + djiTransientFadeOut, lessThanOrEqualTo(const Duration(seconds: 6)));
    });

    test('a new kind shows a warning again, a number inside it does not', () {
      expect(djiTransientShowsAgain('live', 'lost'), isTrue);
      expect(djiTransientShowsAgain(null, 'stale'), isTrue);
      expect(djiTransientShowsAgain('stale', 'stale'), isFalse);
    });
  });

  group('the widget', () {
    final recall = DjiTransientRecall();
    const text = Key('warning');

    Widget warning({Object? kind = 'watching', bool keep = false}) => MaterialApp(
      home: DjiTransientScope(
        recall: recall,
        child: Center(
          child: DjiTransient(kind: kind, keep: keep, child: const Text('Watching only', key: text)),
        ),
      ),
    );

    double opacity(WidgetTester tester) => tester
        .widget<FadeTransition>(find.ancestor(of: find.byKey(text), matching: find.byType(FadeTransition)).first)
        .opacity
        .value;

    testWidgets('it follows the rule, then leaves the layout', (tester) async {
      await tester.pumpWidget(warning());
      expect(opacity(tester), 0);
      await tester.pump(const Duration(milliseconds: 125));
      expect(opacity(tester), closeTo(0.5, 0.01));
      await tester.pump(const Duration(milliseconds: 125));
      expect(opacity(tester), 1);
      await tester.pump(const Duration(milliseconds: 4700));
      expect(opacity(tester), 1);
      // The hold ends at 5 s: the fade starts with the next frame
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 400));
      expect(opacity(tester), closeTo(0.5, 0.01));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump();
      expect(find.byKey(text), findsNothing);
    });

    testWidgets('a key or a tap brings it back from nothing, and from where it is while it fades', (tester) async {
      await tester.pumpWidget(warning());
      await tester.pump(djiTransientHold);
      await tester.pumpAndSettle();
      expect(find.byKey(text), findsNothing);

      recall.recall();
      await tester.pump();
      expect(find.byKey(text), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 250));
      expect(opacity(tester), 1);
      // Five seconds from the recall
      await tester.pump(const Duration(milliseconds: 4700));
      expect(opacity(tester), 1);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 400));
      final fading = opacity(tester);
      expect(fading, closeTo(0.5, 0.05));
      // Brought back while it fades: up from there, never from nothing
      recall.recall();
      await tester.pump();
      expect(opacity(tester), greaterThanOrEqualTo(fading - 0.01));
      await tester.pump(const Duration(milliseconds: 250));
      expect(opacity(tester), 1);
    });

    testWidgets('a new kind shows it again by itself; the same kind does not', (tester) async {
      await tester.pumpWidget(warning(kind: 'live'));
      await tester.pump(djiTransientHold);
      await tester.pumpAndSettle();
      expect(find.byKey(text), findsNothing);
      await tester.pumpWidget(warning(kind: 'live'));
      await tester.pumpAndSettle();
      expect(find.byKey(text), findsNothing);
      await tester.pumpWidget(warning(kind: 'lost'));
      await tester.pumpAndSettle();
      expect(find.byKey(text), findsOneWidget);
    });

    testWidgets('an error that needs an action stays until it is resolved, then goes like the others', (
      tester,
    ) async {
      await tester.pumpWidget(warning(kind: 'otherVersion', keep: true));
      await tester.pump(const Duration(minutes: 1));
      await tester.pumpAndSettle();
      expect(opacity(tester), 1);
      // Resolved: a warning of another kind for five seconds
      await tester.pumpWidget(warning(kind: 'live'));
      await tester.pumpAndSettle();
      expect(opacity(tester), 1);
      await tester.pump(djiTransientHold);
      await tester.pumpAndSettle();
      expect(find.byKey(text), findsNothing);
    });
  });
}
