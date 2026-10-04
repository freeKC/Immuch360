import UIKit

/// Opens 360° videos in [SphericalVideoViewController], full screen over the Flutter view. Pigeon calls it on the
/// main thread.
///
/// The full screen presentation hides the Flutter view, which sends the app lifecycle to paused, and closing the
/// player brings it back to resumed: that is what lets the asset viewer restart its own player, as on Android.
///
/// [events] tells Flutter when the player closes, with the stereo layout and the coverage it showed last, so that the
/// corrections of the user can be remembered for the asset.
///
/// The fallback URL of [open] is the server's transcoded stream: the player switches to it when the device cannot
/// decode the original or when the original fails.
///
/// The raw projection of [open] is the JSON of a dual fisheye calibration (see [DualFisheyeCalibration]) when the
/// frame holds the two fisheye circles of a raw camera file: the player stitches them on the sphere itself.
class SphericalVideoApiImpl: SphericalVideoApi {
  private let events: SphericalVideoEvents

  init(events: SphericalVideoEvents) {
    self.events = events
  }

  func open(
    url: String,
    headers: [String: String],
    title: String,
    closeLabel: String?,
    errorMessage: String?,
    stereoLayout: StereoLayout,
    stereoLabels: [String: String],
    coverage: SphereCoverage,
    fallbackUrl: String?,
    rawProjection: String?
  ) throws {
    guard let videoUrl = URL(string: url) else {
      throw PigeonError(code: "INVALID_URL", message: "Cannot read the video URL \(url)", details: nil)
    }
    // An unreadable fallback, or the original itself, is no fallback
    var fallback = fallbackUrl.flatMap { URL(string: $0) }
    if fallback == videoUrl {
      fallback = nil
    }
    let noViewController = PigeonError(
      code: "NO_VIEW_CONTROLLER",
      message: "No view controller to show the 360° player",
      details: nil
    )
    guard let presenter = topViewController() else {
      throw noViewController
    }
    // A second tap while the player slides in
    if presenter is SphericalVideoViewController && !presenter.isBeingDismissed {
      return
    }
    // UIKit drops a presentation made during a transition or over another one: the error lets Flutter resume its player
    if presenter.isBeingPresented || presenter.isBeingDismissed || presenter.presentedViewController != nil {
      throw noViewController
    }

    // An unreadable calibration leaves the frame as it is, the two circles side by side, rather than no video at all
    var calibration: DualFisheyeCalibration?
    if let rawProjection {
      do {
        calibration = try DualFisheyeCalibration.parse(rawProjection)
      } catch {
        print("Cannot read the dual fisheye calibration, the 360° video plays unstitched: \(error)")
      }
    }

    let player = SphericalVideoViewController(
      url: videoUrl,
      fallbackUrl: fallback,
      headers: headers,
      title: title,
      closeLabel: closeLabel,
      errorMessage: errorMessage,
      stereoLayout: stereoLayout,
      stereoLabels: stereoLabels,
      coverage: coverage,
      dualFisheye: calibration,
      events: events
    )
    player.modalPresentationStyle = .fullScreen
    player.modalTransitionStyle = .crossDissolve
    presenter.present(player, animated: true)
  }

  private func topViewController() -> UIViewController? {
    let windows = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }
    let window = windows.first(where: { $0.isKeyWindow }) ?? windows.first
    var top = window?.rootViewController
    while let presented = top?.presentedViewController {
      top = presented
    }
    return top
  }
}
