// The wait of the screens of the 3D conversions that read and write real files in their tests: the conversion dialog
// checks its folders with a real partial file and keeps desktop_ai.json, the panel runs jobs that hash and write real
// files. A fixed count of steps was not enough on the Windows runner of the CI (desktop run 40514244187, two attempts,
// four tests that passed an hour before on the same commit): the wait now ends once the screen is still.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Lets the real files be read and written: each step waits for the real event loop, then a frame. Goes on until what
/// the screen shows (its texts, which buttons are enabled) and [watched], when given, have not changed for 50 steps,
/// and [until] holds: 30 steps at least, some 15 s at most.
Future<void> settleStill(WidgetTester tester, {Object? Function()? watched, bool Function()? until}) async {
  String? last;
  var still = 0;
  for (var step = 0; step < 1500; step++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
    final seen = _shown(tester, watched);
    still = seen == last ? still + 1 : 0;
    last = seen;
    if (step >= 29 && still >= 50 && (until?.call() ?? true)) {
      return;
    }
  }
}

String _shown(WidgetTester tester, Object? Function()? watched) {
  final texts = [
    for (final text in tester.widgetList<Text>(find.byType(Text))) text.data ?? text.textSpan?.toPlainText() ?? '',
  ];
  final buttons = [
    for (final button in tester.widgetList<ButtonStyleButton>(find.byWidgetPredicate((w) => w is ButtonStyleButton)))
      button.onPressed != null,
  ];
  return '${texts.join('|')}#${buttons.join(',')}#${watched?.call()}';
}
