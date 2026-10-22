import AVFoundation
import Flutter
import UIKit

/// The live view of the Tapo cameras on iPhone and iPad, a platform view of type [CameraLiveViewFactory.viewType], as
/// CameraLiveView.kt is on Android. AVPlayer has no RTSP: Dart pulls the camera's stream, makes a live HLS playlist of
/// it and serves it on the local media bridge, and this view plays that http://127.0.0.1 address (CameraLiveSource
/// with isHls). No camera account ever reaches this side, and the errors sent to Flutter carry error domains and
/// codes only, never the address.
///
/// The views are kept by id, weakly: Flutter owns them, and an iOS platform view gets no dispose call.
final class CameraLiveViewFactory: NSObject, FlutterPlatformViewFactory {
  static let viewType = "immuch/camera_live"

  private let events: CameraLiveEvents
  private let views = NSMapTable<NSNumber, CameraLivePlayerView>.strongToWeakObjects()

  init(messenger: FlutterBinaryMessenger) {
    events = CameraLiveEvents(binaryMessenger: messenger)
    super.init()
  }

  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
    let view = CameraLivePlayerView(frame: frame, viewId: viewId, events: events)
    views.setObject(view, forKey: NSNumber(value: viewId))
    return view
  }

  /// The view of [viewId], nil once Flutter let go of it
  func view(_ viewId: Int64) -> CameraLivePlayerView? {
    views.object(forKey: NSNumber(value: viewId))
  }
}

/// What Flutter asks of the live views: the playlist to play, the sound, the end. Pigeon calls it on the main thread;
/// a view already gone ignores the call.
final class CameraLiveApiImpl: CameraLiveApi {
  private let views: CameraLiveViewFactory

  init(views: CameraLiveViewFactory) {
    self.views = views
  }

  func setSource(viewId: Int64, source: CameraLiveSource) throws {
    views.view(viewId)?.play(source)
  }

  func setMuted(viewId: Int64, muted: Bool) throws {
    views.view(viewId)?.setMuted(muted)
  }

  func stop(viewId: Int64) throws {
    views.view(viewId)?.stop()
  }
}

/// The UIView of a live view, whose layer is the AVPlayerLayer: it follows the size Flutter gives the view
final class CameraLiveLayerView: UIView {
  override class var layerClass: AnyClass { AVPlayerLayer.self }

  var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

/// One live view: an AVPlayer on the live playlist, a few seconds behind its live edge, muted at first, the picture
/// kept at its aspect ratio on black. Its states: connecting until the first frame shows, playing, buffering while it
/// waits for the stream, failed with the reason, idle once stopped.
final class CameraLivePlayerView: NSObject, FlutterPlatformView {
  /// How far behind the live edge the player starts and stays: about one segment of the cameras' 2 s GOP, plus room
  /// for the next one to be cut
  private static let offsetFromLive = CMTime(seconds: 3, preferredTimescale: 600)

  private let viewId: Int64
  private let events: CameraLiveEvents
  private let container: CameraLiveLayerView
  private var player: AVPlayer?
  private var observations: [NSKeyValueObservation] = []
  private var notifications: [NSObjectProtocol] = []
  private var muted = true
  private var hasAudio = true
  private var shown = false
  private var lastState: CameraLiveState?
  private var soundOn = false

  init(frame: CGRect, viewId: Int64, events: CameraLiveEvents) {
    self.viewId = viewId
    self.events = events
    container = CameraLiveLayerView(frame: frame)
    container.backgroundColor = .black
    container.isUserInteractionEnabled = false
    container.playerLayer.videoGravity = .resizeAspect
    super.init()
  }

  deinit {
    // Flutter let go of the view: nothing plays on
    releasePlayer()
  }

  func view() -> UIView {
    container
  }

  /// Plays [source] in place of what played before (also the switch between the HD and SD streams)
  func play(_ source: CameraLiveSource) {
    releasePlayer()
    // Only the bridge of this device: the live view never reads anything else
    guard source.isHls, let url = URL(string: source.url), url.scheme == "http", url.host == "127.0.0.1" else {
      send(.failed, error: "unsupported address")
      return
    }
    let item = AVPlayerItem(url: url)
    item.configuredTimeOffsetFromLive = Self.offsetFromLive
    item.automaticallyPreservesTimeOffsetFromLive = true
    let player = AVPlayer(playerItem: item)
    player.isMuted = muted
    player.allowsExternalPlayback = false
    container.playerLayer.player = player
    self.player = player
    hasAudio = true
    shown = false
    observe(item, of: player)
    applySound()
    send(.connecting, error: nil)
    player.play()
  }

  func setMuted(_ muted: Bool) {
    self.muted = muted
    player?.isMuted = muted
    applySound()
  }

  func stop() {
    guard player != nil else { return }
    releasePlayer()
    send(.idle, error: nil)
  }

  private func observe(_ item: AVPlayerItem, of player: AVPlayer) {
    // KVO may call on any thread: the states go out on the main one, for the current item only
    let onMain: (@escaping (CameraLivePlayerView) -> Void) -> Void = { [weak self, weak item] action in
      DispatchQueue.main.async {
        guard let self, let item, item === self.player?.currentItem else { return }
        action(self)
      }
    }
    observations = [
      item.observe(\.status) { _, _ in onMain { $0.statusChanged() } },
      item.observe(\.tracks) { _, _ in onMain { $0.tracksChanged() } },
      player.observe(\.timeControlStatus) { _, _ in onMain { $0.report() } },
      container.playerLayer.observe(\.isReadyForDisplay) { _, _ in onMain { $0.report() } },
    ]
    let center = NotificationCenter.default
    notifications = [
      center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) {
        [weak self] note in
        self?.fail(note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError)
      },
      center.addObserver(forName: AVPlayerItem.playbackStalledNotification, object: item, queue: .main) {
        [weak self] _ in
        self?.report()
      },
    ]
  }

  private func statusChanged() {
    guard let item = player?.currentItem else { return }
    if item.status == .failed {
      fail(item.error as NSError?)
    } else {
      report()
    }
  }

  /// Whether the stream has sound, once its tracks are known: the playlist of a camera without sound, or the one Dart
  /// made without it after a failure, has none
  private func tracksChanged() {
    guard let tracks = player?.currentItem?.tracks, !tracks.isEmpty else { return }
    let audio = tracks.contains { $0.assetTrack?.mediaType == .audio }
    if audio != hasAudio {
      hasAudio = audio
      report(force: true)
    }
  }

  private func report(force: Bool = false) {
    guard let player, let item = player.currentItem, item.status != .failed else { return }
    let state: CameraLiveState
    if item.status == .readyToPlay && player.timeControlStatus == .playing && container.playerLayer.isReadyForDisplay {
      shown = true
      state = .playing
    } else {
      state = shown ? .buffering : .connecting
    }
    if force || state != lastState {
      send(state, error: nil)
    }
  }

  /// The player gave up: the last frame stays, the observers go, Flutter decides what comes next
  private func fail(_ error: NSError?) {
    guard let player else { return }
    removeObservers()
    player.pause()
    send(.failed, error: Self.describe(error))
  }

  /// The domain and code of [error] and of the error under it ("CoreMediaErrorDomain -12642"), never its text: an
  /// URL error tells its address there
  private static func describe(_ error: NSError?) -> String {
    guard let error else { return "AVPlayer error" }
    var text = "\(error.domain) \(error.code)"
    if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
      text += " (\(underlying.domain) \(underlying.code))"
    }
    return text
  }

  /// Sound even with the ring switch on silent once the user turns it on, as the other players of the app; the
  /// music of other apps goes on while the live view is muted
  private func applySound() {
    let wanted = player != nil && !muted
    let session = AVAudioSession.sharedInstance()
    if wanted {
      try? session.setCategory(.playback, mode: .moviePlayback)
      try? session.setActive(true)
    } else if player != nil {
      try? session.setCategory(.ambient)
    } else if soundOn {
      // Lets the music the live view interrupted resume
      try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }
    soundOn = wanted
  }

  private func removeObservers() {
    observations.forEach { $0.invalidate() }
    observations = []
    notifications.forEach { NotificationCenter.default.removeObserver($0) }
    notifications = []
  }

  private func releasePlayer() {
    removeObservers()
    guard let player else { return }
    self.player = nil
    player.pause()
    player.replaceCurrentItem(with: nil)
    container.playerLayer.player = nil
    applySound()
  }

  private func send(_ state: CameraLiveState, error: String?) {
    lastState = state
    events.stateChanged(viewId: viewId, state: state, error: error, hasAudio: hasAudio) { _ in }
  }
}
