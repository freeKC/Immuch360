import Foundation
import simd

/// How the screen content is turned against the portrait of the phone, for the gyroscope: the interface orientation of
/// UIKit, without UIKit, so that the tests compile on macOS (SwiftTests/run.sh). The top of the phone on the left is
/// UIInterfaceOrientation.landscapeRight (the home button on the right), on the right .landscapeLeft.
enum LookScreen {
  case portrait
  case portraitUpsideDown
  case topOnLeft
  case topOnRight
}

/// The pure part of the view of SphericalVideoViewController, unit tested (SwiftTests/main.swift): the controls of the
/// 360° photo viewer of Flutter (panorama_viewer.widget.dart) in the 360° video player (issue 20), as on Android
/// (SphereLookMath.kt).
///
/// The view is a yaw and a pitch, in radians: the yaw around the vertical axis, growing to the left (the opposite of the
/// photo viewer's longitude), the pitch growing upwards, clamped at the poles, so that a drag reaches straight up and
/// straight down and the view never flips over; no roll, so the horizon stays level. The gyroscope adds its turns to
/// the same two angles, as the photo viewer does (applyGyroRotation in Dart), rather than replacing the view with the
/// attitude of the phone: off, nothing of the motion of the phone reaches the view.
enum SphereLookMath {
  /// The field of view across the longer side of the screen the player opens with, and goes back to with a double tap
  /// once zoomed in, in degrees: the photo viewer's
  static let defaultFieldOfView: Float = 90
  /// The limits of the pinch, the photo viewer's
  static let minFieldOfView: Float = 15
  static let maxFieldOfView: Float = 115
  /// Where a double tap zooms in to, the photo viewer's
  static let doubleTapFieldOfView: Float = 45
  /// The drag speed at the default field of view, the player's before issue 20; slower when zoomed in
  static let radiansPerPoint: Float = 0.12 * Float.pi / 180
  /// Slower rotations of the gyroscope, in rad/s, are sensor noise: the photo viewer's threshold
  static let gyroNoiseThreshold: Float = 0.005
  /// The duration of the double tap zoom, the photo viewer's
  static let zoomAnimationDuration: TimeInterval = 0.25

  /// The field of view of a pinch, from [start] when the fingers went down and the [scale] they spread by since
  static func pinch(start: Float, scale: Float) -> Float {
    guard scale > 0, scale.isFinite else { return clampFieldOfView(start) }
    return clampFieldOfView(start / scale)
  }

  /// The field of view a double tap animates to: zoomed in, or back to the default once zoomed in
  static func doubleTap(_ fieldOfView: Float) -> Float {
    fieldOfView > doubleTapFieldOfView + 1 ? doubleTapFieldOfView : defaultFieldOfView
  }

  static func clampFieldOfView(_ fieldOfView: Float) -> Float {
    min(max(fieldOfView, minFieldOfView), maxFieldOfView)
  }

  /// The vertical field of view, in degrees, of a screen of [width] by [height] showing [fieldOfView] across its
  /// longer side, as the camera of the player does (its projection direction follows the longer side)
  static func verticalFieldOfView(_ fieldOfView: Float, width: Float, height: Float) -> Float {
    guard width > 0, height > 0, width > height else { return fieldOfView }
    let half = tan(fieldOfView / 2 * Float.pi / 180) * height / width
    return 2 * atan(half) * 180 / Float.pi
  }

  /// How far the pitch goes, in radians. A full sphere: straight up and straight down, as in the photo viewer. A half
  /// sphere (VR180): only until the edge of the screen reaches the zenith or the nadir, [verticalFieldOfView] being the
  /// vertical field of view in degrees, so that a drag shows no more of the empty back half than at the 45 degrees of
  /// the default view in portrait
  static func maxPitch(halfSphere: Bool, verticalFieldOfView: Float) -> Float {
    let degrees: Float = halfSphere ? min(max(90 - verticalFieldOfView / 2, 0), 90) : 90
    return degrees * Float.pi / 180
  }

  /// A drag of [dx] and [dy] points (y down): the picture follows the finger, a drag to the left turns the view to the
  /// right, a drag down looks up; zoomed in, slower
  static func drag(
    yaw: Float, pitch: Float, dx: Float, dy: Float, fieldOfView: Float, maxPitch: Float
  ) -> (yaw: Float, pitch: Float) {
    let scale = radiansPerPoint * fieldOfView / defaultFieldOfView
    return (yaw: wrap(yaw + dx * scale), pitch: min(max(pitch + dy * scale, -maxPitch), maxPitch))
  }

  /// Turns the view by the rotation the gyroscope measured over [dt] seconds, as the photo viewer's applyGyroRotation:
  /// rates in rad/s around the axes of the phone in portrait (x to its right edge, y to its top, z out of the screen,
  /// positive counterclockwise seen from the tip of the axis), as CMDeviceMotion.rotationRate gives them. Turning the
  /// phone to the right looks further right, tilting its top towards the user looks up; the roll is ignored.
  static func gyro(
    yaw: Float, pitch: Float, rateX: Float, rateY: Float, rateZ: Float, dt: Float, screen: LookScreen, maxPitch: Float
  ) -> (yaw: Float, pitch: Float) {
    // Rotation around the axes of the screen as the user sees it
    let axes: (right: Float, up: Float)
    switch screen {
    case .portrait:
      axes = (right: rateX, up: rateY)
    case .topOnLeft:
      axes = (right: -rateY, up: rateX)
    case .portraitUpsideDown:
      axes = (right: -rateX, up: -rateY)
    case .topOnRight:
      axes = (right: rateY, up: -rateX)
    }
    func angle(_ rate: Float) -> Float { abs(rate) < gyroNoiseThreshold ? 0 : rate * dt }
    // The photo viewer's longitude goes down by the turn around the screen's up axis: the yaw, its opposite, goes up
    return (
      yaw: wrap(yaw + angle(axes.up)),
      pitch: min(max(pitch + angle(axes.right), -maxPitch), maxPitch)
    )
  }

  /// The time between two samples of the gyroscope, in seconds: the first one, or timestamps that make no sense, count
  /// as one sample at 50 Hz, as in the photo viewer
  static func gyroStep(previous: TimeInterval?, current: TimeInterval) -> Float {
    guard let previous else { return 1 / 50 }
    let elapsed = current - previous
    return elapsed > 0 && elapsed <= 0.2 ? Float(elapsed) : 1 / 50
  }

  /// The orientation of the camera for [yaw] and [pitch]: always upright, no roll
  static func orientation(yaw: Float, pitch: Float) -> simd_quatf {
    simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0)) * simd_quatf(angle: pitch, axis: SIMD3<Float>(1, 0, 0))
  }

  /// [yaw] within one turn either way of zero, so that hours of turning keep its precision
  static func wrap(_ yaw: Float) -> Float {
    guard abs(yaw) > Float.pi * 4 else { return yaw }
    return remainder(yaw, 2 * Float.pi)
  }
}
