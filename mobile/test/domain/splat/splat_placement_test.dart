// The Dart port of placement.js (the drawn poster of a splat photo, plan of 3 November 2026, section 7) against
// viewer_expected.json of make_viewer_fixtures.py, which placement.test.mjs and SplatPlacementViewerTest.kt read too.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/splat/splat_placement.dart';

final Map<String, dynamic> _expected =
    jsonDecode(File('test/fixtures/splat_viewer/viewer_expected.json').readAsStringSync()) as Map<String, dynamic>;

Iterable<MapEntry<String, Map<String, dynamic>>> get _cases => _expected.entries
    .where((entry) => entry.key != 'about')
    .map((e) => MapEntry(e.key, e.value as Map<String, dynamic>));

List<double> _doubles(Object? values) => [for (final value in values! as List) (value as num).toDouble()];

void _near(double found, num wanted, double tolerance, String reason) =>
    expect((found - wanted).abs() <= tolerance, isTrue, reason: '$reason: $found is not $wanted');

void main() {
  test('every case of viewer_expected.json: bounds, object or place, floor rule, first view', () {
    expect(_cases.length, greaterThanOrEqualTo(8));
    for (final MapEntry(key: name, value: wanted) in _cases) {
      final positions = _doubles(wanted['positions']);
      final sample = splatSampleOf(wanted['count'] as int);
      expect(sample.stride, wanted['stride'], reason: name);
      expect(sample.samples, positions.length ~/ 3, reason: name);
      final bounds = splatBoundsOf(positions)!;
      final wantedBounds = wanted['bounds'] as Map<String, dynamic>;
      for (var axis = 0; axis < 3; axis++) {
        _near(bounds.low[axis], (wantedBounds['low'] as List)[axis] as num, 1e-12, '$name low');
        _near(bounds.high[axis], (wantedBounds['high'] as List)[axis] as num, 1e-12, '$name high');
      }
      expect(bounds.isObject, wanted['object'], reason: name);
      expect(splatFloorUprightOf(positions, bounds), wanted['floorUpright'], reason: name);
      final upright = splatOpeningUpright(null, positions, bounds);
      expect(upright, wanted['upright'], reason: name);
      final view = splatFirstView(bounds, upright);
      final wantedView = wanted['view'] as Map<String, dynamic>;
      _near(view.size, wanted['size'] as num, 1e-12, '$name size');
      _near(view.pitch, wantedView['pitch'] as num, 1e-12, '$name pitch');
      _near(view.distance, wantedView['distance'] as num, 1e-9, '$name distance');
      _near(view.speed, wantedView['speed'] as num, 1e-12, '$name speed');
      for (var axis = 0; axis < 3; axis++) {
        _near(view.position[axis], (wantedView['position'] as List)[axis] as num, 1e-9, '$name position');
        _near(view.center[axis], (wantedView['target'] as List)[axis] as num, 1e-9, '$name target');
      }
    }
  });

  test('a choice made for the file wins over the floor rule', () {
    final room = _expected['room_floor.spz'] as Map<String, dynamic>;
    final positions = _doubles(room['positions']);
    final bounds = splatBoundsOf(positions);
    expect(splatOpeningUpright(null, positions, bounds), 'yUp');
    expect(splatOpeningUpright('zUp', positions, bounds), 'zUp');
    expect(splatOpeningUpright('nonsense', positions, bounds), 'yUp');
  });

  test('the pitches are the headset\'s with the z mirror: Z up turns z to y', () {
    final z = splatRotateX(splatPitchOf('zUp'), const [0, 0, 1]);
    _near(z[1], 1, 1e-12, 'z to y');
    _near(z[2], 0, 1e-12, 'z to y');
    final y = splatRotateX(splatPitchOf('yDown'), const [0, 1, 0]);
    _near(y[1], -1, 1e-12, 'y down');
    expect(splatPitchOf('yUp'), 0);
  });

  test('percentiles as relief-v1 takes them', () {
    final sorted = [for (var i = 1; i <= 20; i++) i.toDouble()];
    expect(splatPercentile(sorted, 5), 1);
    expect(splatPercentile(sorted, 95), 19);
    expect(splatPercentile(const [7.0], 5), 7);
  });

  test('no positions, or one that is not a number: no bounds, the origin 2 m ahead', () {
    expect(splatBoundsOf(const []), isNull);
    expect(splatBoundsOf(const [0, 0, 0, double.nan, 1, 1]), isNull);
    final view = splatFirstView(null, 'yDown');
    expect(view.object, isFalse);
    expect(view.position, const [0.0, 1.3, -2.0]);
  });

  test('the narrower side spans 60 degrees, in landscape and in portrait', () {
    expect(splatVerticalFov(16 / 9), 60);
    expect(splatVerticalFov(1.5), 60);
    final portrait = splatVerticalFov(1080 / 2340);
    final horizontal = 2 * math.atan(math.tan(portrait * math.pi / 360) * (1080 / 2340)) * 180 / math.pi;
    _near(horizontal, 60, 1e-9, 'portrait');
  });

  test('an object fits the narrower side whatever way it is turned; a place has its centre under the eye', () {
    final axes = _expected['axes_v2.spz'] as Map<String, dynamic>;
    final bounds = splatBoundsOf(_doubles(axes['positions']))!;
    for (final upright in splatUprights) {
      final view = splatFirstView(bounds, upright);
      final world = splatWorldBounds(bounds, view.pitch, view.position);
      final limit = math.tan(math.pi / 6) * 1.0001;
      for (var corner = 0; corner < 8; corner++) {
        final point = [
          for (var axis = 0; axis < 3; axis++) (corner >> axis) & 1 == 1 ? world.high[axis] : world.low[axis],
        ];
        final depth = view.eye[2] - point[2];
        expect(depth, greaterThan(0), reason: 'in front of the eye');
        expect((point[0] - view.eye[0]).abs() / depth, lessThan(limit), reason: '$upright x');
        expect((point[1] - view.eye[1]).abs() / depth, lessThan(limit), reason: '$upright y');
      }
      // The centre of the file shows at the target
      final centre = view.place(bounds.center);
      for (var axis = 0; axis < 3; axis++) {
        _near(centre[axis], view.center[axis], 1e-9, '$upright centre');
      }
    }
    final room = _expected['room_colmap.spz'] as Map<String, dynamic>;
    final roomBounds = splatBoundsOf(_doubles(room['positions']))!;
    final view = splatFirstView(roomBounds, 'yDown');
    final world = splatWorldBounds(roomBounds, view.pitch, view.position);
    _near((world.low[1] + world.high[1]) / 2, 1.6 - 0.3, 1e-9, 'room height');
    _near((world.low[0] + world.high[0]) / 2, 0, 1e-9, 'room x');
  });
}
