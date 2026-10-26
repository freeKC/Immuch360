// The safety notice of the DJI live video on a phone: in the remote control layout its text is one stop that the
// arrows scroll, then "I understand", as on a TV; out of it, the plain list it always was.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/presentation/widgets/drone/dji_live_notice.widget.dart';
import 'package:immich_mobile/presentation/widgets/tv/remote_scroll_area.widget.dart';

import '../../../unit/presentation/presentation_context.dart';

void main() {
  late PresentationContext context;

  setUp(() async => context = await PresentationContext.create());
  tearDown(() => context.dispose());

  /// A 1080p screen in the remote control layout, 960 by 540 dp: the notice shows, its answer goes to [answers]
  Future<void> openNotice(WidgetTester tester, {required bool remote, required List<bool> answers}) async {
    await tester.binding.setSurfaceSize(const Size(960, 540));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpTestWidget(
      context,
      Builder(
        builder: (context) => TextButton(
          onPressed: () async => answers.add(await showDjiLiveNotice(context, headset: false, remote: remote)),
          child: const Text('open'),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  bool focusIn(WidgetTester tester, Finder finder) {
    final focus = FocusManager.instance.primaryFocus?.context;
    if (focus == null) {
      return false;
    }
    final target = tester.element(finder);
    var found = identical(focus, target);
    focus.visitAncestorElements((ancestor) {
      found = found || identical(ancestor, target);
      return !found;
    });
    return found;
  }

  testWidgets('in the remote control layout the arrows scroll the text to its end, then reach I understand', (
    tester,
  ) async {
    final answers = <bool>[];
    await openNotice(tester, remote: true, answers: answers);
    final text = find.byKey(const Key('dji_live_notice_text'));
    expect(focusIn(tester, text), isTrue);
    expect(
      find.byKey(const Key('dji_live_notice_observer')),
      findsNothing,
      reason: 'the phone wording, not the TV one',
    );
    final position = tester
        .state<ScrollableState>(find.descendant(of: text, matching: find.byType(Scrollable)))
        .position;

    var reached = false;
    for (var i = 0; i < 8 && !reached; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      reached = focusIn(tester, find.byKey(const Key('dji_live_notice_ok')));
    }

    expect(position.pixels, position.maxScrollExtent, reason: 'read to its last line');
    expect(reached, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(answers, [true]);
  });

  testWidgets('out of it, the plain list it always was', (tester) async {
    final answers = <bool>[];
    await openNotice(tester, remote: false, answers: answers);

    expect(find.byKey(const Key('dji_live_notice')), findsOneWidget);
    expect(find.byType(RemoteScrollArea), findsNothing);
  });
}
