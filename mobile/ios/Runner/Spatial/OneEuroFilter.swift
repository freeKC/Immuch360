import Foundation

/// One Euro filter (Casiez, Roussel and Vogel, CHI 2012): a low pass filter whose cutoff frequency rises with the
/// speed of the signal. A still head gives a steady value (little jitter), a moving head is followed with little lag.
///
/// [minCutoff] (Hz) sets the smoothing at rest, [beta] how fast the cutoff rises with the speed, [derivativeCutoff]
/// (Hz) the smoothing of the speed estimate itself.
final class OneEuroFilter {
  var minCutoff: Double
  var beta: Double
  var derivativeCutoff: Double

  private var lastValue: Double?
  private var lastDerivative: Double = 0
  private var lastTime: TimeInterval?

  init(minCutoff: Double = 1.0, beta: Double = 0.02, derivativeCutoff: Double = 1.0) {
    self.minCutoff = minCutoff
    self.beta = beta
    self.derivativeCutoff = derivativeCutoff
  }

  /// Forgets the history: the next sample passes through unchanged
  func reset() {
    lastValue = nil
    lastDerivative = 0
    lastTime = nil
  }

  /// Filters [value], measured at [time] (seconds, any monotonic clock)
  func filter(_ value: Double, at time: TimeInterval) -> Double {
    guard let previousValue = lastValue, let previousTime = lastTime else {
      lastValue = value
      lastDerivative = 0
      lastTime = time
      return value
    }
    // Two samples with the same time stamp would divide by zero
    let elapsed = max(time - previousTime, 0.001)
    let derivative = (value - previousValue) / elapsed
    let smoothedDerivative = lastDerivative + Self.alpha(cutoff: derivativeCutoff, elapsed: elapsed)
      * (derivative - lastDerivative)
    let cutoff = minCutoff + beta * abs(smoothedDerivative)
    let smoothed = previousValue + Self.alpha(cutoff: cutoff, elapsed: elapsed) * (value - previousValue)

    lastValue = smoothed
    lastDerivative = smoothedDerivative
    lastTime = time
    return smoothed
  }

  /// Weight of the new sample for an exponential smoothing with this cutoff frequency
  private static func alpha(cutoff: Double, elapsed: Double) -> Double {
    let timeConstant = 1.0 / (2.0 * Double.pi * cutoff)
    return 1.0 / (1.0 + timeConstant / elapsed)
  }
}
