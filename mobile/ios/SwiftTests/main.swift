// Unit tests of the pure Swift of the iOS 360° player's stabilisation (issue 14): StabilizationTable.swift and
// PlayerStabilization.swift of Runner/Spherical, compiled with this file by run.sh (swiftc, no simulator, no Xcode
// project target). The CI's macOS job runs them (.github/workflows/immuch360-ios-check.yml).
//
// The sign convention is pinned the way the Android tests pin it (StabilizationTableTest.kt), on the stitch: a point
// of the stitched picture at direction d of the view frame (x right, y down, z forward) must be shown at K d, so the
// output pixel of direction e samples the picture at rows.apply(e). The math of the tests (Rodrigues, the matrix of a
// quaternion, the view direction of an output pixel) is written here apart from the code under test.
//
// Arguments: the paths of RawStitchShaders.metal and RawStitchRenderer.swift, for the check of the uniform layouts.

import Foundation

// MARK: - A small harness

var failures = 0
var checks = 0
var currentTest = ""

func check(_ condition: Bool, _ message: @autoclosure () -> String = "", line: Int = #line) {
  checks += 1
  if !condition {
    failures += 1
    print("FAIL \(currentTest) line \(line): \(message())")
  }
}

func near(_ a: Double, _ b: Double, _ tolerance: Double) -> Bool { abs(a - b) <= tolerance }

func checkVector(
  _ expected: SIMD3<Double>, _ actual: SIMD3<Double>, _ tolerance: Double, _ message: String = "", line: Int = #line
) {
  let ok = near(expected.x, actual.x, tolerance) && near(expected.y, actual.y, tolerance)
    && near(expected.z, actual.z, tolerance)
  check(ok, "\(message) expected \(expected), got \(actual)", line: line)
}

var tests: [(String, () -> Void)] = []
func test(_ name: String, _ body: @escaping () -> Void) { tests.append((name, body)) }

// MARK: - Math of the tests, apart from the code under test

let degree = Double.pi / 180

typealias Matrix = [[Double]]

/// The rotation by [angle] radians about [axis], right handed (Rodrigues)
func rotation(_ axis: SIMD3<Double>, _ angle: Double) -> Matrix {
  let n = (axis * axis).sum().squareRoot()
  let (x, y, z) = (axis.x / n, axis.y / n, axis.z / n)
  let c = cos(angle)
  let s = sin(angle)
  let t = 1 - c
  return [
    [t * x * x + c, t * x * y - s * z, t * x * z + s * y],
    [t * x * y + s * z, t * y * y + c, t * y * z - s * x],
    [t * x * z - s * y, t * y * z + s * x, t * z * z + c],
  ]
}

func times(_ m: Matrix, _ v: SIMD3<Double>) -> SIMD3<Double> {
  SIMD3<Double>(
    m[0][0] * v.x + m[0][1] * v.y + m[0][2] * v.z,
    m[1][0] * v.x + m[1][1] * v.y + m[1][2] * v.z,
    m[2][0] * v.x + m[2][1] * v.y + m[2][2] * v.z)
}

/// The quaternion of the rotation by [angle] about [axis]
func quaternion(_ axis: SIMD3<Double>, _ angle: Double) -> StabilizationQuaternion {
  let n = (axis * axis).sum().squareRoot()
  let s = sin(angle / 2) / n
  return StabilizationQuaternion(w: cos(angle / 2), x: axis.x * s, y: axis.y * s, z: axis.z * s)
}

/// The rotation matrix of the unit quaternion [q], acting on vectors
func matrixOf(_ q: StabilizationQuaternion) -> Matrix {
  let (w, x, y, z) = (q.w, q.x, q.y, q.z)
  return [
    [1 - 2 * (y * y + z * z), 2 * (x * y - w * z), 2 * (x * z + w * y)],
    [2 * (x * y + w * z), 1 - 2 * (x * x + z * z), 2 * (y * z - w * x)],
    [2 * (x * z - w * y), 2 * (y * z + w * x), 1 - 2 * (x * x + y * y)],
  ]
}

/// The direction an output pixel of the stitch shows (RawStitchShaders.metal, rawStitchViewDirection, and
/// dual_fisheye_math.dart viewDirection): longitude (2 u - 1) pi, latitude pi / 2 - pi v, u and v from the top left
func viewDirection(_ u: Double, _ v: Double) -> SIMD3<Double> {
  let lon = (2 * u - 1) * Double.pi
  let lat = Double.pi / 2 - Double.pi * v
  return SIMD3<Double>(cos(lat) * sin(lon), -sin(lat), cos(lat) * cos(lon))
}

let xAxis = SIMD3<Double>(1, 0, 0)
let yAxis = SIMD3<Double>(0, 1, 0)
let zAxis = SIMD3<Double>(0, 0, 1)

func tableOf(_ times: [Int64], _ quaternions: [StabilizationQuaternion]) -> StabilizationTable {
  let values = quaternions.flatMap { [$0.w, $0.x, $0.y, $0.z] }
  guard let table = StabilizationTable.of(timesUs: times, corrections: values, onRefused: { print("refused: \($0)") })
  else {
    fatalError("a table of the tests was refused")
  }
  return table
}

/// Whether two quaternions are the same rotation (q and -q are)
func sameRotation(_ a: StabilizationQuaternion, _ b: StabilizationQuaternion, _ tolerance: Double) -> Bool {
  let dot = a.w * b.w + a.x * b.x + a.y * b.y + a.z * b.z
  return near(abs(dot), 1, tolerance)
}

/// The rows of K itself, the wrong convention: the checks below must tell them from those of K^T
func wrongRows(_ q: StabilizationQuaternion) -> StabilizationRows {
  let k = matrixOf(q)
  func row(_ i: Int) -> SIMD4<Float> { SIMD4<Float>(Float(k[i][0]), Float(k[i][1]), Float(k[i][2]), 0) }
  return StabilizationRows(row0: row(0), row1: row(1), row2: row(2))
}

// MARK: - The convention on the stitch

/// The camera looks 10 degrees below the horizon, the target is level: the correction is the rotation about x by -10
/// degrees. Whether [rows] show the centre of the picture (what the camera looked at) 10 degrees below the front, and
/// the point 10 degrees above it (the horizon) straight ahead.
func pitchedCameraHolds(_ rows: StabilizationRows) -> Bool {
  let below = SIMD3<Double>(0, sin(10 * degree), cos(10 * degree))
  let centre = rows.apply(below)
  let ahead = rows.apply(zAxis)
  let aboveCentre = viewDirection(0.5, 0.5 - 10.0 / 180)
  let tolerance = 1e-6
  return near(centre.x, 0, tolerance) && near(centre.y, 0, tolerance) && near(centre.z, 1, tolerance)
    && near(ahead.x, aboveCentre.x, tolerance) && near(ahead.y, aboveCentre.y, tolerance)
    && near(ahead.z, aboveCentre.z, tolerance)
}

test("the output pixels look where the stitch says") {
  // The centre of the picture straight ahead, its top up (y down), its right half to the right
  checkVector(zAxis, viewDirection(0.5, 0.5), 1e-12)
  checkVector(SIMD3<Double>(0, -1, 0), viewDirection(0.5, 0), 1e-12)
  checkVector(xAxis, viewDirection(0.75, 0.5), 1e-12)
}

test("without a table the stitch is unchanged") {
  for (u, v) in [(0.1, 0.3), (0.5, 0.5), (0.8, 0.9)] {
    let d = viewDirection(u, v)
    checkVector(d, StabilizationRows.identity.apply(d), 1e-12)
  }
  check(RawStitchStabilization().rows(atCompositionTimeUs: 123_456) == .identity)
}

test("a camera pitched down has its centre drawn below the front") {
  let k = quaternion(xAxis, -10 * degree)
  let table = tableOf([0], [k])
  check(pitchedCameraHolds(table.rows(at: 0)), "the rows of K^T")
  // The mutation check: the rows of K itself turn the picture the other way, which this test sees
  check(!pitchedCameraHolds(wrongRows(k)), "the rows of K must fail")
}

test("a rolled camera has its horizon drawn level") {
  // The camera rolled 15 degrees about its forward axis: the world's right (1, 0, 0) is seen at C^T (1, 0, 0), row 0
  // of C; the stitch must show that point of the picture at the right of the view, on the horizon
  let roll = quaternion(zAxis, 15 * degree)
  let camera = matrixOf(roll)
  let seenRight = SIMD3<Double>(camera[0][0], camera[0][1], camera[0][2])
  let table = tableOf([0], [roll])
  checkVector(seenRight, table.rows(at: 0).apply(xAxis), 1e-6)
  let wrong = wrongRows(roll).apply(xAxis)
  check(!near(wrong.y, seenRight.y, 1e-3), "the rows of K must fail")
}

test("any correction draws the point at d where K d says") {
  var generator = SystemRandomNumberGenerator()
  var mutationsSeen = 0
  for _ in 0..<50 {
    let axis = SIMD3<Double>(
      Double.random(in: -1...1, using: &generator), Double.random(in: -1...1, using: &generator),
      Double.random(in: -1...1, using: &generator) + 0.01)
    let angle = Double.random(in: -0.95...0.95, using: &generator) * Double.pi
    let q = quaternion(axis, angle)
    let k = matrixOf(q)
    let rows = tableOf([0], [q]).rows(at: 0)
    for u in [0.1, 0.5, 0.8] {
      for v in [0.3, 0.5, 0.9] {
        let d = viewDirection(u, v)
        // The output pixel at K d samples the picture at d
        checkVector(d, rows.apply(times(k, d)), 1e-5, "angle \(angle) u \(u) v \(v)")
      }
    }
    // q and -q are the same rotation: the same rows
    let negated = tableOf([0], [StabilizationQuaternion(w: -q.w, x: -q.x, y: -q.y, z: -q.z)]).rows(at: 0)
    for i in 0..<4 {
      check(abs(rows.row0[i] - negated.row0[i]) < 1e-6 && abs(rows.row1[i] - negated.row1[i]) < 1e-6
        && abs(rows.row2[i] - negated.row2[i]) < 1e-6)
    }
    let d = viewDirection(0.3, 0.4)
    let wrong = wrongRows(q).apply(times(k, d))
    if abs(angle) > 5 * degree && ((wrong - d) * (wrong - d)).sum() > 1e-6 {
      mutationsSeen += 1
    }
  }
  check(mutationsSeen > 40, "the rows of K must fail for most rotations, failed for \(mutationsSeen) of 50")
}

test("a small turn of the camera is undone in the stitch") {
  // The camera shook 3 degrees to the right between two frames while the target kept its heading: what the camera sees
  // at its centre is the world 3 degrees to the right, and the stitch draws it there
  let shake = quaternion(yAxis, 3 * degree)
  let table = tableOf([0, 33_367], [.identity, shake])
  let seenAhead = times(rotation(yAxis, 3 * degree), zAxis)
  check(seenAhead.x > 0, "the camera looked to the right")
  checkVector(zAxis, table.rows(at: 33_367).apply(seenAhead), 1e-6)
  checkVector(zAxis, table.rows(at: 0).apply(zAxis), 1e-12, "frame 0 is not turned")
  check(abs(wrongRows(shake).apply(seenAhead).x) > 0.05, "the rows of K must fail")
}

// MARK: - The lookup

test("gives the rotation of the frame at its time, blended between frames") {
  // A constant turn about y of 2 degrees a frame, 30 frames a second
  let step: Int64 = 33_367
  let frameTimes = (0..<30).map { Int64($0) * step }
  let table = tableOf(frameTimes, (0..<30).map { quaternion(yAxis, 2.0 * Double($0) * degree) })
  for i in [0, 1, 7, 15, 29] {
    check(sameRotation(quaternion(yAxis, 2.0 * Double(i) * degree), table.quaternion(at: frameTimes[i]), 1e-12),
      "frame \(i)")
  }
  // A quarter of the way from frame 10 to 11: 20.5 degrees
  check(sameRotation(quaternion(yAxis, 20.5 * degree), table.quaternion(at: frameTimes[10] + step / 4), 1e-9))
  // Before the first frame and after the last: those frames
  check(sameRotation(.identity, table.quaternion(at: -500_000), 1e-12))
  check(sameRotation(quaternion(yAxis, 58 * degree), table.quaternion(at: frameTimes[29] + 10_000_000), 1e-12))
  check(table.count == 30)
  check(table.firstTimeUs == 0)
  check(table.lastTimeUs == 29 * step)
}

test("blends along the shorter arc whatever the sign of the neighbours") {
  let a = quaternion(xAxis, 10 * degree)
  let b20 = quaternion(xAxis, 20 * degree)
  let b = StabilizationQuaternion(w: -b20.w, x: -b20.x, y: -b20.y, z: -b20.z)
  let q = tableOf([0, 1000], [a, b]).quaternion(at: 500)
  check(sameRotation(quaternion(xAxis, 15 * degree), q, 1e-12))
  check(near((q.w * q.w + q.x * q.x + q.y * q.y + q.z * q.z).squareRoot(), 1, 1e-12))
}

test("finds the frames of a long table by binary search") {
  // An hour at 30 frames a second, the rotation of frame i about z by (i mod 3000) / 1000 radian
  let count = 108_000
  let frameTimes = (0..<count).map { Int64($0) * 33_367 + 1_234 }
  var values = [Double]()
  values.reserveCapacity(4 * count)
  for i in 0..<count {
    let q = quaternion(zAxis, Double(i % 3000) / 1000)
    values += [q.w, q.x, q.y, q.z]
  }
  guard let table = StabilizationTable.of(timesUs: frameTimes, corrections: values) else {
    check(false, "refused")
    return
  }
  for i in [0, 1, 2999, 3000, 54_321, 107_999] {
    check(sameRotation(quaternion(zAxis, Double(i % 3000) / 1000), table.quaternion(at: frameTimes[i]), 1e-12),
      "frame \(i)")
  }
}

test("refuses a table it cannot use") {
  var reasons: [String] = []
  let one: [Double] = [1, 0, 0, 0]
  check(StabilizationTable.of(timesUs: nil, corrections: one, onRefused: { reasons.append($0) }) == nil)
  check(StabilizationTable.of(timesUs: [], corrections: [], onRefused: { reasons.append($0) }) == nil)
  check(StabilizationTable.of(timesUs: [0, 1], corrections: one, onRefused: { reasons.append($0) }) == nil)
  check(StabilizationTable.of(timesUs: [5, 5], corrections: one + one, onRefused: { reasons.append($0) }) == nil)
  check(StabilizationTable.of(timesUs: [0], corrections: [2, 0, 0, 0], onRefused: { reasons.append($0) }) == nil)
  check(StabilizationTable.of(timesUs: [0], corrections: [.nan, 0, 0, 0], onRefused: { reasons.append($0) }) == nil)
  check(reasons.count == 6, "\(reasons)")
  if reasons.count == 6 {
    check(reasons[2].contains("4 values for 2 frames"), reasons[2])
    check(reasons[3].contains("does not follow"), reasons[3])
  }
  check(StabilizationTable.of(timesUs: [0, 1], corrections: one + one) != nil)
}

// MARK: - The table the compositor reads

/// Counts the calls of a closure the render queue may run
final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  func increment() {
    lock.lock()
    count += 1
    lock.unlock()
  }

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }
}

test("the stitch reads the table at the time of the composition, offset to the table's clock") {
  let shake = quaternion(yAxis, 3 * degree)
  let table = tableOf([0, 33_367], [.identity, shake])
  // A composition that starts 33 367 us after the first frame of the lead track
  let stabilization = RawStitchStabilization(timeOffsetUs: 33_367)
  check(stabilization.rows(atCompositionTimeUs: 0) == .identity, "no table yet")
  check(!stabilization.isActive)
  let reported = Counter()
  stabilization.setTable(table, onFirstFrame: { reported.increment() })
  check(stabilization.isActive)
  check(stabilization.rows(atCompositionTimeUs: 0) == table.rows(at: 33_367), "composition 0 is frame 1")
  _ = stabilization.rows(atCompositionTimeUs: 1000)
  check(reported.value == 1, "the first stabilised frame is told once, told \(reported.value)")
  // A table set again (another item, the switch on again) tells its first frame again; the switch keeps the notice once
  stabilization.setTable(table, onFirstFrame: { reported.increment() })
  _ = stabilization.rows(atCompositionTimeUs: 0)
  check(reported.value == 2)
  stabilization.setTable(nil)
  check(stabilization.rows(atCompositionTimeUs: 0) == .identity, "off: the stitch is unchanged")
  check(!stabilization.isActive)
}

// MARK: - The switch

let twoFrames = tableOf([0, 33_367], [.identity, .identity])

test("a raw video with a track is stabilised once the table comes") {
  let toggle = StabilizationSwitch(enabled: true)
  check(!toggle.buttonVisible, "nothing known yet: no button")
  check(toggle.onTrack(hasTrack: true, table: nil) == nil)
  check(toggle.track == .pending)
  check(toggle.buttonVisible)
  check(toggle.activeTable == nil)
  check(toggle.onTrack(hasTrack: true, table: twoFrames) == nil)
  check(toggle.track == .ready)
  check(toggle.activeTable != nil)
  // The first stabilised frame says so, once
  check(toggle.onStabilizedFrame() == .stabilized)
  check(toggle.onStabilizedFrame() == nil)
}

test("off gives the raw video") {
  let toggle = StabilizationSwitch(enabled: true)
  _ = toggle.onTrack(hasTrack: true, table: twoFrames)
  check(toggle.toggle() == nil, "turned off: no notice")
  check(!toggle.enabled)
  check(toggle.activeTable == nil)
  check(toggle.buttonVisible, "the button stays, dimmed")
  // Back on: the notice tells it at once
  check(toggle.toggle() == .stabilized)
  check(toggle.activeTable != nil)
  check(toggle.onStabilizedFrame() == nil, "told already")
}

test("a file without a track says so only when the user turned it on") {
  // On by default, then the file has no track after all: the button hides, nothing is said
  let quiet = StabilizationSwitch(enabled: true)
  _ = quiet.onTrack(hasTrack: true, table: nil)
  check(quiet.onTrack(hasTrack: false, table: nil) == nil)
  check(quiet.track == .missing)
  check(!quiet.buttonVisible)
  // Off in the settings, turned on in the player while the track is read, and none comes
  let asked = StabilizationSwitch(enabled: false)
  _ = asked.onTrack(hasTrack: true, table: nil)
  check(asked.toggle() == nil, "nothing to say while the track is read")
  check(asked.onTrack(hasTrack: false, table: nil) == .noTrack)
  check(!asked.buttonVisible)
  // Turned on and off again: nothing either
  let changed = StabilizationSwitch(enabled: false)
  _ = changed.onTrack(hasTrack: true, table: nil)
  _ = changed.toggle()
  _ = changed.toggle()
  check(changed.onTrack(hasTrack: false, table: nil) == nil)
}

test("the setting moves the switch until the user presses it") {
  let toggle = StabilizationSwitch(enabled: true)
  toggle.onSetting(false)
  check(!toggle.enabled)
  toggle.onSetting(true)
  check(toggle.enabled)
  // The user turns it off while the table is built: the table, sent with the setting read before, keeps it off
  _ = toggle.toggle()
  toggle.onSetting(true)
  check(!toggle.enabled)
  check(toggle.wasTouched)
}

test("a video the stitch does not draw shows no button and gets no table") {
  // An equirectangular video, or a raw frame the shader modifier draws: the table describes nothing there
  let toggle = StabilizationSwitch(enabled: true)
  _ = toggle.onTrack(hasTrack: true, table: twoFrames)
  check(toggle.buttonVisible)
  toggle.stitched = false
  check(!toggle.buttonVisible, "a button that would do nothing hides")
  check(toggle.activeTable == nil)
  toggle.stitched = true
  check(toggle.buttonVisible)
  check(toggle.activeTable != nil)
}

// MARK: - The inbox

final class Owner {}

test("the inbox keeps the last message of each URL apart") {
  let inbox = StabilizationInbox()
  let a = StabilizationInbox.Message(
    url: "file:///a.insv", enabled: true, hasTrack: true, table: twoFrames, summary: "a")
  let b = StabilizationInbox.Message(url: "file:///b.insv", enabled: true, hasTrack: false, table: nil, summary: nil)
  inbox.post(a)
  // A late message about another video does not take the place of the one of the video that plays
  inbox.post(b)
  check(inbox.latest(for: "file:///a.insv")?.summary == "a")
  check(inbox.latest(for: "file:///b.insv")?.hasTrack == false)
  // The last few URLs only: the oldest goes
  for n in 0..<StabilizationInbox.maxUrls {
    inbox.post(StabilizationInbox.Message(url: "file:///c\(n).insv", enabled: true, hasTrack: false, table: nil,
      summary: nil))
  }
  check(inbox.latest(for: "file:///a.insv") == nil)
  check(inbox.latest(for: "file:///b.insv") == nil)
  check(inbox.latest(for: "file:///c0.insv")?.url == "file:///c0.insv")
  check(inbox.latest(for: nil) == nil)
}

test("the inbox hands the messages to the player that listens, and to it only") {
  let inbox = StabilizationInbox()
  let first = Owner()
  var got: [String?] = []
  inbox.listen(owner: first) { got.append($0.summary) }
  let pending = StabilizationInbox.Message(url: "file:///a.insv", enabled: true, hasTrack: true, table: nil,
    summary: nil)
  inbox.post(pending)
  check(inbox.latest(for: "file:///a.insv")?.table == nil)
  let ready = StabilizationInbox.Message(url: "file:///a.insv", enabled: true, hasTrack: true, table: twoFrames,
    summary: "2 frames")
  inbox.post(ready)
  check(got == [nil, "2 frames"], "\(got)")
  inbox.forget("file:///b.insv")
  check(inbox.latest(for: "file:///a.insv")?.summary == "2 frames")
  inbox.forget("file:///a.insv")
  check(inbox.latest(for: "file:///a.insv") == nil)

  // A player that closes after the next one opened leaves the new one listening
  let next = Owner()
  var nextGot = 0
  inbox.listen(owner: next) { _ in nextGot += 1 }
  inbox.stopListening(owner: first)
  inbox.post(pending)
  check(nextGot == 1)
  inbox.stopListening(owner: next)
  inbox.post(ready)
  check(nextGot == 1)
  check(got.count == 2, "the first player heard nothing more")
}

// MARK: - The uniforms of the shader and of Swift

/// The float4 members of the struct RawStitchUniforms in [source], in order: `float4 name;` in the shader, `var name`
/// of a SIMD4<Float> (or a row of StabilizationRows) in Swift. The arrays of lenses and faces are left out.
func float4Members(_ source: String, swift: Bool) -> [String] {
  guard let start = source.range(of: "struct RawStitchUniforms {"),
    let end = source.range(of: "}", range: start.upperBound..<source.endIndex)
  else {
    return []
  }
  var names: [String] = []
  for line in source[start.upperBound..<end.lowerBound].split(separator: "\n") {
    let words = line.trimmingCharacters(in: .whitespaces).split(separator: " ")
    guard words.count >= 2 else { continue }
    if !swift && words[0] == "float4" {
      names.append(String(words[1].prefix { $0 != ";" }))
    } else if swift && words[0] == "var"
      && (line.contains("SIMD4<Float>") || line.contains("StabilizationRows.identity"))
    {
      names.append(String(words[1]))
    }
  }
  return names
}

test("the stabilisation rows close the uniforms of the shader and of Swift alike") {
  let arguments = CommandLine.arguments
  guard arguments.count >= 3,
    let metal = try? String(contentsOfFile: arguments[1], encoding: .utf8),
    let renderer = try? String(contentsOfFile: arguments[2], encoding: .utf8)
  else {
    check(false, "run.sh passes the paths of RawStitchShaders.metal and RawStitchRenderer.swift")
    return
  }
  let shaderMembers = float4Members(metal, swift: false)
  let swiftMembers = float4Members(renderer, swift: true)
  let tail = ["stabilization0", "stabilization1", "stabilization2"]
  check(Array(shaderMembers.suffix(3)) == tail, "shader: \(shaderMembers)")
  check(Array(swiftMembers.suffix(3)) == tail, "Swift: \(swiftMembers)")
  // The float4 members after the faces, in the same order in both
  check(shaderMembers == swiftMembers, "shader \(shaderMembers), Swift \(swiftMembers)")
  check(renderer.contains("MemoryLayout<RawStitchUniforms>.stride == 784"))
  // Both fragment shaders turn their view direction
  let turned = metal.components(separatedBy: "rawStitchStabilized(rawStitchViewDirection(").count - 1
  check(turned == 2, "fragments turning the view direction: \(turned)")
}

// MARK: - Run

for (name, body) in tests {
  currentTest = name
  let before = failures
  body()
  print("\(failures == before ? "ok  " : "FAIL") \(name)")
}
print("\(tests.count) tests, \(checks) checks, \(failures) failed")
exit(failures == 0 ? 0 : 1)
