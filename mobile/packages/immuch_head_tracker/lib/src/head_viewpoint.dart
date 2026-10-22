// From head samples to the viewpoint of the synthesised view: ports of the phones' HeadViewpoint and of the filtering
// step of HeadTracker.report (HeadTracker.kt), same constants. The Kotlin class computes in 32 bit floats, this port in
// doubles; test/desktop/spatial/head_tracker_test.dart checks both against values printed by the Kotlin classes.

import 'dart:typed_data';

import 'package:immuch_head_tracker/src/head_sample.dart';
import 'package:immuch_head_tracker/src/one_euro_filter.dart';

/// The One Euro filter of the phones on headX: it runs in pixels of a 640 pixel wide image, the unit its parameters
/// are tuned for (on the normalised position the same beta would barely raise the cutoff and a moving head would lag),
/// and a face found again after a loss starts a new trajectory instead of gliding from where the head was seconds ago.
class HeadXFilter {
  HeadXFilter({OneEuroFilter? filter}) : _filter = filter ?? OneEuroFilter();

  static const scale = 640.0;

  final OneEuroFilter _filter;
  bool _wasLost = true;

  /// The last raw and filtered headX, NaN before the first face
  double rawX = double.nan;
  double filteredX = double.nan;

  /// Takes one sample; returns the filtered headX of a face, null for a sample without one
  double? add(HeadSample sample) {
    if (!sample.hasFace) {
      _wasLost = sample.lost;
      return null;
    }
    return addFace(sample.headX, sample.timeNanos);
  }

  /// Takes the headX of a face seen at [timeNanos]
  double addFace(double headX, int timeNanos) {
    if (_wasLost) {
      _filter.reset();
    }
    _wasLost = false;
    rawX = headX;
    filteredX = _filter.filter(headX * scale, timeNanos) / scale;
    return filteredX;
  }

  /// Marks the face as lost: the next face starts afresh
  void lose() => _wasLost = true;

  void reset() {
    _filter.reset();
    _wasLost = true;
    rawX = double.nan;
    filteredX = double.nan;
  }
}

/// Turns head samples into the viewpoint of the synthesised view: 0 is the left camera, 0.5 the centre, 1 the right
/// camera.
///
/// The first face after [recenter] (and after creation) sets the centre. Then p = 0.5 + (headX - centre) * sensitivity,
/// kept between 0.15 and 0.85. When the tracker reports the face lost (no face for 300 ms, during which the viewpoint
/// holds still) the viewpoint eases back to 0.5 over one second; a face found again, or a new centre, eases in over
/// 0.3 s.
class HeadViewpoint {
  /// The phones' default; the desktop starts at [desktopSensitivity], the user sitting further from the screen
  static const defaultSensitivity = 2.0;
  static const desktopSensitivity = 3.0;
  static const minSensitivity = 0.5;
  static const maxSensitivity = 4.0;
  static const minViewpoint = 0.15;
  static const maxViewpoint = 0.85;
  static const centreViewpoint = 0.5;
  static const _lostEaseNanos = 1000000000;
  static const _foundEaseNanos = 300000000;

  double sensitivity = defaultSensitivity;

  double _centre = double.nan;
  bool _recenterPending = true;
  double _target = centreViewpoint;

  /// When the face was reported lost, -1 while a face is tracked
  int _lostSinceNanos = -1;
  double _lostFrom = centreViewpoint;

  /// When the face was found again after a loss, -1 when no ease in runs
  int _foundSinceNanos = -1;
  double _foundFrom = centreViewpoint;

  /// The next face sets the centre
  void recenter() {
    _recenterPending = true;
  }

  void onFace(double headX, int now) {
    if (headX.isNaN) {
      return;
    }
    if (_recenterPending || _centre.isNaN) {
      _centre = headX;
      _recenterPending = false;
      // The viewpoint goes back to the middle smoothly rather than jumping there
      _foundFrom = valueAt(now);
      _foundSinceNanos = now;
    }
    if (_lostSinceNanos >= 0) {
      _foundFrom = valueAt(now);
      _foundSinceNanos = now;
      _lostSinceNanos = -1;
    }
    _target = (centreViewpoint + (headX - _centre) * sensitivity).clamp(
      minViewpoint,
      maxViewpoint,
    );
  }

  void onLost(int now) {
    if (_lostSinceNanos < 0) {
      _lostFrom = valueAt(now);
      _lostSinceNanos = now;
      _foundSinceNanos = -1;
    }
  }

  /// Takes a sample: its filtered headX (from [HeadXFilter]) when it holds a face, the loss when it says lost
  void onSample(HeadSample sample, double? filteredX) {
    if (sample.hasFace && filteredX != null) {
      onFace(filteredX, sample.timeNanos);
    } else if (sample.lost) {
      onLost(sample.timeNanos);
    }
  }

  /// The viewpoint at [now], in the clock of the samples
  double valueAt(int now) {
    if (_lostSinceNanos >= 0) {
      return _mix(
        _lostFrom,
        centreViewpoint,
        _smoothStep(_float(now - _lostSinceNanos) / _lostEaseNanos),
      );
    }
    if (_foundSinceNanos >= 0) {
      // The elapsed time as a 32 bit float, as the Kotlin class has it: a few nanoseconds before the end of the ease it
      // already reads 1, and the ease ends on the same frame on both
      final t = _float(now - _foundSinceNanos) / _foundEaseNanos;
      if (t < 1) {
        return _mix(_foundFrom, _target, _smoothStep(t));
      }
      _foundSinceNanos = -1;
    }
    return _target;
  }

  /// Whether the viewpoint still moves on its own (an ease runs), so it needs updates at the display rate
  bool isAnimating(int now) =>
      (_lostSinceNanos >= 0 && now - _lostSinceNanos < _lostEaseNanos) ||
      (_foundSinceNanos >= 0 && now - _foundSinceNanos < _foundEaseNanos);

  static final _single = Float32List(1);

  static double _float(int nanos) => (_single..[0] = nanos.toDouble())[0];

  static double _smoothStep(double t) {
    final x = t.clamp(0.0, 1.0);
    return x * x * (3 - 2 * x);
  }

  static double _mix(double from, double to, double t) =>
      from + (to - from) * t;
}
