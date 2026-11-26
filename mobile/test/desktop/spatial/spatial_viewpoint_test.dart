import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/desktop/spatial/spatial_viewpoint.dart';
import 'package:immich_mobile/desktop/spatial/viewer_position.dart';
import 'package:immich_mobile/desktop/spatial/viewer_position_sources.dart';

import 'fake_viewer_position_source.dart';

ViewerPosition _at(double x, int ms, {double confidence = 1}) => ViewerPosition(
  x: x,
  y: 0,
  timestamp: Duration(milliseconds: ms),
  confidence: confidence,
);

Duration _ms(int ms) => Duration(milliseconds: ms);

void main() {
  group('mapping', () {
    test('centre, ends, sensitivity, reverse and the limits of the phones', () {
      expect(spatialViewpointOf(0), 0.5);
      expect(spatialViewpointOf(1), closeTo(0.85, 1e-12));
      expect(spatialViewpointOf(-1), closeTo(0.15, 1e-12));
      expect(spatialViewpointOf(0.5), closeTo(0.675, 1e-12));
      expect(spatialViewpointOf(0.5, sensitivity: 0.5), closeTo(0.5875, 1e-12));
      expect(spatialViewpointOf(0.5, reverse: true), closeTo(0.325, 1e-12));
      expect(spatialViewpointOf(3), 0.85);
      expect(spatialViewpointOf(-0.6, sensitivity: 2), 0.15);
    });
  });

  group('follow', () {
    test('a source that smooths itself is followed at once', () {
      final view = SpatialViewpoint(followTime: Duration.zero);
      expect(view.valueAt(_ms(0)), 0.5);
      view.add(_at(1, 0), _ms(0));
      expect(view.valueAt(_ms(0)), closeTo(0.85, 1e-12));
      expect(view.movingAt(_ms(0)), isFalse);
    });

    test('the mouse is followed with its time constant: 63 percent after one, all of it after a while', () {
      final view = SpatialViewpoint(followTime: MousePositionSource.follow);
      view.valueAt(_ms(0));
      view.add(_at(1, 0), _ms(0));
      expect(view.valueAt(_ms(0)), 0.5);
      expect(view.valueAt(_ms(80)), closeTo(0.5 + 0.35 * 0.632, 0.002));
      expect(view.movingAt(_ms(80)), isTrue);
      // Frame by frame gives the same curve
      for (var ms = 96; ms <= 2000; ms += 16) {
        view.valueAt(_ms(ms));
      }
      expect(view.valueAt(_ms(2000)), closeTo(0.85, 1e-4));
      expect(view.movingAt(_ms(2000)), isFalse);
    });

    test('no one seen: the view holds, then glides back to the centre over one second', () {
      final view = SpatialViewpoint(followTime: Duration.zero);
      view.add(_at(1, 0), _ms(0));
      view.add(ViewerPosition.lost(_ms(100)), _ms(100));
      expect(view.lost, isTrue);
      expect(view.valueAt(_ms(100)), closeTo(0.85, 1e-9));
      // Half way through the smooth step, half way back
      expect(view.valueAt(_ms(600)), closeTo(0.675, 1e-9));
      expect(view.movingAt(_ms(600)), isTrue);
      expect(view.valueAt(_ms(1100)), 0.5);
      expect(view.movingAt(_ms(1200)), isFalse);
      // A later lost position does not restart the glide
      view.add(ViewerPosition.lost(_ms(1300)), _ms(1300));
      expect(view.valueAt(_ms(1300)), 0.5);
    });

    test('seen again: a glide in over 0.3 s from where the view was, then the position', () {
      final view = SpatialViewpoint(followTime: Duration.zero);
      view.add(_at(1, 0), _ms(0));
      view.add(ViewerPosition.lost(_ms(0)), _ms(0));
      view.valueAt(_ms(500));
      view.add(_at(-1, 500), _ms(500));
      expect(view.lost, isFalse);
      expect(view.valueAt(_ms(500)), closeTo(0.675, 1e-9));
      expect(view.valueAt(_ms(650)), closeTo((0.675 + 0.15) / 2, 1e-9));
      expect(view.valueAt(_ms(800)), closeTo(0.15, 1e-9));
      expect(view.movingAt(_ms(900)), isFalse);
    });

    test('sensitivity and reverse change the target at once', () {
      final view = SpatialViewpoint(followTime: Duration.zero, sensitivity: 0.5);
      view.add(_at(1, 0), _ms(0));
      expect(view.valueAt(_ms(0)), closeTo(0.675, 1e-12));
      view.reverse = true;
      expect(view.valueAt(_ms(16)), closeTo(0.325, 1e-12));
    });

    test('a recorded track of the fake source, as the head tracker will send it', () async {
      final source = FakeViewerPositionSource();
      final view = SpatialViewpoint(followTime: source.followTime);
      final seen = <double>[];
      final subscription = source.positions.listen((position) {
        view.add(position, position.timestamp);
        seen.add(view.valueAt(position.timestamp));
      });
      source.play([(0, 0, 1), (33, 0.5, 0.9), (66, 1, 0.9), (400, 0, 0), (1500, -0.5, 0.8)]);
      await subscription.cancel();
      expect(seen, [0.5, closeTo(0.675, 1e-12), closeTo(0.85, 1e-12), closeTo(0.85, 1e-12), closeTo(0.5, 1e-12)]);
      expect(view.valueAt(_ms(1800)), closeTo(0.325, 1e-12));
    });
  });

  group('sources', () {
    test('mouse: the pointer across the picture, leaving it, and the recentre', () {
      var now = Duration.zero;
      final mouse = MousePositionSource(clock: () => now);
      final seen = <ViewerPosition>[];
      mouse.positions.listen(seen.add);
      expect(mouse.kind, ViewerPositionKind.mouse);
      mouse.pointerAt(const Offset(150, 50), const Size(200, 100));
      expect(seen.last.x, closeTo(0.5, 1e-12));
      expect(seen.last.y, closeTo(0, 1e-12));
      expect(seen.last.confidence, 1);
      now = _ms(10);
      mouse.pointerAt(const Offset(500, 0), const Size(200, 100));
      expect(seen.last.x, 1);
      expect(seen.last.timestamp, _ms(10));
      mouse.recenter();
      expect(seen.last.x, 0);
      mouse.pointerAt(const Offset(100, 50), const Size(200, 100));
      expect(seen.last.x, -1);
      mouse.pointerLeft();
      expect(seen.last.seen, isFalse);
      expect(mouse.latest, seen.last);
    });

    test('sway: a sine of four seconds, restarted by the recentre', () {
      var now = Duration.zero;
      final sway = SwayPositionSource(clock: () => now, start: false);
      expect(sway.latest!.x, 0);
      now = _ms(1000);
      sway.tick();
      expect(sway.latest!.x, closeTo(SwayPositionSource.amplitude, 1e-9));
      now = _ms(3000);
      sway.tick();
      expect(sway.latest!.x, closeTo(-SwayPositionSource.amplitude, 1e-9));
      sway.recenter();
      expect(sway.latest!.x, 0);
      expect(spatialViewpointOf(SwayPositionSource.amplitude), closeTo(0.71, 1e-9));
    });

    test('keys: steps of a fifth, kept within the range, and the recentre', () async {
      final keys = KeysPositionSource(clock: () => Duration.zero);
      expect(keys.latest!.x, 0);
      keys.nudge(1);
      expect(keys.latest!.x, closeTo(0.2, 1e-12));
      keys.nudge(-12);
      expect(keys.latest!.x, -1);
      keys.recenter();
      expect(keys.latest!.x, 0);
      await keys.close();
      keys.nudge(1);
      expect(keys.latest!.x, 0, reason: 'nothing more once closed');
    });
  });
}
