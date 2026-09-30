import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/panorama_viewer.widget.dart';

// 0.1 rad in degrees
const _step = 0.1 * 180 / math.pi;

({double longitude, double latitude}) _rotate({
  double longitude = 0,
  double latitude = 0,
  double rateX = 0,
  double rateY = 0,
  double rateZ = 0,
  double dt = 1,
  DeviceOrientation orientation = DeviceOrientation.portraitUp,
}) => applyGyroRotation(
  longitude: longitude,
  latitude: latitude,
  rateX: rateX,
  rateY: rateY,
  rateZ: rateZ,
  dt: dt,
  orientation: orientation,
);

void _expectView(({double longitude, double latitude}) view, double longitude, double latitude, [String? reason]) {
  expect(view.longitude, closeTo(longitude, 1e-9), reason: reason);
  expect(view.latitude, closeTo(latitude, 1e-9), reason: reason);
}

void main() {
  group('applyGyroRotation', () {
    test('portrait: turning around the vertical axis changes the longitude', () {
      // Positive y is counterclockwise seen from above: the phone turns left
      final left = _rotate(rateY: 0.1);
      expect(left.longitude, closeTo(-5.73, 0.01));
      expect(left.latitude, 0);

      // Turning right looks further right, where a drag to the left leads
      expect(_rotate(longitude: 10, rateY: -0.1).longitude, closeTo(10 + _step, 1e-9));
    });

    test('portrait: tilting around the horizontal axis changes the latitude', () {
      // Top of the phone towards the user: its back points higher
      final up = _rotate(rateX: 0.1);
      expect(up.latitude, closeTo(5.73, 0.01));
      expect(up.longitude, 0);
      expect(_rotate(rateX: -0.1).latitude, closeTo(-5.73, 0.01));
    });

    test('integrates over dt', () {
      expect(_rotate(rateY: -0.1, dt: 1 / 50).longitude, closeTo(_step / 50, 1e-9));
    });

    test('clamps the latitude to the poles', () {
      expect(_rotate(latitude: 89, rateX: 1).latitude, 90);
      expect(_rotate(latitude: -89, rateX: -1).latitude, -90);
    });

    test('landscape swaps the axes, with signs depending on the side the top of the phone is on', () {
      // Top on the left: device x points up, device y points left
      var view = _rotate(rateX: 0.1, orientation: DeviceOrientation.landscapeLeft);
      _expectView(view, -_step, 0);
      view = _rotate(rateY: 0.1, orientation: DeviceOrientation.landscapeLeft);
      _expectView(view, 0, -_step);

      // Top on the right: device x points down, device y points right
      view = _rotate(rateX: 0.1, orientation: DeviceOrientation.landscapeRight);
      _expectView(view, _step, 0);
      view = _rotate(rateY: 0.1, orientation: DeviceOrientation.landscapeRight);
      _expectView(view, 0, _step);
    });

    test('the same movement of the phone moves the view the same way in every orientation', () {
      // Up and right axes of the screen, in device coordinates
      const screenAxes = {
        DeviceOrientation.portraitUp: (up: (0.0, 1.0), right: (1.0, 0.0)),
        DeviceOrientation.landscapeLeft: (up: (1.0, 0.0), right: (0.0, -1.0)),
        DeviceOrientation.portraitDown: (up: (0.0, -1.0), right: (-1.0, 0.0)),
        DeviceOrientation.landscapeRight: (up: (-1.0, 0.0), right: (0.0, 1.0)),
      };
      for (final MapEntry(key: orientation, value: axes) in screenAxes.entries) {
        // Turning right: clockwise around the screen's up axis
        final turn = _rotate(rateX: -0.1 * axes.up.$1, rateY: -0.1 * axes.up.$2, orientation: orientation);
        expect(turn.longitude, closeTo(_step, 1e-9), reason: '$orientation');
        expect(turn.latitude, 0, reason: '$orientation');

        // Tilting the top towards the user: counterclockwise around the screen's right axis
        final tilt = _rotate(rateX: 0.1 * axes.right.$1, rateY: 0.1 * axes.right.$2, orientation: orientation);
        expect(tilt.longitude, 0, reason: '$orientation');
        expect(tilt.latitude, closeTo(_step, 1e-9), reason: '$orientation');
      }
    });

    test('ignores rates below the noise threshold', () {
      final still = _rotate(longitude: 12, latitude: 34, rateX: 0.004, rateY: -0.004);
      _expectView(still, 12, 34);

      // Per axis: a real rotation still goes through
      final view = _rotate(rateX: 0.004, rateY: -0.1);
      _expectView(view, _step, 0);
    });

    test('ignores rolling around the axis out of the screen', () {
      final view = _rotate(longitude: 12, latitude: 34, rateZ: 1);
      _expectView(view, 12, 34);
    });
  });
}
