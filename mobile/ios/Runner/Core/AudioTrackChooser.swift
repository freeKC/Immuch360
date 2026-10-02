import AVFoundation
import UIKit

/// The audio tracks of the video an AVPlayer plays (languages, commentary), and the pick of the user among them, for
/// the native video players. A video with two audio tracks or more shows an audio track button; its menu lists the
/// options of the audible media selection group of the asset by language and name, with the one playing checked, and
/// the pick goes to the player item through `select(_:in:)`.
///
/// The language of the track picked is remembered for every video (user defaults), and the players prefer it for the
/// next videos through their media selection criteria (see `preferSavedLanguage`).
///
/// [labels] are the translated labels from Flutter, under the keys below; English is the fallback.
@MainActor
final class AudioTrackChooser {
  /// An audio track of the video and its name in the menu
  struct Track {
    let option: AVMediaSelectionOption
    let name: String
  }

  private static let languageKey = "video_audio_track_language"

  /// Language codes that name no language: undetermined, multiple languages, no linguistic content
  private static let noLanguage: Set<String> = ["und", "mul", "zxx", "mis"]

  private let labels: [String: String]
  /// The language the names of the track languages are written in: the language of the app
  private let displayLocale: Locale
  private var group: AVMediaSelectionGroup?
  private weak var item: AVPlayerItem?
  private(set) var tracks: [Track] = []

  init(labels: [String: String]) {
    self.labels = labels
    if let tag = labels["audioTrackLocale"], !tag.isEmpty {
      displayLocale = Locale(identifier: tag)
    } else {
      displayLocale = Locale.current
    }
  }

  /// Label of the audio track button and title of its menu
  var buttonLabel: String { text("audioTrack", "Audio track") }

  /// Whether the video has a choice of audio tracks
  var hasChoice: Bool { tracks.count >= 2 }

  /// Makes [player] prefer the language picked last, for the items it plays from now on. Call it before the item
  /// is set.
  static func preferSavedLanguage(_ player: AVPlayer) {
    guard let language = UserDefaults.standard.string(forKey: languageKey), !language.isEmpty else { return }
    let criteria = AVPlayerMediaSelectionCriteria(preferredLanguages: [language], preferredMediaCharacteristics: nil)
    player.setMediaSelectionCriteria(criteria, forMediaCharacteristic: .audible)
  }

  /// Reads the audio tracks of [item], once it can play. Returns whether the video has a choice of tracks.
  func load(_ item: AVPlayerItem) async -> Bool {
    guard let group = try? await item.asset.loadMediaSelectionGroup(for: .audible) else {
      tracks = []
      return false
    }
    var named: [Track] = []
    for (index, option) in group.options.enumerated() {
      let title = await Self.title(of: option)
      let isDefault = group.options.count > 1 && option == group.defaultOption
      named.append(Track(option: option, name: name(of: option, number: index + 1, title: title, isDefault: isDefault)))
    }
    self.group = group
    self.item = item
    tracks = named
    return hasChoice
  }

  /// The menu of the audio tracks, built each time it opens so that the track playing is the one checked. [picked]
  /// runs after a pick, with the name of the track.
  func menu(picked: @escaping (String) -> Void) -> UIMenu {
    let element = UIDeferredMenuElement.uncached { [weak self] completion in
      Task { @MainActor [weak self] in
        guard let self else {
          completion([])
          return
        }
        let selected = self.selectedOption()
        completion(
          self.tracks.map { track in
            UIAction(title: track.name, state: track.option == selected ? .on : .off) { [weak self] _ in
              self?.select(track)
              picked(track.name)
            }
          })
      }
    }
    return UIMenu(title: buttonLabel, children: [element])
  }

  /// Name of the track playing, for the accessibility value of the button
  var selectedName: String? {
    let selected = selectedOption()
    return tracks.first { $0.option == selected }?.name
  }

  private func selectedOption() -> AVMediaSelectionOption? {
    guard let group, let item else { return nil }
    return item.currentMediaSelection.selectedMediaOption(in: group)
  }

  /// Plays [track] and remembers its language for the next videos; a track without a language leaves the next
  /// videos to their own default
  private func select(_ track: Track) {
    guard let group, let item else { return }
    item.select(track.option, in: group)
    if let language = Self.language(of: track.option) {
      UserDefaults.standard.set(language, forKey: Self.languageKey)
    } else {
      UserDefaults.standard.removeObject(forKey: Self.languageKey)
    }
  }

  /// "French", "English (United States)" in the language of the app, the name of the track in the file when it says
  /// more, and the default mark; "Track 2" for a track with neither language nor name
  private func name(of option: AVMediaSelectionOption, number: Int, title: String?, isDefault: Bool) -> String {
    var parts: [String] = []
    var languageName: String?
    if let language = Self.language(of: option) {
      let name = displayLocale.localizedString(forIdentifier: language) ?? language
      // Some languages write their names in lower case ("français"), the menu starts with a capital
      let capitalized = name.prefix(1).uppercased(with: displayLocale) + name.dropFirst()
      languageName = capitalized
      parts.append(capitalized)
    }
    if let title, !title.isEmpty, title.caseInsensitiveCompare(languageName ?? "") != .orderedSame {
      parts.append(title)
    }
    if parts.isEmpty {
      parts.append(text("audioTrackNumber", "Track {track}").replacingOccurrences(of: "{track}", with: "\(number)"))
    }
    if isDefault {
      parts.append(text("audioTrackDefault", "Default"))
    }
    return parts.joined(separator: ", ")
  }

  /// The language tag of [option], nil for none or for a code that names no language
  private static func language(of option: AVMediaSelectionOption) -> String? {
    guard let tag = option.extendedLanguageTag ?? option.locale?.identifier else { return nil }
    let trimmed = tag.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, !noLanguage.contains(trimmed.lowercased()) else { return nil }
    return trimmed
  }

  /// The name the file gives the track (its title metadata), if any
  private static func title(of option: AVMediaSelectionOption) async -> String? {
    let items = AVMetadataItem.metadataItems(from: option.commonMetadata, filteredByIdentifier: .commonIdentifierTitle)
    guard let first = items.first, let value = try? await first.load(.stringValue) else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  /// A label from Flutter, or its English fallback
  private func text(_ key: String, _ fallback: String) -> String {
    guard let value = labels[key], !value.isEmpty else { return fallback }
    return value
  }
}
