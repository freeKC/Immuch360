import UIKit

/// Opens 360° videos in [SphericalVideoViewController], full screen over the Flutter view. Pigeon calls it on the
/// main thread.
///
/// The full screen presentation hides the Flutter view, which sends the app lifecycle to paused, and closing the
/// player brings it back to resumed: that is what lets the asset viewer restart its own player, as on Android.
class SphericalVideoApiImpl: SphericalVideoApi {
  func open(url: String, headers: [String: String], title: String, closeLabel: String?, errorMessage: String?) throws {
    guard let videoUrl = URL(string: url) else {
      throw PigeonError(code: "INVALID_URL", message: "Cannot read the video URL \(url)", details: nil)
    }
    guard let presenter = topViewController() else {
      throw PigeonError(code: "NO_VIEW_CONTROLLER", message: "No view controller to show the 360° player", details: nil)
    }
    // A second tap while the player slides in
    if presenter is SphericalVideoViewController {
      return
    }

    let player = SphericalVideoViewController(
      url: videoUrl,
      headers: headers,
      title: title,
      closeLabel: closeLabel,
      errorMessage: errorMessage
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
