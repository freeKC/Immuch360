import Foundation

// Pure Swift (Foundation only): compiled with ios/SwiftTests/main.swift by the CI's macOS job, as StabilizationTable.

/// What Flutter tells the 360° player about the stabilisation of a video (issue 14), see
/// SphericalVideoApi.setStabilization: called right before the player opens (the setting, and whether Flutter reads a
/// motion track), then once more with the table of a raw video. The player may not exist yet when the first message
/// comes: the last message about each URL waits here, and the player that plays that URL listens. A message about
/// another video never takes the place of the one of the video that plays. The last [maxUrls] URLs are kept, a table
/// being a few MB long. Main thread only, as Pigeon and UIKit call it. The same rules as the Android player
/// (PlayerStabilization.kt).
final class StabilizationInbox: @unchecked Sendable {
  static let shared = StabilizationInbox()

  /// URLs whose last message is kept
  static let maxUrls = 3

  /// [table] is nil while Flutter reads the track ([hasTrack] true) and for a file without one
  struct Message: Sendable {
    let url: String
    let enabled: Bool
    let hasTrack: Bool
    let table: StabilizationTable?
    let summary: String?
  }

  // The last message about each URL, the oldest first
  private var messages: [Message] = []
  private var listener: (owner: ObjectIdentifier, handler: (Message) -> Void)?

  /// Keeps [message] for the player of its URL, and hands it to the player that listens
  func post(_ message: Message) {
    messages.removeAll { $0.url == message.url }
    messages.append(message)
    if messages.count > Self.maxUrls {
      messages.removeFirst(messages.count - Self.maxUrls)
    }
    listener?.handler(message)
  }

  /// The last message about [url], nil when there is none
  func latest(for url: String?) -> Message? {
    guard let url else { return nil }
    return messages.last(where: { $0.url == url })
  }

  /// [handler] gets every message from now on, in place of the listener before; [owner] names it for
  /// [stopListening]
  func listen(owner: AnyObject, _ handler: @escaping (Message) -> Void) {
    listener = (owner: ObjectIdentifier(owner), handler: handler)
  }

  /// Stops the listener of [owner], unless another one took its place: a player that closes may go after the next one
  /// opened
  func stopListening(owner: AnyObject) {
    if listener?.owner == ObjectIdentifier(owner) {
      listener = nil
    }
  }

  /// Forgets the message about [url]: its player closed
  func forget(_ url: String?) {
    guard let url else { return }
    messages.removeAll { $0.url == url }
  }
}

/// The stabilisation switch of the 360° player and what follows from it: whether its button shows, which table the
/// frames get, and which notice to show. Pure Swift, so that the rules are tested without a device; the player applies
/// what it says. The rules of the Android player (StabilizationSwitch in PlayerStabilization.kt) without its CAMM
/// track: AVFoundation applies none.
///
/// The button shows for a raw video whose track Flutter reads or has read while the frame shown is the stitched sphere.
/// Off, the frames get no rotation: off means the raw video, and the switch starts at the setting Flutter sends before
/// every video opens. On with a table, the table turns the frames.
final class StabilizationSwitch {
  /// What the player knows of the motion track of the file
  enum Track: Equatable {
    case unknown
    case pending
    case ready
    case missing
  }

  /// A notice to show for a few seconds
  enum Notice: Equatable {
    case stabilized
    case noTrack
  }

  /// The switch: on by default, as the setting
  private(set) var enabled: Bool
  private(set) var track = Track.unknown
  /// The table of the file, once Flutter sent it
  private(set) var table: StabilizationTable?

  /// The frame shown is the stitched sphere, whose picture the table describes; false where the stitch is not in use
  var stitched = true

  // The user pressed the button in this player: the setting Flutter sends no longer moves the switch
  private(set) var wasTouched = false
  // The user turned the switch on in this player: a file without a track then says so
  private var turnedOnByUser = false
  // "Stabilised..." showed once already in this player
  private var stabilizedNoticeShown = false

  init(enabled: Bool) {
    self.enabled = enabled
  }

  /// Whether the button shows: for a track that turns what shows
  var buttonVisible: Bool { stitched && (track == .pending || track == .ready) }

  /// The table the frames get: none when off, and none when the frame shown is not [stitched]
  var activeTable: StabilizationTable? { enabled && stitched ? table : nil }

  /// What Flutter said about the file (see StabilizationInbox): the table, or that it reads the track ([hasTrack]
  /// without a table), or that the file has none. A table refused by the player counts as none. A file without a track
  /// says so only when the user turned the switch on in this player.
  func onTrack(hasTrack: Bool, table: StabilizationTable?) -> Notice? {
    self.table = hasTrack ? table : nil
    if !hasTrack {
      track = .missing
    } else if table != nil {
      track = .ready
    } else {
      track = .pending
    }
    return track == .missing && enabled && turnedOnByUser ? .noTrack : nil
  }

  /// The setting Flutter sent, unless the user already pressed the button in this player
  func onSetting(_ enabled: Bool) {
    if !wasTouched {
      self.enabled = enabled
    }
  }

  /// The user pressed the button: the switch flips. Turned on, the notice tells what the user gets: stabilised when the
  /// file has a table, no track when it turned out to have none; nothing while the track is read (the notice comes with
  /// the first stabilised frame).
  func toggle() -> Notice? {
    wasTouched = true
    enabled.toggle()
    guard enabled else { return nil }
    turnedOnByUser = true
    if table != nil {
      stabilizedNoticeShown = true
      return .stabilized
    }
    return track == .missing ? .noTrack : nil
  }

  /// A frame was drawn with the table: the first one of this player tells the user, once
  func onStabilizedFrame() -> Notice? {
    guard !stabilizedNoticeShown else { return nil }
    stabilizedNoticeShown = true
    return .stabilized
  }
}
