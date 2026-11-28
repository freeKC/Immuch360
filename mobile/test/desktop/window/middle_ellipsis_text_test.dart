// The file name of the viewers of a computer (lib/desktop/window/middle_ellipsis_text.dart): whole when it fits, else
// cut in its middle so that its start and its end, the number and the extension, stay; the whole name in the tooltip
// and for a screen reader.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/window/middle_ellipsis_text.dart';

void main() {
  test('a name that fits stays whole; a long one keeps its start and its end', () {
    double width(String text) => text.characters.length * 10.0;
    expect(middleEllipsized('clip.mp4', 200, width), 'clip.mp4');
    final cut = middleEllipsized('RatEX_motion_paysage_16x9 (1).mp4', 200, width);
    expect(cut.characters.length, 20, reason: 'as many characters as fit, the ellipsis one of them');
    expect(cut, 'RatEX_mot…x9 (1).mp4');
    expect(middleEllipsized('abc', 5, width), '…', reason: 'nothing fits but the ellipsis');
    expect(middleEllipsized('', 0, width), '');
  });

  testWidgets('in a narrow bar the name is cut in its middle, the whole of it in the tooltip', (tester) async {
    const name = 'VID_20261127_213605_RatEX_motion_paysage_16x9 (1).mp4';
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(width: 300, child: MiddleEllipsisText(name, key: Key('name'))),
          ),
        ),
      ),
    );
    final shown = tester.widget<Text>(find.descendant(of: find.byKey(const Key('name')), matching: find.byType(Text)));
    expect(shown.data, contains('…'));
    expect(shown.data, endsWith('(1).mp4'), reason: 'the end that tells two files apart');
    expect(shown.data, startsWith('VID_'));
    expect(shown.semanticsLabel, name);
    expect(find.byTooltip(name), findsOneWidget);
    expect(tester.getSize(find.byKey(const Key('name'))).width, lessThanOrEqualTo(300));

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(width: 1000, child: MiddleEllipsisText(name, key: Key('name'))),
          ),
        ),
      ),
    );
    expect(find.text(name), findsOneWidget, reason: 'room enough: whole');
    expect(find.byTooltip(name), findsNothing);
  });
}
