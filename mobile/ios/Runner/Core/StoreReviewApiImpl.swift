import StoreKit
import UIKit

/// The review prompt of the App Store, for the invitation to rate the app (lib/domain/models/rate_app.dart): StoreKit
/// decides whether it shows (three times a year at most) and never says what the user did. AppStore.requestReview on
/// iOS 16 and later, SKStoreReviewController before, in the foreground scene. The App Store page is opened from Dart
/// through its address, so openStorePage answers false. Pigeon calls it on the main thread.
class StoreReviewApiImpl: StoreReviewApi {
  func requestReview(completion: @escaping (Result<Bool, Error>) -> Void) {
    guard let scene = activeScene() else {
      completion(.success(false))
      return
    }
    Task { @MainActor in
      if #available(iOS 16.0, *) {
        AppStore.requestReview(in: scene)
      } else {
        SKStoreReviewController.requestReview(in: scene)
      }
    }
    completion(.success(true))
  }

  func openStorePage() throws -> Bool {
    return false
  }

  private func activeScene() -> UIWindowScene? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    return scenes.first(where: { $0.activationState == .foregroundActive })
  }
}
