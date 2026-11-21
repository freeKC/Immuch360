import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/display_rate_pacer.widget.dart';

/// The window of a Meta Quest follows the display while a video plays, and rests otherwise
void main() {
  /// How many of 60 pumps of 16 ms leave a frame asked for: one per refresh while the pacer runs, none at rest
  Future<int> framesAskedOverASecond(WidgetTester tester) async {
    var asked = 0;
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (tester.binding.hasScheduledFrame) {
        asked++;
      }
    }
    return asked;
  }

  Widget pacer({required bool active, bool tickersEnabled = true}) => Directionality(
    textDirection: TextDirection.ltr,
    child: TickerMode(
      enabled: tickersEnabled,
      child: DisplayRatePacer(active: active, child: const Text('video')),
    ),
  );

  testWidgets('asks for a frame at every refresh while active, and shows its child', (tester) async {
    await tester.pumpWidget(pacer(active: true));
    expect(find.text('video'), findsOneWidget);
    expect(await framesAskedOverASecond(tester), 60);
  });

  testWidgets('asks for nothing while inactive', (tester) async {
    await tester.pumpWidget(pacer(active: false));
    await tester.pump();
    expect(await framesAskedOverASecond(tester), 0);
  });

  testWidgets('starts when the video plays and stops when it pauses', (tester) async {
    await tester.pumpWidget(pacer(active: false));
    await tester.pump();
    expect(await framesAskedOverASecond(tester), 0);

    await tester.pumpWidget(pacer(active: true));
    expect(await framesAskedOverASecond(tester), 60);

    await tester.pumpWidget(pacer(active: false));
    await tester.pump();
    expect(await framesAskedOverASecond(tester), 0);

    // Playing again after a pause
    await tester.pumpWidget(pacer(active: true));
    expect(await framesAskedOverASecond(tester), 60);
  });

  testWidgets('a page covered by another route (tickers muted) asks for nothing', (tester) async {
    await tester.pumpWidget(pacer(active: true, tickersEnabled: false));
    await tester.pump();
    expect(await framesAskedOverASecond(tester), 0);

    await tester.pumpWidget(pacer(active: true));
    expect(await framesAskedOverASecond(tester), 60);
  });

  testWidgets('leaving the tree stops it', (tester) async {
    await tester.pumpWidget(pacer(active: true));
    expect(await framesAskedOverASecond(tester), 60);

    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(await framesAskedOverASecond(tester), 0);
  });
}
