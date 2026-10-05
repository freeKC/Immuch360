import Foundation

/// What the rawProjection JSON of the 360 player asks for (docs 18-design-projections-and-parsers.md section 3.6)
enum RawProjection {
  /// v1 (build 16): one frame with both fisheye circles side by side, stitched per screen pixel by the shader modifier
  /// of SphericalVideoViewController
  case sideBySide(DualFisheyeCalibration)
  /// v2: stitched into equirectangular frames by RawStitchCompositor, whatever its layout
  case stitched(RawStitchSpec, RawStitchGeometry)

  /// Reads [json]: no version (or version 1) is v1, version 2 is checked by RawStitchSpec.geometry. Throws for any
  /// other version and for a JSON that does not check: the player then plays the video as it is.
  static func parse(_ json: String) throws -> RawProjection {
    // A double, so that "version": 2.0 reads too
    struct Header: Decodable {
      let version: Double?
    }
    let data = Data(json.utf8)
    let version = try JSONDecoder().decode(Header.self, from: data).version ?? 1
    if version <= 1 {
      return .sideBySide(try DualFisheyeCalibration.parse(json))
    }
    guard version == 2 else {
      throw RawStitchError(reason: "rawProjection version \(version) is unknown")
    }
    let spec = try JSONDecoder().decode(RawStitchSpec.self, from: data)
    return .stitched(spec, try spec.geometry())
  }
}
