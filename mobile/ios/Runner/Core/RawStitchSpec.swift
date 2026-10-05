import Foundation
import simd

/// Why a raw recording cannot be stitched: a rawProjection the player rejects, a track it does not find, a frame it
/// cannot draw. The reason goes to the log as it is.
struct RawStitchError: LocalizedError, CustomStringConvertible {
  let reason: String

  var errorDescription: String? { reason }
  var description: String { reason }
}

/// Version 2 of the rawProjection JSON (docs 18-design-projections-and-parsers.md section 3): a raw two lens
/// recording that RawStitchCompositor stitches into equirectangular frames. The decoded inputs are [tracks] (one for
/// a side by side frame, two otherwise, in one file or in two); each fisheye lens names the track that holds it and
/// where its square lies there, a GoPro EAC recording carries its face table. Every number is read as a double (JSON
/// integers included) and checked by [geometry], which gives the values the renderer uses.
struct RawStitchSpec: Decodable {
  enum Kind: String, Decodable {
    case dualFisheye
    case eacGoPro
  }

  enum Model: String, Decodable {
    case mei
    case equidistant
    case kannalaBrandt
  }

  enum Layout: String, Decodable {
    case sideBySide
    case twoTracks
    case twoFiles
  }

  /// A decoded input: [file] 0 is the URL the player was given, 1 the second URL; the track is the one whose tkhd
  /// track_ID is [trackId], else the [videoTrack]th video track of that file
  struct Track: Decodable {
    let file: Double
    let videoTrack: Double
    let trackId: Double?
    let width: Double?
    let height: Double?
    let codec: String?
    let codecs: String?
    let bitDepth: Double?
  }

  /// A fisheye lens in canvas pixels (lens 1's cx includes one canvasSquare) and degrees; [viewToLens] is row major,
  /// from the view direction to the lens frame, levelling included
  struct Lens: Decodable {
    let texture: Double
    let region: [Double]
    let cx: Double
    let cy: Double
    let fx: Double?
    let fy: Double?
    let xi: Double?
    let k1: Double?
    let k2: Double?
    let k3: Double?
    let k4: Double?
    let k5: Double?
    let p1: Double?
    let p2: Double?
    let radius: Double?
    let radiusTheta: Double?
    let yaw: Double?
    let pitch: Double?
    let roll: Double?
    let viewToLens: [Double]
  }

  /// A face of a GoPro EAC recording: its track, its slot there (1 whole, 0 and 2 split) and its axes in the camera
  /// frame
  struct Face: Decodable {
    let texture: Double
    let slot: Double
    let forward: [Double]
    let right: [Double]
    let down: [Double]
  }

  let version: Double
  let kind: Kind
  let layout: Layout
  let camera: String?
  let frameWidth: Double?
  let frameHeight: Double?
  let tracks: [Track]
  let secondUrl: String?
  let secondFallbackUrl: String?
  let trackOrder: [Double]?
  let trackOrderSource: String?
  let calibrationSource: String?
  let gravitySource: String?
  // dualFisheye
  let model: Model?
  let canvasSquare: Double?
  let maxTheta: Double?
  let blendStart: Double?
  let blendEnd: Double?
  let lenses: [Lens]?
  // eacGoPro
  let face: Double?
  let overlap: Double?
  let half: Double?
  let middle: Double?
  let right: Double?
  let viewToCamera: [Double]?
  let faces: [Face]?

  /// Checks the rules of section 3.4 and turns the JSON into what the renderer uses, as floats, once
  func geometry() throws -> RawStitchGeometry {
    guard version == 2 else {
      throw RawStitchError(reason: "rawProjection version \(version) is not 2")
    }
    let expectedTracks = layout == .sideBySide ? 1 : 2
    guard tracks.count == expectedTracks else {
      throw RawStitchError(reason: "\(tracks.count) tracks for the \(layout.rawValue) layout")
    }
    if layout == .twoFiles {
      guard let secondUrl, !secondUrl.isEmpty, URL(string: secondUrl) != nil else {
        throw RawStitchError(reason: "the twoFiles layout has no readable secondUrl")
      }
    }
    var parsedTracks: [RawStitchGeometry.Track] = []
    for (index, track) in tracks.enumerated() {
      guard let file = Self.integer(track.file), file == 0 || file == 1 else {
        throw RawStitchError(reason: "track \(index) names file \(track.file)")
      }
      if file == 1 && layout != .twoFiles {
        throw RawStitchError(reason: "track \(index) is in the second file of a \(layout.rawValue) layout")
      }
      guard let videoTrack = Self.integer(track.videoTrack), videoTrack >= 0 else {
        throw RawStitchError(reason: "track \(index) has video track \(track.videoTrack)")
      }
      var trackId: Int32?
      if let value = track.trackId {
        guard let id = Self.integer(value), id > 0 else {
          throw RawStitchError(reason: "track \(index) has track ID \(value)")
        }
        trackId = Int32(id)
      }
      parsedTracks.append(
        RawStitchGeometry.Track(
          file: file,
          videoTrack: videoTrack,
          trackId: trackId,
          width: track.width.flatMap { Self.integer($0) },
          height: track.height.flatMap { Self.integer($0) }
        ))
    }
    let width = frameWidth.flatMap { Self.integer($0) } ?? 0
    switch kind {
    case .dualFisheye:
      return try fisheyeGeometry(tracks: parsedTracks, frameWidth: width)
    case .eacGoPro:
      return try eacGeometry(tracks: parsedTracks, frameWidth: width)
    }
  }

  private func fisheyeGeometry(tracks parsedTracks: [RawStitchGeometry.Track], frameWidth: Int) throws
    -> RawStitchGeometry
  {
    guard let model else {
      throw RawStitchError(reason: "dualFisheye without a model")
    }
    guard let lenses, lenses.count == 2 else {
      throw RawStitchError(reason: "dualFisheye needs 2 lenses, not \(lenses?.count ?? 0)")
    }
    guard let square = canvasSquare, square.isFinite, square > 0 else {
      throw RawStitchError(reason: "canvasSquare \(canvasSquare ?? 0) is not positive")
    }
    // Insta360 values when Flutter leaves them out; DJI sends its own
    let largest = maxTheta ?? 100
    let start = blendStart ?? 85
    let end = blendEnd ?? 95
    guard largest.isFinite, start.isFinite, end.isFinite, 0 < start, start < end, end <= largest, largest <= 180
    else {
      throw RawStitchError(reason: "blend \(start) to \(end) and maxTheta \(largest) are not in order")
    }
    var parsedLenses: [RawStitchGeometry.Lens] = []
    for (index, lens) in lenses.enumerated() {
      guard let texture = Self.integer(lens.texture), texture >= 0, texture < parsedTracks.count else {
        throw RawStitchError(reason: "lens \(index) names texture \(lens.texture)")
      }
      let region = lens.region
      guard region.count == 4, region.allSatisfy({ $0.isFinite }), region[0] >= 0, region[1] >= 0, region[2] > 0,
        region[3] > 0, region[0] + region[2] <= 1.000001, region[1] + region[3] <= 1.000001
      else {
        throw RawStitchError(reason: "lens \(index) has region \(region)")
      }
      let rows = try Self.rows(lens.viewToLens, name: "lens \(index) viewToLens")
      let determinant = Self.determinant(lens.viewToLens)
      guard abs(determinant - 1) < 1e-3 else {
        throw RawStitchError(reason: "lens \(index) viewToLens has determinant \(determinant), not a rotation")
      }
      guard lens.cx.isFinite, lens.cy.isFinite else {
        throw RawStitchError(reason: "lens \(index) has no finite principal point")
      }
      let focalX: Double
      let focalY: Double
      switch model {
      case .mei:
        guard let fx = lens.fx, let fy = lens.fy, let xi = lens.xi, fx.isFinite, fy.isFinite, xi.isFinite, fx > 0,
          fy > 0, xi >= 0
        else {
          throw RawStitchError(reason: "Mei lens \(index) lacks fx, fy or xi")
        }
        focalX = fx
        focalY = fy
      case .kannalaBrandt:
        guard let fx = lens.fx, let fy = lens.fy, fx.isFinite, fy.isFinite, fx > 0, fy > 0 else {
          throw RawStitchError(reason: "Kannala-Brandt lens \(index) lacks fx or fy")
        }
        focalX = fx
        focalY = fy
      case .equidistant:
        let angle = lens.radiusTheta ?? 100
        guard let radius = lens.radius, radius.isFinite, radius > 0, angle.isFinite, angle > 0 else {
          throw RawStitchError(reason: "equidistant lens \(index) lacks its radius")
        }
        // The radius marks radiusTheta degrees off axis: pixels per radian
        focalX = radius / (angle * .pi / 180)
        focalY = focalX
      }
      let terms = [lens.k1, lens.k2, lens.k3, lens.k4, lens.k5, lens.p1, lens.p2, lens.xi].map { $0 ?? 0 }
      guard terms.allSatisfy({ $0.isFinite }) else {
        throw RawStitchError(reason: "lens \(index) has a coefficient that is not finite")
      }
      // Lens i's square starts i squares to the right on the canvas: its fraction is (x - i S) / S, y / S
      let offset = Double(index) * square
      parsedLenses.append(
        RawStitchGeometry.Lens(
          rows: rows,
          texture: texture,
          region: SIMD4<Float>(Float(region[0]), Float(region[1]), Float(region[2]), Float(region[3])),
          projection: SIMD4<Float>(
            Float(focalX / square), Float(focalY / square), Float((lens.cx - offset) / square), Float(lens.cy / square)
          ),
          radial: SIMD4<Float>(Float(terms[0]), Float(terms[1]), Float(terms[2]), Float(terms[3])),
          extra: SIMD4<Float>(Float(terms[4]), Float(terms[7]), Float(terms[5]), Float(terms[6]))
        ))
    }
    let projection: RawStitchGeometry.Projection
    switch model {
    case .mei:
      projection = .mei
    case .equidistant:
      projection = .equidistant
    case .kannalaBrandt:
      projection = .kannalaBrandt
    }
    let radians = Float.pi / 180
    return RawStitchGeometry(
      layout: layout,
      projection: projection,
      tracks: parsedTracks,
      lenses: parsedLenses,
      eac: nil,
      angles: SIMD4<Float>(Float(largest) * radians, Float(start) * radians, Float(end) * radians, 0),
      frameWidth: frameWidth
    )
  }

  private func eacGeometry(tracks parsedTracks: [RawStitchGeometry.Track], frameWidth: Int) throws
    -> RawStitchGeometry
  {
    guard layout == .twoTracks else {
      throw RawStitchError(reason: "eacGoPro needs the twoTracks layout, not \(layout.rawValue)")
    }
    guard let faceSize = face.flatMap({ Self.integer($0) }), let halfWidth = half.flatMap({ Self.integer($0) }),
      let middleStart = middle.flatMap({ Self.integer($0) }), let rightStart = right.flatMap({ Self.integer($0) }),
      let overlapWidth = overlap.flatMap({ Self.integer($0) })
    else {
      throw RawStitchError(reason: "eacGoPro lacks face, overlap, half, middle or right")
    }
    guard faceSize > 0, overlapWidth >= 0, middleStart == 2 * halfWidth, rightStart == middleStart + faceSize else {
      throw RawStitchError(
        reason: "EAC geometry face \(faceSize), half \(halfWidth), middle \(middleStart), right \(rightStart)")
    }
    let trackWidth = rightStart + 2 * halfWidth
    for (index, track) in parsedTracks.enumerated() {
      guard track.width == trackWidth, track.height == faceSize else {
        throw RawStitchError(
          reason: "EAC track \(index) is \(track.width ?? 0)x\(track.height ?? 0), not \(trackWidth)x\(faceSize)")
      }
    }
    guard let viewToCamera else {
      throw RawStitchError(reason: "eacGoPro lacks viewToCamera")
    }
    let cameraRows = try Self.rows(viewToCamera, name: "viewToCamera")
    // A reflection is expected: the face table's camera frame is left handed
    let determinant = Self.determinant(viewToCamera)
    guard abs(abs(determinant) - 1) < 1e-3 else {
      throw RawStitchError(reason: "viewToCamera has determinant \(determinant)")
    }
    guard let faces, faces.count == 6 else {
      throw RawStitchError(reason: "eacGoPro needs 6 faces, not \(faces?.count ?? 0)")
    }
    var parsedFaces: [RawStitchGeometry.Face] = []
    var slots = Set<Int>()
    for (index, face) in faces.enumerated() {
      guard let texture = Self.integer(face.texture), texture >= 0, texture < parsedTracks.count,
        let slot = Self.integer(face.slot), slot >= 0, slot <= 2
      else {
        throw RawStitchError(reason: "face \(index) has texture \(face.texture) and slot \(face.slot)")
      }
      guard let forward = Self.vector(face.forward), let rightAxis = Self.vector(face.right),
        let downAxis = Self.vector(face.down)
      else {
        throw RawStitchError(reason: "face \(index) lacks one of its axes")
      }
      slots.insert(texture * 3 + slot)
      parsedFaces.append(
        RawStitchGeometry.Face(
          forward: SIMD4<Float>(forward.x, forward.y, forward.z, Float(texture)),
          right: SIMD4<Float>(rightAxis.x, rightAxis.y, rightAxis.z, Float(slot)),
          down: SIMD4<Float>(downAxis.x, downAxis.y, downAxis.z, 0)
        ))
    }
    guard slots.count == 6 else {
      throw RawStitchError(reason: "the faces do not fill the three slots of both tracks")
    }
    return RawStitchGeometry(
      layout: layout,
      projection: .eac,
      tracks: parsedTracks,
      lenses: [],
      eac: RawStitchGeometry.Eac(
        face: Float(faceSize),
        half: Float(halfWidth),
        overlap: Float(overlapWidth),
        middle: Float(middleStart),
        right: Float(rightStart),
        trackWidth: Float(trackWidth),
        trackHeight: Float(faceSize),
        cameraRows: cameraRows,
        faces: parsedFaces
      ),
      angles: SIMD4<Float>(repeating: 0),
      frameWidth: frameWidth
    )
  }

  /// [value] when it is a whole number a track ID or a pixel count can be, else nil
  private static func integer(_ value: Double) -> Int? {
    guard value.isFinite, value == value.rounded(), abs(value) <= Double(Int32.max) else { return nil }
    return Int(value)
  }

  /// Three finite numbers as a vector, else nil
  private static func vector(_ values: [Double]) -> SIMD3<Float>? {
    guard values.count == 3, values.allSatisfy({ $0.isFinite }) else { return nil }
    return SIMD3<Float>(Float(values[0]), Float(values[1]), Float(values[2]))
  }

  /// The three rows of a row major 3x3 matrix, w zero: the shaders take dot products with them, so that no matrix
  /// layout convention stands between Swift and Metal
  private static func rows(_ values: [Double], name: String) throws -> [SIMD4<Float>] {
    guard values.count == 9, values.allSatisfy({ $0.isFinite }) else {
      throw RawStitchError(reason: "\(name) is not 9 finite numbers")
    }
    return (0..<3).map { row in
      SIMD4<Float>(Float(values[3 * row]), Float(values[3 * row + 1]), Float(values[3 * row + 2]), 0)
    }
  }

  /// The determinant of a row major 3x3 matrix of 9 numbers
  private static func determinant(_ m: [Double]) -> Double {
    m[0] * (m[4] * m[8] - m[5] * m[7]) - m[1] * (m[3] * m[8] - m[5] * m[6]) + m[2] * (m[3] * m[7] - m[4] * m[6])
  }
}

/// A checked rawProjection v2, as RawStitchRenderer draws it: floats, angles in radians, lens values as fractions of
/// the lens square (see RawStitchShaders.metal)
struct RawStitchGeometry {
  /// The raw value is the one the shaders read
  enum Projection: Int {
    case mei = 0
    case equidistant = 1
    case kannalaBrandt = 2
    case eac = 3
  }

  /// A decoded input: file 0 or 1, the track ID to look for, else the index among the video tracks of the file
  struct Track {
    let file: Int
    let videoTrack: Int
    let trackId: Int32?
    let width: Int?
    let height: Int?
  }

  struct Lens {
    /// Rows of viewToLens, w zero
    let rows: [SIMD4<Float>]
    /// Index in [tracks] of the texture that holds the lens
    let texture: Int
    /// The lens square in its texture: origin xy, size zw, fractions from the top left corner
    let region: SIMD4<Float>
    /// fx / S, fy / S, (cx - i S) / S, cy / S: from the lens point to the fraction of the lens square
    let projection: SIMD4<Float>
    /// k1, k2, k3, k4
    let radial: SIMD4<Float>
    /// k5, xi, p1, p2
    let extra: SIMD4<Float>
  }

  struct Face {
    /// xyz: the direction the face looks at in the camera frame, w: its texture
    let forward: SIMD4<Float>
    /// xyz: the right of the face, w: its slot
    let right: SIMD4<Float>
    /// xyz: the bottom of the face
    let down: SIMD4<Float>
  }

  /// GoPro EAC: the columns of the declared track size and the face table
  struct Eac {
    let face: Float
    let half: Float
    let overlap: Float
    let middle: Float
    let right: Float
    let trackWidth: Float
    let trackHeight: Float
    /// Rows of viewToCamera, w zero
    let cameraRows: [SIMD4<Float>]
    let faces: [Face]
  }

  let layout: RawStitchSpec.Layout
  let projection: Projection
  /// One for a side by side frame, two otherwise
  let tracks: [Track]
  /// Lens 0 then lens 1; none for EAC
  let lenses: [Lens]
  let eac: Eac?
  /// maxTheta, blendStart, blendEnd in radians, 0
  let angles: SIMD4<Float>
  /// Width of the stitched frame worth drawing, 0 when Flutter did not tell
  let frameWidth: Int
}
