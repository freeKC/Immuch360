// Spatial 2.5D on the computers (release 53): from the positions of the viewer (viewer_position.dart) to the viewpoint
// p of the view, between the left eye (0) and the right one (1). The same for every source:
// - p = 0.5 + 0.35 x sensitivity x, reversed on request, kept between 0.15 and 0.85 as on the phones (HeadViewpoint of
//   HeadTracker.kt): beyond, the views would show too much of what neither eye saw;
// - the view follows a new position with the time constant of its source (none for a source that smooths itself);
// - no one seen: p glides back to 0.5 over one second; someone seen again: p glides in over 0.3 s from where it was.
//   Both as on the phones, with the same smooth step.

import 'dart:math' as math;

import 'package:immich_mobile/desktop/spatial/viewer_position.dart';

/// The limits of the viewpoint and its centre, as on the phones
const spatialViewpointMin = 0.15;
const spatialViewpointMax = 0.85;
const spatialViewpointCentre = 0.5;

/// How far p moves for a position at the end of the range ([ViewerPosition.x] of 1) at the default sensitivity
const spatialViewpointGain = 0.35;

/// The glide back to the centre when no one is seen, and the glide in when someone is seen again
const spatialLostGlide = Duration(seconds: 1);
const spatialFoundGlide = Duration(milliseconds: 300);

/// The sensitivities the settings offer, in percent of the default
const spatialSensitivityMin = 25;
const spatialSensitivityMax = 200;
const spatialSensitivityDefault = 100;

/// The viewpoint of a 2.5D view at [ViewerPosition.x] of [x]: [sensitivity] (1 by default) and [reverse] applied, kept
/// within the limits
double spatialViewpointOf(double x, {double sensitivity = 1, bool reverse = false}) =>
    (spatialViewpointCentre + spatialViewpointGain * sensitivity * (reverse ? -x : x)).clamp(
      spatialViewpointMin,
      spatialViewpointMax,
    );

double _smoothStep(double t) {
  final c = t.clamp(0.0, 1.0);
  return c * c * (3 - 2 * c);
}

double _mix(double a, double b, double t) => a + (b - a) * t;

/// Follows the positions of one source; read [valueAt] on each frame
class SpatialViewpoint {
  SpatialViewpoint({required this.followTime, this.sensitivity = 1, this.reverse = false});

  /// The time constant of the follow, that of the source
  Duration followTime;

  /// 1 by default; see [spatialViewpointOf]
  double sensitivity;
  bool reverse;

  double? _x;
  double _followed = spatialViewpointCentre;
  Duration? _last;
  Duration? _lostSince;
  double _lostFrom = spatialViewpointCentre;
  Duration? _foundSince;
  double _foundFrom = spatialViewpointCentre;

  /// Whether no one is seen now (no position yet counts as seen at the centre)
  bool get lost => _lostSince != null;

  /// Where the last position asks the view to be
  double get target =>
      _x == null ? spatialViewpointCentre : spatialViewpointOf(_x!, sensitivity: sensitivity, reverse: reverse);

  /// Takes [position] in at [now] (the clock of [valueAt])
  void add(ViewerPosition position, Duration now) {
    final current = valueAt(now);
    if (!position.seen) {
      if (_lostSince == null) {
        _lostSince = now;
        _lostFrom = current;
        _foundSince = null;
      }
      return;
    }
    _x = position.x;
    if (_lostSince != null) {
      // Seen again: a new start, glided in from where the view is
      _lostSince = null;
      _foundSince = now;
      _foundFrom = current;
      _followed = target;
    }
  }

  /// The viewpoint at [now], a monotonic time that never goes back
  double valueAt(Duration now) {
    final last = _last ?? now;
    _last = now;
    final lostSince = _lostSince;
    if (lostSince != null) {
      final glided = _mix(_lostFrom, spatialViewpointCentre, _smoothStep(_fraction(now - lostSince, spatialLostGlide)));
      _followed = glided;
      return glided;
    }
    final goal = target;
    final dt = (now - last).inMicroseconds / 1e6;
    final tau = followTime.inMicroseconds / 1e6;
    if (tau <= 0 || dt >= tau * 20) {
      _followed = goal;
    } else if (dt > 0) {
      _followed += (goal - _followed) * (1 - math.exp(-dt / tau));
    }
    final foundSince = _foundSince;
    if (foundSince == null) {
      return _followed;
    }
    final k = _smoothStep(_fraction(now - foundSince, spatialFoundGlide));
    if (k >= 1) {
      _foundSince = null;
      return _followed;
    }
    return _mix(_foundFrom, _followed, k);
  }

  /// Whether the view still moves on its own at [now]: a glide runs, or the follow has not arrived
  bool movingAt(Duration now) {
    final lostSince = _lostSince;
    if (lostSince != null) {
      return now - lostSince < spatialLostGlide;
    }
    return _foundSince != null || (target - _followed).abs() > 1e-4;
  }

  static double _fraction(Duration elapsed, Duration total) => elapsed.inMicroseconds / total.inMicroseconds;
}
