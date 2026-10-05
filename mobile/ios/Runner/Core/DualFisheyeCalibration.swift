import Foundation
import simd

/// The calibration of a raw dual fisheye camera file (Insta360 .insv), as Flutter hands it to the native players in
/// the rawProjection field of their open call (see docs 16-dual-fisheye-spec.md, section 5). The frame holds the two
/// fisheye circles side by side, lens 0 in the left square and lens 1 in the right one. The lens values are pixels of
/// a calibration canvas made of one square of [canvasSquare] pixels per lens, side by side (lens 1's centre already
/// includes the offset of one square), and angles in degrees.
///
/// A direction of the view (x right, y down, z ahead, as in an equirectangular frame) finds its point in the frame
/// this way: [levelingMatrix] (G) takes it to the body frame of the camera (x right, y down, z along lens 0) with the
/// horizon level, [lensRotation] (R_i) to the frame of lens i, where the Mei or the equidistant projection gives
/// canvas pixels, which [textureProjection] turns into texture coordinates of the whole frame.
struct DualFisheyeCalibration: Decodable {
  enum Model: String, Decodable {
    case mei
    case equidistant
  }

  /// One lens, in canvas pixels and degrees. A Mei lens (Insta360 V3 strings) has [xi], [fx] and [fy]; an equidistant
  /// one (V1 strings) has [radius], its image circle at about 100 degrees off axis, instead.
  struct Lens: Decodable {
    let cx: Float
    let cy: Float
    let yaw: Float
    let pitch: Float
    let roll: Float
    let xi: Float?
    let fx: Float?
    let fy: Float?
    let k1: Float
    let k2: Float
    let k3: Float
    let p1: Float
    let p2: Float
    let radius: Float?

    private enum CodingKeys: String, CodingKey {
      case cx, cy, yaw, pitch, roll, xi, fx, fy, k1, k2, k3, p1, p2, radius
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      cx = try container.number(.cx)
      cy = try container.number(.cy)
      // Flutter writes every angle and coefficient; a missing one reads as zero, as on the Dart side
      yaw = try container.number(.yaw, default: 0)
      pitch = try container.number(.pitch, default: 0)
      roll = try container.number(.roll, default: 0)
      xi = try container.optionalNumber(.xi)
      fx = try container.optionalNumber(.fx)
      fy = try container.optionalNumber(.fy)
      k1 = try container.number(.k1, default: 0)
      k2 = try container.number(.k2, default: 0)
      k3 = try container.number(.k3, default: 0)
      p1 = try container.number(.p1, default: 0)
      p2 = try container.number(.p2, default: 0)
      radius = try container.optionalNumber(.radius)
    }
  }

  /// Why a calibration cannot be used: the frame then plays as it is
  struct InvalidCalibration: Error, CustomStringConvertible {
    let description: String
  }

  /// The angle off axis the radius of an equidistant lens marks: about 100 degrees on the X3, whose V1 radius sits
  /// where the Mei model of the same lens puts 100 degrees
  static let equidistantRadiusAngle: Float = 100 * .pi / 180

  let model: Model
  /// The frame the calibration was written for, in pixels: two squares side by side. Only its proportions matter
  /// here, so that a transcoded stream of another size maps the same.
  let frameWidth: Float
  let frameHeight: Float
  let canvasSquare: Float
  /// The direction of gravity in the body frame, of unit length
  let downBody: SIMD3<Float>
  /// Lens 0 (left square), then lens 1 (right square)
  let lenses: [Lens]

  private enum CodingKeys: String, CodingKey {
    case kind, model, frameWidth, frameHeight, canvasSquare, downBody, lenses
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try container.decode(String.self, forKey: .kind)
    guard kind == "dualFisheye" else {
      throw InvalidCalibration(description: "unknown projection kind \(kind)")
    }
    model = try container.decode(Model.self, forKey: .model)
    frameWidth = try container.number(.frameWidth)
    frameHeight = try container.number(.frameHeight)
    canvasSquare = try container.number(.canvasSquare)
    lenses = try container.decode([Lens].self, forKey: .lenses)
    guard frameWidth > 0, frameHeight > 0, canvasSquare > 0 else {
      throw InvalidCalibration(description: "empty frame \(frameWidth)x\(frameHeight) or canvas \(canvasSquare)")
    }
    guard lenses.count == 2 else {
      throw InvalidCalibration(description: "\(lenses.count) lenses instead of 2")
    }
    for (index, lens) in lenses.enumerated() {
      switch model {
      case .mei:
        guard let xi = lens.xi, let fx = lens.fx, let fy = lens.fy, xi.isFinite, fx > 0, fy > 0 else {
          throw InvalidCalibration(description: "lens \(index) lacks its Mei xi, fx or fy")
        }
      case .equidistant:
        guard let radius = lens.radius, radius > 0 else {
          throw InvalidCalibration(description: "lens \(index) lacks its radius")
        }
      }
    }
    // Without a usable gravity, the camera stands upright: gravity along body +x
    let down = try container.decodeIfPresent([Double].self, forKey: .downBody) ?? []
    let vector = down.count == 3 ? SIMD3<Float>(Float(down[0]), Float(down[1]), Float(down[2])) : SIMD3<Float>(1, 0, 0)
    let length = simd_length(vector)
    downBody = length.isFinite && length > 1e-6 ? vector / length : SIMD3<Float>(1, 0, 0)
  }

  /// Reads the JSON of the rawProjection field; throws when it is not a usable dual fisheye calibration
  static func parse(_ json: String) throws -> DualFisheyeCalibration {
    try JSONDecoder().decode(DualFisheyeCalibration.self, from: Data(json.utf8))
  }

  /// Frame pixels per canvas pixel: the frame shows the whole calibration square of each lens, at its own resolution
  var frameScale: Float { frameHeight / canvasSquare }

  /// The width of one lens square in texture coordinates of the frame: one half of a 2:1 frame
  var squareWidth: Float { frameHeight / frameWidth }

  /// G: from a direction of the view (x right, y down, z ahead) to the body frame. The view looks ahead along lens 1,
  /// where Insta360 Studio centres its exports, with the horizon level. Its columns are the body directions of the
  /// right of the view, of gravity and of the front of the view.
  var levelingMatrix: simd_float3x3 {
    Self.levelingMatrix(downBody: downBody)
  }

  /// G for the gravity [downBody] (unit length, body frame), see the instance member
  static func levelingMatrix(downBody down: SIMD3<Float>) -> simd_float3x3 {
    // Lens 1 straight up or down has no level direction: body x is the fallback, the same one as the Dart and the
    // Kotlin side, so the picture opens on the same heading on every platform
    let front = levelled(SIMD3<Float>(0, 0, -1), down: down) ?? levelled(SIMD3<Float>(1, 0, 0), down: down)
      ?? SIMD3<Float>(0, 0, -1)
    let right = simd_cross(down, front)
    return simd_float3x3(columns: (right, down, front))
  }

  /// [hint] without its part along [down], unit length, or nil when it runs along [down]
  private static func levelled(_ hint: SIMD3<Float>, down: SIMD3<Float>) -> SIMD3<Float>? {
    let v = hint - simd_dot(hint, down) * down
    let length = simd_length(v)
    return length < 1e-6 ? nil : v / length
  }

  /// R_i: from the body frame to the frame of lens [index] (x and y along the rows and the columns of its circle, z
  /// along its axis), in the lens pose convention GyroView measured against Insta360 Studio:
  /// Rz(mirrored roll) * Rx(180 degrees for lens 1) * Rx(pitch) * Ry(yaw). The roll is mirrored about the nearest
  /// quarter turn, which is how the sensors sit sideways in the body.
  func lensRotation(_ index: Int) -> simd_float3x3 {
    let lens = lenses[index]
    return Self.lensRotation(yaw: lens.yaw, pitch: lens.pitch, roll: lens.roll, index: index)
  }

  /// R_i for the pose of lens [index] in degrees, see the instance member
  static func lensRotation(yaw: Float, pitch: Float, roll: Float, index: Int) -> simd_float3x3 {
    let mirroredRoll = 2 * (roll / 90).rounded() * 90 - roll
    return rotationZ(degrees: mirroredRoll) * rotationX(degrees: 180 * Float(index))
      * rotationX(degrees: pitch) * rotationY(degrees: yaw)
  }

  /// Puts the projected point of lens [index] in the frame: (fx, fy, cx, cy) such that the texture coordinates are
  /// (fx * mx + cx, fy * my + cy), where (mx, my) is the distorted Mei point, or the unit direction off axis times the
  /// angle off axis (in radians) for an equidistant lens. Texture coordinates run from the top left corner of the
  /// frame over its whole width and height. Canvas pixels are pixel centres, as in the stitch prototype: half a frame
  /// pixel more.
  func textureProjection(_ index: Int) -> SIMD4<Float> {
    let lens = lenses[index]
    let focalX: Float
    let focalY: Float
    switch model {
    case .mei:
      focalX = lens.fx ?? 0
      focalY = lens.fy ?? 0
    case .equidistant:
      focalX = (lens.radius ?? 0) / Self.equidistantRadiusAngle
      focalY = focalX
    }
    let scale = frameScale
    return SIMD4<Float>(
      focalX * scale / frameWidth,
      focalY * scale / frameHeight,
      (lens.cx * scale + 0.5) / frameWidth,
      (lens.cy * scale + 0.5) / frameHeight
    )
  }

  private static func rotationX(degrees: Float) -> simd_float3x3 {
    let angle = degrees * .pi / 180
    let c = cos(angle)
    let s = sin(angle)
    return simd_float3x3(rows: [
      SIMD3<Float>(1, 0, 0),
      SIMD3<Float>(0, c, -s),
      SIMD3<Float>(0, s, c),
    ])
  }

  private static func rotationY(degrees: Float) -> simd_float3x3 {
    let angle = degrees * .pi / 180
    let c = cos(angle)
    let s = sin(angle)
    return simd_float3x3(rows: [
      SIMD3<Float>(c, 0, s),
      SIMD3<Float>(0, 1, 0),
      SIMD3<Float>(-s, 0, c),
    ])
  }

  private static func rotationZ(degrees: Float) -> simd_float3x3 {
    let angle = degrees * .pi / 180
    let c = cos(angle)
    let s = sin(angle)
    return simd_float3x3(rows: [
      SIMD3<Float>(c, -s, 0),
      SIMD3<Float>(s, c, 0),
      SIMD3<Float>(0, 0, 1),
    ])
  }
}

private extension KeyedDecodingContainer {
  /// A JSON number, read as a double (the widest JSONDecoder reads without loss) and kept as a float, finite
  func number(_ key: Key, default fallback: Float? = nil) throws -> Float {
    if let fallback, !contains(key) {
      return fallback
    }
    let decoded = try decode(Double.self, forKey: key)
    let value = Float(decoded)
    guard value.isFinite else {
      throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "not a finite number")
    }
    return value
  }

  func optionalNumber(_ key: Key) throws -> Float? {
    guard let value = try decodeIfPresent(Double.self, forKey: key) else { return nil }
    let number = Float(value)
    return number.isFinite ? number : nil
  }
}
