import Foundation

// Pure Swift (Foundation and the standard library only): the CI's macOS job compiles this file with
// ios/SwiftTests/main.swift and runs the tests without a simulator (ios/SwiftTests/run.sh).

/// A rotation as a unit quaternion (w, x, y, z), Hamilton product, acting on vectors
struct StabilizationQuaternion: Equatable, Sendable {
  var w: Double
  var x: Double
  var y: Double
  var z: Double

  static let identity = StabilizationQuaternion(w: 1, x: 0, y: 0, z: 0)
}

/// The three rows the stitch shader multiplies each output view direction by (RawStitchShaders.metal,
/// rawStitchStabilized): float4 rows whose xyz are the rows of the 3 x 3 matrix, w unused
struct StabilizationRows: Equatable, Sendable {
  var row0: SIMD4<Float>
  var row1: SIMD4<Float>
  var row2: SIMD4<Float>

  static let identity = StabilizationRows(
    row0: SIMD4<Float>(1, 0, 0, 0), row1: SIMD4<Float>(0, 1, 0, 0), row2: SIMD4<Float>(0, 0, 1, 0))

  /// What the shader does with them: the direction of the stitched picture that the output direction [d] shows
  func apply(_ d: SIMD3<Double>) -> SIMD3<Double> {
    func dot(_ row: SIMD4<Float>) -> Double {
      Double(row.x) * d.x + Double(row.y) * d.y + Double(row.z) * d.z
    }
    return SIMD3<Double>(dot(row0), dot(row1), dot(row2))
  }
}

/// The stabilisation of a raw 360° video with the motion track of its camera (issue 14), as Flutter builds it
/// (lib/domain/models/raw/stabilization.dart): for each frame, its presentation time on the timeline of the video and
/// the rotation K of the sphere of the stitched frame that shows the world level and steady. A point of the stitched
/// frame at direction d of its view frame (x to the right, y down, z forward: the frame of the stitch, the centre of
/// the equirectangular picture straight ahead) is shown at direction K d. The same table and convention as the Android
/// player (StabilizationTable.kt).
///
/// The iOS player turns the picture inside the stitch (RawStitchCompositor): the output pixel of direction e shows the
/// stitched picture at K^T e, so that the point at d lands at K d. [rows] gives K^T as the shader takes it. The frame
/// is turned at its own composition time: exact per frame, seeks included, and the sphere of SceneKit shows the result
/// as any equirectangular video, whatever its own axes.
///
/// [corrections] holds four values a frame (w, x, y, z), unit quaternions; [timesUs] rise.
struct StabilizationTable: Sendable {
  /// Corrections whose norm is farther than this from 1 are refused: a table Flutter did not build
  static let normTolerance = 1e-3

  let timesUs: [Int64]
  let corrections: [Double]

  private init(timesUs: [Int64], corrections: [Double]) {
    self.timesUs = timesUs
    self.corrections = corrections
  }

  /// The table of [timesUs] and [corrections] as setStabilization gives them, or nil with the reason in [onRefused]
  /// for one that cannot be used: none, lengths that do not match, times that do not rise, values that are not unit
  /// quaternions
  static func of(
    timesUs: [Int64]?, corrections: [Double]?, onRefused: (String) -> Void = { _ in }
  ) -> StabilizationTable? {
    guard let timesUs, let corrections, !timesUs.isEmpty else {
      onRefused("no frame")
      return nil
    }
    guard corrections.count == 4 * timesUs.count else {
      onRefused("\(corrections.count) values for \(timesUs.count) frames")
      return nil
    }
    for i in 1..<timesUs.count where timesUs[i] <= timesUs[i - 1] {
      onRefused("frame \(i) at \(timesUs[i]) us does not follow \(timesUs[i - 1]) us")
      return nil
    }
    for i in 0..<timesUs.count {
      let o = 4 * i
      let norm = (corrections[o] * corrections[o] + corrections[o + 1] * corrections[o + 1]
        + corrections[o + 2] * corrections[o + 2] + corrections[o + 3] * corrections[o + 3]).squareRoot()
      if !norm.isFinite || abs(norm - 1) > normTolerance {
        onRefused("frame \(i) has a correction of norm \(norm)")
        return nil
      }
    }
    return StabilizationTable(timesUs: timesUs, corrections: corrections)
  }

  /// Frames in the table
  var count: Int { timesUs.count }

  /// Presentation time of the first and of the last frame, in microseconds
  var firstTimeUs: Int64 { timesUs[0] }
  var lastTimeUs: Int64 { timesUs[timesUs.count - 1] }

  /// The correction at [timeUs] of the timeline: the one of the frame at that time, blended (slerp) between the frames
  /// before and after it, the first or the last one outside them. Binary search: a lookup per frame costs nothing next
  /// to the stitch.
  func quaternion(at timeUs: Int64) -> StabilizationQuaternion {
    if timeUs <= timesUs[0] { return quaternion(frame: 0) }
    let last = timesUs.count - 1
    if timeUs >= timesUs[last] { return quaternion(frame: last) }
    // The last frame at or before timeUs, and the one after it
    var low = 0
    var high = last
    while high - low > 1 {
      let middle = (low + high) / 2
      if timesUs[middle] <= timeUs { low = middle } else { high = middle }
    }
    let share = Double(timeUs - timesUs[low]) / Double(timesUs[high] - timesUs[low])
    return StabilizationMath.slerp(quaternion(frame: low), quaternion(frame: high), share)
  }

  /// The rows of K^T at [timeUs] for the stitch shader (see the type)
  func rows(at timeUs: Int64) -> StabilizationRows {
    StabilizationMath.stitchRows(quaternion(at: timeUs))
  }

  private func quaternion(frame: Int) -> StabilizationQuaternion {
    let o = 4 * frame
    return StabilizationQuaternion(
      w: corrections[o], x: corrections[o + 1], y: corrections[o + 2], z: corrections[o + 3])
  }
}

/// Quaternions (w, x, y, z), Hamilton product, rotations acting on vectors
enum StabilizationMath {
  /// The rotation blended between [a] and [b] at [share] (0 at a, 1 at b), along the shorter arc, unit long
  static func slerp(_ a: StabilizationQuaternion, _ b: StabilizationQuaternion, _ share: Double)
    -> StabilizationQuaternion
  {
    var dot = a.w * b.w + a.x * b.x + a.y * b.y + a.z * b.z
    let sign: Double = dot < 0 ? -1 : 1
    dot *= sign
    let wa: Double
    var wb: Double
    if dot > 1 - 1e-10 {
      // Within about 1e-5 radian: a straight blend is as good
      wa = 1 - share
      wb = share
    } else {
      let angle = acos(min(1, dot))
      let sine = sin(angle)
      wa = sin((1 - share) * angle) / sine
      wb = sin(share * angle) / sine
    }
    wb *= sign
    var q = StabilizationQuaternion(
      w: wa * a.w + wb * b.w, x: wa * a.x + wb * b.x, y: wa * a.y + wb * b.y, z: wa * a.z + wb * b.z)
    let norm = (q.w * q.w + q.x * q.x + q.y * q.y + q.z * q.z).squareRoot()
    q.w /= norm
    q.x /= norm
    q.y /= norm
    q.z /= norm
    return q
  }

  /// The rotation matrix of the unit quaternion [q], rows first: m[r][c]
  static func matrix(_ q: StabilizationQuaternion) -> [[Double]] {
    let (w, x, y, z) = (q.w, q.x, q.y, q.z)
    return [
      [1 - 2 * (y * y + z * z), 2 * (x * y - w * z), 2 * (x * z + w * y)],
      [2 * (x * y + w * z), 1 - 2 * (x * x + z * z), 2 * (y * z - w * x)],
      [2 * (x * z - w * y), 2 * (y * z + w * x), 1 - 2 * (x * x + y * y)],
    ]
  }

  /// The rows of K^T for the stitch shader, K the rotation of [q]: row i of K^T is column i of K
  static func stitchRows(_ q: StabilizationQuaternion) -> StabilizationRows {
    let k = matrix(q)
    func row(_ i: Int) -> SIMD4<Float> {
      SIMD4<Float>(Float(k[0][i]), Float(k[1][i]), Float(k[2][i]), 0)
    }
    return StabilizationRows(row0: row(0), row1: row(1), row2: row(2))
  }
}

/// The table the stitch of one stitched raw video applies (RawStitchInstruction): set on the main thread by the player
/// (nil when off, while the track is read, or for a file without one), read by RawStitchCompositor on its render queue
/// for every frame. [timeOffsetUs] goes from the time of the composition to the time of the table, whose zero is the
/// first frame of the lead track (zero for the files of these cameras).
final class RawStitchStabilization: @unchecked Sendable {
  private let lock = NSLock()
  private var table: StabilizationTable?
  private var firstFrameReported = false
  private var onFirstFrame: (@Sendable () -> Void)?

  let timeOffsetUs: Int64

  init(timeOffsetUs: Int64 = 0) {
    self.timeOffsetUs = timeOffsetUs
  }

  /// The table the frames get from now on, nil for none. [onFirstFrame] runs once, on the render queue, when the
  /// first frame is drawn with this table.
  func setTable(_ table: StabilizationTable?, onFirstFrame: (@Sendable () -> Void)? = nil) {
    lock.lock()
    defer { lock.unlock() }
    self.table = table
    self.onFirstFrame = onFirstFrame
    firstFrameReported = false
  }

  /// Whether a table turns the frames
  var isActive: Bool {
    lock.lock()
    defer { lock.unlock() }
    return table != nil
  }

  /// The rows the frame at [compositionTimeUs] gets: the identity without a table
  func rows(atCompositionTimeUs compositionTimeUs: Int64) -> StabilizationRows {
    lock.lock()
    let table = self.table
    var report: (@Sendable () -> Void)?
    if table != nil && !firstFrameReported {
      firstFrameReported = true
      report = onFirstFrame
    }
    lock.unlock()
    guard let table else { return .identity }
    report?()
    return table.rows(at: compositionTimeUs &+ timeOffsetUs)
  }
}
