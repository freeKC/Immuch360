// What tells a pinch of a computer's touchpad from a two finger scroll (desktop_trackpad_pinch.dart, 28 November
// 2026), and the claim that takes a pinch from the drags under a view on the report that makes it one.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/window/desktop_photo_zoom.dart';
import 'package:immich_mobile/desktop/window/desktop_trackpad_pinch.dart';
import 'package:logging/logging.dart';

import 'trackpad_pinch_sequences.dart';

void main() {
  group('the latch', () {
    PointerPanZoomUpdateEvent update(int pointer, double scale, {Offset pan = Offset.zero}) =>
        PointerPanZoomUpdateEvent(pointer: pointer, position: const Offset(10, 20), pan: pan, scale: scale);

    test('a scroll is no pinch: a scale of 1 all along gives no zoom', () {
      final latch = TrackpadPinchLatch()..begin(const PointerPanZoomStartEvent(pointer: 1, position: Offset(10, 20)));
      for (final step in scroll(const Offset(-200, 0))) {
        expect(latch.update(update(1, step.scale, pan: step.pan)), 1);
      }
      expect(latch.pinching, isFalse);
    });

    test('a pinch past half a per cent latches, and its zooms add up to its whole scale', () {
      final latch = TrackpadPinchLatch()..begin(const PointerPanZoomStartEvent(pointer: 2, position: Offset(10, 20)));
      expect(latch.start, const Offset(10, 20));
      var zoom = 1.0;
      for (final step in windowsPinch(2, const Offset(800, 480))) {
        zoom *= latch.update(update(2, step.scale, pan: step.pan));
      }
      expect(latch.pinching, isTrue);
      expect(zoom, closeTo(2, 1e-9), reason: 'nothing of the pinch is lost at the latch');
    });

    test('the line of the log tells the pan that came with the pinch from the one around the pointer', () {
      final latch = TrackpadPinchLatch()..begin(const PointerPanZoomStartEvent(pointer: 6, position: Offset(800, 480)));
      for (final step in windowsPinch(2, const Offset(800, 480))) {
        latch.update(
          PointerPanZoomUpdateEvent(pointer: 6, position: const Offset(800, 480), pan: step.pan, scale: step.scale),
        );
      }
      expect(
        latch.describe(),
        'pinch, 30 reports from (800.0, 480.0), largest scale 2.000 with a pan of (-800.0, -480.0) (around the '
        'pointer: (-800.0, -480.0)), pan when it became a pinch (-4.8, -2.9)',
      );
    });

    test('below the slop no zoom, and a gesture that goes back under it stays a pinch', () {
      final latch = TrackpadPinchLatch()..begin(const PointerPanZoomStartEvent(pointer: 3, position: Offset.zero));
      expect(latch.update(update(3, 1.004)), 1);
      expect(latch.pinching, isFalse);
      expect(latch.update(update(3, 1.01)), closeTo(1.01, 1e-12));
      expect(latch.update(update(3, 1.0)), closeTo(1 / 1.01, 1e-12));
      expect(latch.pinching, isTrue);
    });

    test('the pinch stays told after its end, until a pointer goes down or a new gesture starts', () {
      final latch = TrackpadPinchLatch()..begin(const PointerPanZoomStartEvent(pointer: 4, position: Offset.zero));
      latch.update(update(4, 1.5));
      expect(latch.pinching, isTrue, reason: 'the end of a drag after the pinch leaves no inertia');
      latch.reset();
      expect(latch.pinching, isFalse);
      latch.update(update(4, 1.6));
      latch.begin(const PointerPanZoomStartEvent(pointer: 5, position: Offset.zero));
      expect(latch.pinching, isFalse);
    });
  });

  group('the claim', () {
    testWidgets('it takes a pinch from a drag on the report that makes it one, and leaves a scroll to it', (
      tester,
    ) async {
      final latch = TrackpadPinchLatch();
      TrackpadGestureClaim? claim;
      int? owned;
      var taken = 0;
      var dragged = 0;
      await tester.pumpWidget(
        Listener(
          onPointerPanZoomStart: latch.begin,
          onPointerPanZoomUpdate: (event) {
            latch.update(event);
            if (latch.pinching) {
              claim?.take(event.pointer);
            }
          },
          child: RawGestureDetector(
            behavior: HitTestBehavior.opaque,
            gestures: {
              TrackpadGestureClaim: GestureRecognizerFactoryWithHandlers<TrackpadGestureClaim>(
                TrackpadGestureClaim.new,
                (recognizer) {
                  claim = recognizer
                    ..onAccepted = ((pointer) {
                      owned = pointer;
                      taken++;
                    })
                    ..onReleased = ((pointer) => owned = owned == pointer ? null : owned);
                },
              ),
            },
            // A drag under it, as the details and the drag that closes the asset viewer
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onVerticalDragUpdate: (_) => dragged++,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );
      const at = Offset(400, 500);
      await sendPanZoom(tester, at, windowsPinch(2, at));
      expect(taken, 1);
      expect(dragged, 0, reason: 'the drag never saw the pan of the pinch');
      expect(owned, isNull, reason: 'given back at the end');
      await sendPanZoom(tester, at, scroll(const Offset(0, -100)));
      expect(dragged, greaterThan(0), reason: 'a scroll is the drag\'s');
      expect(taken, 1);
    });
  });

  group('the log', () {
    testWidgets('the first gestures and every pinch at info, the plain scrolls after them at fine', (tester) async {
      tester.view.physicalSize = const Size(800, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      resetDesktopTouchpadGestureLog();
      final level = Logger.root.level;
      Logger.root.level = Level.ALL;
      addTearDown(() => Logger.root.level = level);
      final lines = <LogRecord>[];
      final listening = Logger.root.onRecord
          .where((record) => record.loggerName == 'DesktopPhotoZoom')
          .listen(lines.add);
      addTearDown(listening.cancel);
      final controller = DesktopZoomController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: DesktopZoomView(
            controller: controller,
            pixelSize: const Size(4000, 2000),
            child: const ColoredBox(color: Colors.blue),
          ),
        ),
      );
      const at = Offset(400, 300);
      // Flicking through photos at fit: the first ones tell what the touchpad sends, the others are no news
      for (var i = 0; i < desktopTouchpadGesturesLogged + 2; i++) {
        await sendPanZoom(tester, at, scroll(const Offset(-200, 0)));
      }
      await sendPanZoom(tester, at, windowsPinch(2, at));
      expect(controller.scale, greaterThan(1.9));
      // A zoomed photo panned by two fingers
      for (var i = 0; i < 3; i++) {
        await sendPanZoom(tester, at, scroll(const Offset(0, -40)));
      }
      final info = lines.where((record) => record.level == Level.INFO).toList();
      final fine = lines.where((record) => record.level == Level.FINE).toList();
      expect(lines, hasLength(desktopTouchpadGesturesLogged + 6), reason: 'still one line a gesture');
      expect(info, hasLength(desktopTouchpadGesturesLogged + 1));
      expect(info.last.message, contains('taken by the zoom: pinch'));
      expect(fine, hasLength(5));
      expect(fine.every((record) => record.message.contains(': scroll,')), isTrue);
    });
  });
}
