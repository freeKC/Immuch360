// A port of the phones' OneEuroFilter.kt (mobile/android/app/src/main/kotlin/app/alextran/immich/spatial), same
// constants, same steps; test/desktop/spatial/head_tracker_test.dart checks it against values printed by the Kotlin
// class.

import 'dart:math' as math;

/// One Euro filter (Casiez, Roussel and Vogel, CHI 2012): a low pass filter whose cutoff frequency rises with the speed
/// of the signal. A still head gives a steady value (low cutoff, little jitter), a moving head is followed with little
/// lag (high cutoff).
///
/// [minCutoff] is the cutoff in Hz when the signal does not move, [beta] how fast the cutoff rises with the speed (in
/// units of the signal per second), [derivativeCutoff] the cutoff in Hz of the low pass filter applied to the speed.
class OneEuroFilter {
  OneEuroFilter({this.minCutoff = 1.0, this.beta = 0.02, this.derivativeCutoff = 1.0});

  final double minCutoff;
  final double beta;
  final double derivativeCutoff;

  bool _hasValue = false;
  int _lastTimeNanos = 0;
  double _value = 0;
  double _derivative = 0;

  /// Filters [x] measured at [timeNanos] (any monotonic clock) and returns the filtered value
  double filter(double x, int timeNanos) {
    if (!_hasValue) {
      _hasValue = true;
      _lastTimeNanos = timeNanos;
      _value = x;
      _derivative = 0;
      return x;
    }
    // A repeated or out of order timestamp would divide by zero: count it as one millisecond
    final dt = math.max((timeNanos - _lastTimeNanos) / 1e9, 1e-3);
    _lastTimeNanos = timeNanos;

    // Speed of the signal, measured against the previous filtered value and smoothed on its own
    final rawDerivative = (x - _value) / dt;
    _derivative += _alpha(derivativeCutoff, dt) * (rawDerivative - _derivative);

    // The faster the signal moves, the higher the cutoff, the less lag
    final cutoff = minCutoff + beta * _derivative.abs();
    _value += _alpha(cutoff, dt) * (x - _value);
    return _value;
  }

  /// Forgets the history: the next value passes through unfiltered
  void reset() {
    _hasValue = false;
    _derivative = 0;
  }

  /// Smoothing factor of an exponential filter with the given cutoff frequency, for a sample period of [dt] seconds
  static double _alpha(double cutoff, double dt) {
    final tau = 1.0 / (2.0 * math.pi * cutoff);
    return 1.0 / (1.0 + tau / dt);
  }
}
