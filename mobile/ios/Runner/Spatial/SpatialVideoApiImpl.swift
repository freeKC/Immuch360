import AVFoundation
import Metal
import UIKit

/// Opens stereoscopic videos in [SpatialVideoViewController], the experimental Spatial 2.5D player, full screen over
/// the Flutter view. Pigeon calls it on the main thread.
///
/// [events] tells Flutter when the player closes, with the position and the layout, so that the normal player
/// resumes where the Spatial one stopped.
///
/// The fallbackUrl of the request is the server's transcoded stream: the player switches to it when the device
/// cannot decode the original or when the original fails.
class SpatialVideoApiImpl: SpatialVideoApi {
  private let events: SpatialVideoEvents

  init(events: SpatialVideoEvents) {
    self.events = events
  }

  func capabilities() throws -> SpatialCapabilities {
    let hasMetal = MTLCreateSystemDefaultDevice() != nil
    let frontCamera = HeadTracker.frontCameraAvailable
    let permission = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    var reason: String?
    if !hasMetal {
      reason = "Metal is not available"
    } else if !frontCamera {
      reason = "no front camera"
    }
    return SpatialCapabilities(
      supported: hasMetal && frontCamera,
      frontCamera: frontCamera,
      cameraPermissionGranted: permission,
      reason: reason
    )
  }

  func open(request: SpatialOpenRequest) throws {
    guard let videoUrl = URL(string: request.url) else {
      throw PigeonError(code: "INVALID_URL", message: "Cannot read the video URL \(request.url)", details: nil)
    }
    // An unreadable fallback, or the original itself, is no fallback
    var fallback = request.fallbackUrl.flatMap { URL(string: $0) }
    if fallback == videoUrl {
      fallback = nil
    }
    let noViewController = PigeonError(
      code: "NO_VIEW_CONTROLLER",
      message: "No view controller to show the Spatial player",
      details: nil
    )
    guard let presenter = topViewController() else {
      throw noViewController
    }
    // A second tap while the player slides in
    if presenter is SpatialVideoViewController && !presenter.isBeingDismissed {
      return
    }
    // UIKit drops a presentation made during a transition or over another one: the error lets Flutter resume its player
    if presenter.isBeingPresented || presenter.isBeingDismissed || presenter.presentedViewController != nil {
      throw noViewController
    }

    let player = SpatialVideoViewController(url: videoUrl, fallbackUrl: fallback, request: request, events: events)
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
