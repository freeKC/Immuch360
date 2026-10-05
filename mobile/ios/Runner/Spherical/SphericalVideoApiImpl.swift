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
/// The raw projection of [open] describes a raw camera file the player stitches itself (see [RawProjection]): version
/// 1 is the dual fisheye calibration of a frame that holds the two fisheye circles side by side (see
/// [DualFisheyeCalibration]), version 2 a recording whose lenses are in one frame, in two tracks or in two files (see
/// [RawStitchSpec]). A projection the player rejects leaves the video as it is.
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

    // An unreadable or rejected projection leaves the frame as it is, rather than no video at all
    var raw: RawProjection?
    if let rawProjection {
      do {
        raw = try RawProjection.parse(rawProjection)
      } catch {
        print("RawStitch: rawProjection rejected: \(error), the 360° video plays unstitched")
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
      raw: raw,
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
