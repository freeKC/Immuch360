import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/panorama_viewer.widget.dart';

typedef _View = ({double longitude, double latitude, Offset velocity});

/// Runs the inertia at [fps] for [seconds], or until it stops, and returns the last view and the frame count
(_View, int) _coast(Offset velocity, {double fps = 60, double seconds = 10, double latitude = 0}) {
  _View view = (longitude: 0, latitude: latitude, velocity: velocity);
  var frames = 0;
  while (frames < fps * seconds) {
    final next = applyInertia(longitude: view.longitude, latitude: view.latitude, velocity: view.velocity, dt: 1 / fps);
    if (next == null) {
      break;
    }
    view = next;
    frames++;
  }
  return (view, frames);
}

void main() {
  group('applyInertia', () {
    test('keeps turning in the direction of the drag, slower every frame', () {
      final first = applyInertia(longitude: 10, latitude: 5, velocity: const Offset(100, -50), dt: 1 / 60)!;
      expect(first.longitude, greaterThan(10));
      expect(first.latitude, lessThan(5));

      final second = applyInertia(
        longitude: first.longitude,
        latitude: first.latitude,
        velocity: first.velocity,
        dt: 1 / 60,
      )!;
      expect(second.longitude - first.longitude, lessThan(first.longitude - 10));
      expect(second.velocity.distance, lessThan(first.velocity.distance));
    });

    test('decays with a time constant of 0.3 s', () {
      final (view, _) = _coast(const Offset(200, 0), seconds: 0.3);
      expect(view.velocity.dx, closeTo(200 / math.e, 1e-6));
    });

    test('travels the same way whatever the frame rate', () {
      final (at60, _) = _coast(const Offset(150, 40), fps: 60, seconds: 0.5);
      final (at120, _) = _coast(const Offset(150, 40), fps: 120, seconds: 0.5);
      expect(at120.longitude, closeTo(at60.longitude, 1e-9));
      expect(at120.latitude, closeTo(at60.latitude, 1e-9));
    });

    test('adds up to about the speed times the time constant, then stops', () {
      final (view, frames) = _coast(const Offset(300, 0));
      // The part left when it stops, below 3°/s, is worth less than 1°
      expect(view.longitude, closeTo(300 * 0.3, 1));
      expect(frames, lessThan(60 * 2), reason: 'a fast flick settles within 2 s');
    });

    test('stops below 0.05° per frame at 60 fps', () {
      expect(applyInertia(longitude: 0, latitude: 0, velocity: const Offset(2.9, 0), dt: 1 / 60), isNull);
      expect(applyInertia(longitude: 0, latitude: 0, velocity: const Offset(0, 3.1), dt: 1 / 60), isNotNull);
      expect(applyInertia(longitude: 0, latitude: 0, velocity: Offset.zero, dt: 1 / 60), isNull);
    });

    test('stops the latitude at the poles and keeps turning the longitude', () {
      final view = applyInertia(longitude: 0, latitude: 89, velocity: const Offset(50, 100), dt: 1 / 10)!;
      expect(view.latitude, 90);
      expect(view.velocity.dy, 0);
      expect(view.velocity.dx, greaterThan(0));
    });
  });

  group('doubleTapFov', () {
    test('zooms in from the default or a wider view', () {
      expect(doubleTapFov(90), 45);
      expect(doubleTapFov(115), 45);
      expect(doubleTapFov(60), 45);
    });

    test('goes back to the default once zoomed in', () {
      expect(doubleTapFov(45), 90);
      // The end of the animation may land a hair off the target
      expect(doubleTapFov(45.4), 90);
      expect(doubleTapFov(15), 90);
    });
  });
}
