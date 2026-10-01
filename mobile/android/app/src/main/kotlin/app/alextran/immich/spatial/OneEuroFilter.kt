package app.alextran.immich.spatial

import kotlin.math.PI
import kotlin.math.abs

/**
 * One Euro filter (Casiez, Roussel and Vogel, CHI 2012): a low pass filter whose cutoff frequency rises with the speed
 * of the signal. A still head gives a steady value (low cutoff, little jitter), a moving head is followed with little
 * lag (high cutoff).
 *
 * [minCutoff] is the cutoff in Hz when the signal does not move, [beta] how fast the cutoff rises with the speed (in
 * units of the signal per second), [derivativeCutoff] the cutoff in Hz of the low pass filter applied to the speed.
 */
class OneEuroFilter(
  private val minCutoff: Double = 1.0,
  private val beta: Double = 0.02,
  private val derivativeCutoff: Double = 1.0,
) {
  private var hasValue = false
  private var lastTimeNanos = 0L
  private var value = 0.0
  private var derivative = 0.0

  /** Filters [x] measured at [timeNanos] (any monotonic clock) and returns the filtered value. */
  fun filter(x: Double, timeNanos: Long): Double {
    if (!hasValue) {
      hasValue = true
      lastTimeNanos = timeNanos
      value = x
      derivative = 0.0
      return x
    }
    // A repeated or out of order timestamp would divide by zero: count it as one millisecond
    val dt = ((timeNanos - lastTimeNanos) / 1e9).coerceAtLeast(1e-3)
    lastTimeNanos = timeNanos

    // Speed of the signal, measured against the previous filtered value and smoothed on its own
    val rawDerivative = (x - value) / dt
    derivative += alpha(derivativeCutoff, dt) * (rawDerivative - derivative)

    // The faster the signal moves, the higher the cutoff, the less lag
    val cutoff = minCutoff + beta * abs(derivative)
    value += alpha(cutoff, dt) * (x - value)
    return value
  }

  /** Forgets the history: the next value passes through unfiltered. */
  fun reset() {
    hasValue = false
    derivative = 0.0
  }

  /** Smoothing factor of an exponential filter with the given cutoff frequency, for a sample period of [dt] seconds */
  private fun alpha(cutoff: Double, dt: Double): Double {
    val tau = 1.0 / (2.0 * PI * cutoff)
    return 1.0 / (1.0 + tau / dt)
  }
}
