import AVFoundation
import UIKit

/// The scanner of "Connect a TV or computer" (sign in with your phone): [QrScanViewController] full screen over the
/// Flutter view. Pigeon calls it on the main thread. The camera permission is asked here first, so that a refusal
/// comes back to Flutter as such. What the code says goes to Flutter only: never to the log.
class QrScanApiImpl: QrScanApi {
  private var pending: ((Result<QrScanResult, Error>) -> Void)?

  func scan(prompt: String, cancelLabel: String, completion: @escaping (Result<QrScanResult, Error>) -> Void) {
    if pending != nil {
      completion(.success(QrScanResult(status: .failed, text: nil)))
      return
    }
    guard AVCaptureDevice.default(for: .video) != nil else {
      completion(.success(QrScanResult(status: .noCamera, text: nil)))
      return
    }
    pending = completion
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      present(prompt: prompt, cancelLabel: cancelLabel)
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
        DispatchQueue.main.async {
          guard let self = self else { return }
          if granted {
            self.present(prompt: prompt, cancelLabel: cancelLabel)
          } else {
            self.finish(QrScanResult(status: .permissionDenied, text: nil))
          }
        }
      }
    default:
      finish(QrScanResult(status: .permissionDenied, text: nil))
    }
  }

  private func present(prompt: String, cancelLabel: String) {
    guard let presenter = topViewController(),
      !presenter.isBeingPresented,
      !presenter.isBeingDismissed,
      presenter.presentedViewController == nil
    else {
      finish(QrScanResult(status: .failed, text: nil))
      return
    }
    let scanner = QrScanViewController(prompt: prompt, cancelLabel: cancelLabel) { [weak self] text in
      if let text = text {
        self?.finish(QrScanResult(status: .scanned, text: text))
      } else {
        self?.finish(QrScanResult(status: .cancelled, text: nil))
      }
    }
    scanner.modalPresentationStyle = .fullScreen
    presenter.present(scanner, animated: true)
  }

  private func finish(_ result: QrScanResult) {
    guard let completion = pending else { return }
    pending = nil
    completion(.success(result))
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
