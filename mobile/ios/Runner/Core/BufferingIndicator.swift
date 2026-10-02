import AVFoundation
import UIKit

/// "Buffering 42%" over an AVPlayer while its item loads: before the item is ready, and whenever it is not likely to
/// keep up (a stall, a seek), as long as the player does not play. The percentage is the media loaded ahead of the
/// position (`loadedTimeRanges`) over `targetSeconds`; it updates four times a second.
///
/// [labels] are the translated labels from Flutter: "buffering", with "{percent}" for the percentage; English is the
/// fallback. The owner adds `view` to its view, places it, calls `start` once the player shows and `stop` when it
/// closes or fails.
@MainActor
final class BufferingIndicator {
  /// The media the label counts as a full buffer, the 5 s the Android players wait for after a stall
  static let targetSeconds: Double = 5

  private static let percentPlaceholder = "{percent}"
  private static let updateInterval: TimeInterval = 0.25

  /// The translucent pill with the label, hidden while the player does not buffer
  let view = UIView()

  private let label = UILabel()
  private let template: String
  private weak var player: AVPlayer?
  private var timer: Timer?

  init(labels: [String: String]) {
    if let text = labels["buffering"], text.contains(Self.percentPlaceholder) {
      template = text
    } else {
      template = "Buffering \(Self.percentPlaceholder)%"
    }
    view.backgroundColor = UIColor(white: 0, alpha: 0.6)
    view.layer.cornerRadius = 8
    view.isUserInteractionEnabled = false
    view.isHidden = true
    view.translatesAutoresizingMaskIntoConstraints = false
    label.textColor = .white
    // Digits of one width, so that the pill does not wobble as the percentage changes
    label.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
    label.textAlignment = .center
    label.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(label)
    NSLayoutConstraint.activate([
      label.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
      label.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -6),
      label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
      label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
    ])
  }

  /// Follows [player] from now on, four times a second, until `stop`
  func start(_ player: AVPlayer) {
    self.player = player
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: Self.updateInterval, repeats: true) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.update()
      }
    }
    update()
  }

  /// Stops the updates and hides the label, for good
  func stop() {
    timer?.invalidate()
    timer = nil
    player = nil
    view.isHidden = true
  }

  /// The part of `targetSeconds` that [bufferedAhead] seconds loaded ahead of the position fill, from 0 to 100
  static func percent(bufferedAhead: Double, target: Double = targetSeconds) -> Int {
    guard target > 0 else { return 100 }
    guard bufferedAhead.isFinite, bufferedAhead > 0 else { return 0 }
    return min(100, Int(bufferedAhead / target * 100))
  }

  /// Seconds of media loaded from the position of [item] on, in the loaded range that holds the position
  static func bufferedAhead(of item: AVPlayerItem) -> Double {
    let position = item.currentTime()
    guard position.isNumeric else { return 0 }
    for value in item.loadedTimeRanges {
      let range = value.timeRangeValue
      if range.containsTime(position) {
        return CMTimeGetSeconds(CMTimeSubtract(range.end, position))
      }
    }
    return 0
  }

  /// Whether [player] waits for its item to load: the item is not ready or not likely to keep up, and nothing plays
  static func isBuffering(_ player: AVPlayer) -> Bool {
    guard let item = player.currentItem, item.status != .failed else { return false }
    guard player.timeControlStatus != .playing else { return false }
    return item.status != .readyToPlay || !item.isPlaybackLikelyToKeepUp
  }

  private func update() {
    guard let player, let item = player.currentItem, Self.isBuffering(player) else {
      view.isHidden = true
      return
    }
    let percent = Self.percent(bufferedAhead: Self.bufferedAhead(of: item))
    label.text = template.replacingOccurrences(of: Self.percentPlaceholder, with: String(percent))
    view.isHidden = false
  }
}
