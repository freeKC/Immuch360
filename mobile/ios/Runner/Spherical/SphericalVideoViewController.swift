import AVFoundation
import CoreMotion
import SceneKit
import UIKit
import native_video_player
import simd

private let defaultFieldOfView: CGFloat = 80
private let minFieldOfView: CGFloat = 30
private let maxFieldOfView: CGFloat = 100
private let maxPitch: Float = 85 * Float.pi / 180
// Drag speed at the default field of view, slower when zoomed in
private let radiansPerPoint: Float = 0.12 * Float.pi / 180
private let controlsHideDelay: TimeInterval = 4
private let messageDuration: TimeInterval = 2
private let xAxis = SIMD3<Float>(1, 0, 0)
private let yAxis = SIMD3<Float>(0, 1, 0)
private let zAxis = SIMD3<Float>(0, 0, 1)

/// Plays an equirectangular video full screen, from the centre of a sphere textured with the video.
///
/// Drags turn the view (the picture follows the finger, so a drag to the left turns the view to the right), a pinch
/// zooms. While the gyroscope button is on, the motion of the phone turns the view and drags only turn it around the
/// vertical axis. A tap on the video shows or hides the controls, which also hide on their own while the video plays.
/// The 3D button tells how a stereoscopic video lays out its two eyes: the phone shows the left eye only. The coverage
/// button (360° or 180°) tells whether the video covers the whole sphere or only its front half, as VR180 videos do;
/// the back half is then black. A video with several audio tracks (languages, commentary) shows an audio track button,
/// see [AudioTrackChooser]. While the video loads or stalls, a label tells how far the buffer is filled, see
/// [BufferingIndicator]. Flutter hears about the close through [SphericalVideoEvents], with the layout and the
/// coverage shown last.
///
/// With a fallback URL (the server's transcoded stream), the original gives way to it once: when its codec and size
/// are above what the device decodes (see [VideoDecoderSupport]), read as soon as its tracks are known, or when it
/// fails. The fallback stream starts where the original stopped; the error label only shows if it fails too.
///
/// With a rawProjection of version 1 (a dual fisheye calibration), the frame is the raw recording of a two lens camera
/// (Insta360 .insv): the two fisheye circles side by side. A shader stitches them on the sphere for every pixel,
/// levelled with the gravity the camera measured, see [applyDualFisheye].
///
/// With a rawProjection of version 2 ([RawStitchSpec]), the raw recording may hold its lenses in one side by side
/// frame, in two video tracks of one file (Insta360 X4, X5, X6, DJI Osmo 360, the EAC strips of a GoPro .360) or in
/// two files (Insta360 split pairs): a video composition hands the frames of both lenses, paired by AVFoundation, to
/// [RawStitchCompositor], which stitches them with Metal into an equirectangular frame that the sphere shows as any
/// 360° video. AVPlayer keeps the clock, the sound, the buffering and the seeking. The item is built by
/// [RawStitchItemBuilder]: one file plays directly (its own tracks, read once), else through an AVMutableComposition.
/// When a source fails, the next one plays from where it stopped: the composition after the direct mode, then the
/// server's transcoded streams where they keep the lenses (a side by side frame, or both files of a pair), else the
/// error label. Lens tracks above what the decoder keeps up with go to the transcoded streams before they play, or
/// play anyway with a message.
///
/// A raw recording covers the whole sphere and holds no stereo pair: the coverage and 3D buttons hide, and the coverage
/// and the layout Flutter gave go back to it unchanged.
final class SphericalVideoViewController: UIViewController, UIGestureRecognizerDelegate {
  private let videoUrl: URL
  // The server's transcoded stream, nil when there is none
  private let fallbackUrl: URL?
  private let headers: [String: String]
  private let videoTitle: String
  private let closeLabel: String?
  private let errorMessage: String
  private let stereoLabels: [String: String]
  private let events: SphericalVideoEvents
  private let audioTracks: AudioTrackChooser
  // What the rawProjection asks for, nil for an equirectangular video
  private let raw: RawProjection?

  private let player = AVPlayer()
  private let sceneView = SCNView(frame: .zero)
  private let cameraNode = SCNNode()
  private let sphereNode = SCNNode()
  private let videoMaterial = SCNMaterial()
  // The back half of a half sphere
  private let backMaterial = SCNMaterial()
  private let motionManager = CMMotionManager()
  private var displayLink: CADisplayLink?
  private var statusObservation: NSKeyValueObservation?
  private var timeControlObservation: NSKeyValueObservation?
  private var presentationSizeObservation: NSKeyValueObservation?

  private let topBar = UIView()
  private let closeButton = UIButton(type: .system)
  private let titleLabel = UILabel()
  private let coverageButton = UIButton(type: .system)
  private let audioButton = UIButton(type: .system)
  private let stereoButton = UIButton(type: .system)
  private let motionButton = UIButton(type: .system)
  private let playPauseButton = UIButton(type: .system)
  private let spinner = UIActivityIndicatorView(style: .large)
  private let errorLabel = UILabel()
  private let messageView = UIView()
  private let messageLabel = UILabel()
  private let bufferingIndicator: BufferingIndicator

  // Where the view looks, in radians: yaw around the vertical axis, growing to the left, and pitch, growing upwards,
  // which only drags set (the phone's attitude replaces it while the motion drives the view)
  private var yaw: Float = 0
  private var pitch: Float = 0
  private var fieldOfView = defaultFieldOfView
  private var pinchStartFieldOfView = defaultFieldOfView
  private var motionEnabled = false
  // Last sample of a previous run, measured in another reference frame
  private var staleMotionTimestamp: TimeInterval?
  private var alignHeadingOnNextMotion = false
  private var screenOrientation = UIInterfaceOrientation.portrait
  // The guess of Flutter from the dimensions of the video at first, what the 3D button picks once the user taps it
  private var stereoLayout: StereoLayout
  private var stereoLayoutChosen = false
  // The layout Flutter gave, kept while the shape of the frame tells nothing more for the coverage in use
  private let initialStereoLayout: StereoLayout
  // Zero until the first frame is known
  private var frameSize = CGSize.zero
  // What Flutter gave at first, what the coverage button picks once the user taps it
  private var coverage: SphereCoverage

  private var controlsVisible = true
  private var failed = false
  private var reachedEnd = false
  private var started = false
  private var closing = false
  private var idleTimerWasDisabled = false
  private var closedReported = false
  private var audioTracksRequested = false
  // The last tap on play or pause: a switch to the fallback stream keeps the video playing or paused
  private var playRequested = true
  // The original gave way to the fallback stream, which happens once
  private var fallbackPlaying = false
  // Where the fallback stream resumes and whether it plays then, applied once it is ready: an item cannot seek
  // before that. The spinner turns meanwhile.
  private var pendingResume: (time: CMTime?, play: Bool)?

  /// Where the frames of a stitched raw video come from
  private enum StitchAttempt: Equatable {
    /// The original file or files: through the asset itself (direct) or through an AVMutableComposition
    case original(composition: Bool)
    /// The server's transcoded streams, for a side by side frame or both files of a pair
    case transcoded
  }

  // The source of the stitched item in use or being built, and every source tried for this opening
  private var stitchAttempt: StitchAttempt?
  private var stitchAttemptsTried: [StitchAttempt] = []
  private var stitchItem: RawStitchItem?
  // While the item of a stitched raw video is built: the spinner turns
  private var preparingStitch = false
  // Counts the builds, so that a build overtaken by another one (or by the close) is dropped
  private var stitchGeneration = 0
  // The GPU valve lowers the render size once per item
  private var valveUsed = false
  private var heavyNoticeShown = false
  private var lastStatisticsPoll: CFTimeInterval = 0
  // The frame count of the stitched item at the last poll and since when it has stayed so, while the player tries to
  // play; nil while it does not (see stitchProducesNoFrame)
  private var stitchFrameWatch: (frames: Int, since: CFTimeInterval)?
  private var tracksObservation: NSKeyValueObservation?
  // Links named .mp4 to local raw files, for iOS 16 and earlier: removed when the player closes
  private var temporaryLinks: [URL] = []

  /// The calibration of a raw frame of version 1, stitched by the shader modifier
  private var dualFisheye: DualFisheyeCalibration? {
    if case .sideBySide(let calibration)? = raw {
      return calibration
    }
    return nil
  }

  private var isRaw: Bool { raw != nil }

  /// The rawProjection of version 2, stitched by RawStitchCompositor
  private var stitched: (spec: RawStitchSpec, geometry: RawStitchGeometry)? {
    if case .stitched(let spec, let geometry)? = raw {
      return (spec: spec, geometry: geometry)
    }
    return nil
  }

  /// [errorMessage] and [stereoLabels] come translated from Flutter, English is the fallback; [stereoLabels] also
  /// holds the labels of the coverage button, of the audio track button, of the buffering label, of the message of a
  /// switch to the fallback stream ("sourceSwitched") and of the message of a raw video heavier than the decoder
  /// ("rawHeavy"). [stereoLayout] is the layout Flutter guessed from the dimensions of the video, [coverage] how much
  /// of the sphere it covers. [fallbackUrl] is the server's transcoded stream, played with the same headers. [raw] is
  /// what the rawProjection asks for, nil for an equirectangular video. [events] is told once when the player closes.
  init(
    url: URL,
    fallbackUrl: URL?,
    headers: [String: String],
    title: String,
    closeLabel: String?,
    errorMessage: String?,
    stereoLayout: StereoLayout,
    stereoLabels: [String: String],
    coverage: SphereCoverage,
    raw: RawProjection?,
    events: SphericalVideoEvents
  ) {
    videoUrl = url
    self.fallbackUrl = fallbackUrl
    self.headers = headers
    videoTitle = title
    self.closeLabel = closeLabel
    self.errorMessage = errorMessage ?? "This video cannot be played"
    self.stereoLayout = stereoLayout
    initialStereoLayout = stereoLayout
    self.stereoLabels = stereoLabels
    self.coverage = coverage
    self.raw = raw
    self.events = events
    audioTracks = AudioTrackChooser(labels: stereoLabels)
    bufferingIndicator = BufferingIndicator(labels: stereoLabels)
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  deinit {
    motionManager.stopDeviceMotionUpdates()
  }

  override var prefersStatusBarHidden: Bool { true }

  override var prefersHomeIndicatorAutoHidden: Bool { !controlsVisible }

  // The interface follows the phone, within the orientations of the Info.plist (no upside down on iPhone)
  override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .all }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
    setUpPlayer()
    setUpScene()
    setUpControls()
    setUpGestures()

    // The motion drives the view from the start where the phone has the sensors for it
    motionEnabled = motionManager.isDeviceMotionAvailable
    motionButton.isHidden = !motionManager.isDeviceMotionAvailable
    // A raw recording always covers the whole sphere and is never a stereo pair
    coverageButton.isHidden = isRaw
    stereoButton.isHidden = isRaw
    updateMotionButton()
    updateCoverageButton()
    applyStereoLayout()
    updateCamera()

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(appDidEnterBackground),
      name: UIApplication.didEnterBackgroundNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(appWillEnterForeground),
      name: UIApplication.willEnterForegroundNotification,
      object: nil
    )
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    guard !started else { return }
    started = true
    idleTimerWasDisabled = UIApplication.shared.isIdleTimerDisabled

    // Sound even with the ring switch on silent, like the Flutter video player
    try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    try? AVAudioSession.sharedInstance().setActive(true)

    if motionEnabled {
      startMotion()
    }
    let link = CADisplayLink(target: self, selector: #selector(step(_:)))
    link.add(to: .main, forMode: .common)
    displayLink = link
    // "Buffering 42%" while the video loads or stalls
    bufferingIndicator.start(player)
    player.play()
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    stop()
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    // Frees the decoder and the buffered video
    statusObservation?.invalidate()
    timeControlObservation?.invalidate()
    presentationSizeObservation?.invalidate()
    tracksObservation?.invalidate()
    // A stitched item still being built is dropped
    stitchGeneration += 1
    player.replaceCurrentItem(with: nil)
    sceneView.isPlaying = false
    for link in temporaryLinks {
      try? FileManager.default.removeItem(at: link)
    }
    temporaryLinks = []
    // Lets the music the video interrupted resume
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    reportClosed()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    if let orientation = view.window?.windowScene?.interfaceOrientation, orientation != .unknown {
      screenOrientation = orientation
    }
    // The field of view spans the longer side of the screen, in portrait as in landscape
    let size = view.bounds.size
    let direction: SCNCameraProjectionDirection = size.width > size.height ? .horizontal : .vertical
    cameraNode.camera?.projectionDirection = direction
  }

  // MARK: - Player

  /// Seconds of media buffered ahead for a video read over HTTP
  private static let streamingForwardBufferDuration: TimeInterval = 15

  private func setUpPlayer() {
    // The audio track of the language picked last, where the video has one
    AudioTrackChooser.preferSavedLanguage(player)
    if let stitched {
      if fallbackUrl != nil && stitched.spec.layout == .twoTracks {
        print("RawStitch: the transcoded stream holds one lens of this recording, it is not used")
      }
      if RawStitchRenderer.shared == nil {
        // Once viewDidLoad has made the controls
        Task { @MainActor [weak self] in
          self?.showError("RawStitch: Metal is not available")
        }
      } else {
        // A pair of files only plays through a composition
        startStitch(.original(composition: stitched.spec.layout == .twoFiles))
      }
    } else {
      let asset = loadItem(videoUrl)
      checkDecoder(asset)
    }

    timeControlObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] _, _ in
      Task { @MainActor [weak self] in
        self?.playbackStateChanged()
      }
    }
  }

  /// Makes [url] the item of the player, with its observations: the original at first, the fallback stream after a
  /// switch. Returns the asset of the item.
  @discardableResult
  private func loadItem(_ url: URL) -> AVURLAsset {
    let asset = makeAsset(for: url)
    let item = AVPlayerItem(asset: asset)
    if !url.isFileURL {
      // Read over HTTP (the media bridge of a network share, a server): more media buffered ahead, so that a share
      // that answers in bursts does not stall the playback every few seconds. Local files keep the defaults.
      item.preferredForwardBufferDuration = Self.streamingForwardBufferDuration
    }
    install(item)
    return asset
  }

  /// Forgets the observations of the item the player plays, before another one replaces it
  private func detachItem() {
    statusObservation?.invalidate()
    presentationSizeObservation?.invalidate()
    tracksObservation?.invalidate()
    tracksObservation = nil
    if let previous = player.currentItem {
      NotificationCenter.default.removeObserver(self, name: .AVPlayerItemDidPlayToEndTime, object: previous)
      NotificationCenter.default.removeObserver(self, name: .AVPlayerItemFailedToPlayToEndTime, object: previous)
    }
  }

  /// Makes [item] the item of the player, with its observations. A stitched item read directly from its file also
  /// gets its lens tracks enabled, see [enableLensTracks].
  private func install(_ item: AVPlayerItem) {
    // The item replaced, if any, tells nothing more
    detachItem()
    player.replaceCurrentItem(with: item)

    statusObservation = item.observe(\.status, options: [.new]) { [weak self] observed, _ in
      let status = observed.status
      let reason = observed.error?.localizedDescription
      let itemId = ObjectIdentifier(observed)
      Task { @MainActor [weak self] in
        // A late change of an item the fallback stream replaced
        guard let self, self.isCurrentItem(itemId) else { return }
        if status == .failed {
          self.itemFailed(reason)
        } else if status == .readyToPlay {
          self.itemReady()
        }
      }
    }
    // Zero until the first frame is known
    presentationSizeObservation = item.observe(\.presentationSize, options: [.initial, .new]) {
      [weak self] observed, _ in
      let size = observed.presentationSize
      guard size.width > 0, size.height > 0 else { return }
      let itemId = ObjectIdentifier(observed)
      Task { @MainActor [weak self] in
        guard let self, self.isCurrentItem(itemId) else { return }
        self.frameSizeKnown(size)
      }
    }
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(playerItemDidPlayToEnd(_:)),
      name: .AVPlayerItemDidPlayToEndTime,
      object: item
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(playerItemFailedToPlayToEnd(_:)),
      name: .AVPlayerItemFailedToPlayToEndTime,
      object: item
    )
    if let stitchItem, stitchItem.mode == .direct, stitchItem.item === item {
      // The tracks of the item are listed once it loads
      tracksObservation = item.observe(\.tracks, options: [.initial, .new]) { [weak self] observed, _ in
        let itemId = ObjectIdentifier(observed)
        Task { @MainActor [weak self] in
          guard let self, self.isCurrentItem(itemId) else { return }
          self.enableLensTracks()
        }
      }
    }
  }

  /// Local files play as they are, those with the extension of a raw camera file as MP4 (see [rawFileAsset]). Server
  /// videos take the route of the Flutter video player (native_video_player): through its local proxy when the server
  /// asks for a client certificate or basic auth, else straight to the server with the custom headers and the session
  /// cookies. Those cookies live in the app group storage, which AVFoundation does not read by itself. The fallback
  /// stream and the second file of a raw pair take the same route as the original.
  private func makeAsset(for url: URL) -> AVURLAsset {
    if url.isFileURL {
      if Self.rawFileExtensions.contains(url.pathExtension.lowercased()) {
        return rawFileAsset(url)
      }
      return AVURLAsset(url: url)
    }
    if let proxyUrl = VideoProxyServer.shared.proxyURL(for: url) {
      return AVURLAsset(url: proxyUrl)
    }
    let cookies = URLSessionManager.cookieStorage.cookies(for: url) ?? []
    var httpHeaders = HTTPCookie.requestHeaderFields(with: cookies)
    httpHeaders.merge(headers) { _, custom in custom }
    return AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": httpHeaders])
  }

  /// The extensions of raw camera files, MP4 inside: Insta360 .insv and .lrv, GoPro .360, DJI .osv and .lrf
  private static let rawFileExtensions: Set<String> = ["insv", "360", "osv", "lrv", "lrf"]

  /// AVFoundation picks the type of a local file from its extension, which a raw camera file does not tell: it is
  /// given as MP4, by its MIME type from iOS 17, else through a link named .mp4 in the temporary folder (the file
  /// itself when no link can be made). A hard link comes first: the media server, in another process, may not follow
  /// a symbolic link from the temporary folder to a file elsewhere in the sandbox, while a hard link is the file
  /// itself. It only works on the same volume, hence the symbolic link after it.
  private func rawFileAsset(_ url: URL) -> AVURLAsset {
    if #available(iOS 17.0, *) {
      return AVURLAsset(url: url, options: [AVURLAssetOverrideMIMETypeKey: "video/mp4"])
    }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("raw360", isDirectory: true)
    let link = folder.appendingPathComponent("\(UUID().uuidString).mp4")
    do {
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    } catch {
      print("RawStitch: no .mp4 link to \(url.lastPathComponent), the file plays as it is: \(error)")
      return AVURLAsset(url: url)
    }
    do {
      try FileManager.default.linkItem(at: url, to: link)
      temporaryLinks.append(link)
      print("RawStitch: \(url.lastPathComponent) plays through a hard link named .mp4")
      return AVURLAsset(url: link)
    } catch {
      print("RawStitch: no hard link to \(url.lastPathComponent): \(error)")
    }
    do {
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
      temporaryLinks.append(link)
      print("RawStitch: \(url.lastPathComponent) plays through a symbolic link named .mp4")
      return AVURLAsset(url: link)
    } catch {
      print("RawStitch: no .mp4 link to \(url.lastPathComponent), the file plays as it is: \(error)")
      return AVURLAsset(url: url)
    }
  }

  /// Whether [itemId] is the item the player plays, and not one the fallback stream replaced
  private func isCurrentItem(_ itemId: ObjectIdentifier) -> Bool {
    guard let item = player.currentItem else { return false }
    return ObjectIdentifier(item) == itemId
  }

  /// Reads the codec and the coded size of the original as soon as its tracks are known, while the item loads, so
  /// that a video above what the device decodes gives way to the fallback stream before it stutters. Without a
  /// fallback, the original plays anyway and the log tells why it may stutter.
  private func checkDecoder(_ asset: AVURLAsset) {
    Task { @MainActor [weak self] in
      guard let format = await VideoDecoderSupport.videoFormat(of: asset) else { return }
      let verdict = VideoDecoderSupport.verdict(for: format)
      guard !verdict.supported else { return }
      guard let self, !self.closing, !self.fallbackPlaying else { return }
      let reason = verdict.reason ?? "above what this device decodes"
      if !self.switchToFallback(because: reason, format: format) {
        print("The 360° video may not play smoothly: \(reason)")
      }
    }
  }

  /// The item can play: its audio tracks and, after a switch to the fallback stream, the position and the state
  /// the original was in
  private func itemReady() {
    loadAudioTracks()
    guard let resume = pendingResume else { return }
    pendingResume = nil
    if let time = resume.time {
      player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }
    // Not before the player shows, which starts the playback itself, nor in the background, which pauses it
    if resume.play && started && !closing && UIApplication.shared.applicationState != .background {
      player.play()
    }
    playbackStateChanged()
  }

  /// The original gives way to the fallback stream once, the error label shows when there is none or it fails too. A
  /// stitched raw video moves to its next source instead, see [stitchFailed].
  private func itemFailed(_ reason: String?) {
    if stitched != nil {
      stitchFailed(reason ?? "unknown error")
      return
    }
    if switchToFallback(because: "the original failed: \(reason ?? "unknown error")") {
      return
    }
    showError(reason)
  }

  /// Plays the fallback stream in place of the original, from where it stopped and in the state the user left it
  /// (playing or paused). False when there is no fallback, when it already plays, or when the player failed or
  /// closes.
  @discardableResult
  private func switchToFallback(because reason: String, format: CMFormatDescription? = nil) -> Bool {
    guard let fallbackUrl, !fallbackPlaying, !failed, !closing else { return false }
    fallbackPlaying = true
    print("The 360° player switches to the transcoded stream: \(reason)")
    let position = player.currentTime()
    let resumeTime: CMTime? = position.isNumeric && position.seconds > 0 ? position : nil
    pendingResume = (time: resumeTime, play: playRequested)
    // Paused until the fallback stream is ready and in place, else it would start from its beginning
    player.pause()
    reachedEnd = false
    // The fallback stream may have other audio tracks: they are read again once it is ready
    audioTracksRequested = false
    audioButton.isHidden = true
    loadItem(fallbackUrl)
    playbackStateChanged()
    showMessage(VideoDecoderSupport.switchedMessage(stereoText("sourceSwitched", fallback: "Playing the transcoded stream"), format: format))
    return true
  }

  private func playbackStateChanged() {
    guard started, !closing else { return }
    let status = player.timeControlStatus
    let paused = status == .paused
    setSymbol(of: playPauseButton, to: paused ? "play.fill" : "pause.fill", pointSize: 28)
    playPauseButton.accessibilityLabel = paused ? "Play" : "Pause"
    // The fallback stream loads paused, see pendingResume; a stitched item is built before it loads
    if (status == .waitingToPlayAtSpecifiedRate || pendingResume != nil || preparingStitch) && !failed {
      spinner.startAnimating()
    } else {
      spinner.stopAnimating()
    }
    // The screen stays awake while the video plays or buffers
    UIApplication.shared.isIdleTimerDisabled = idleTimerWasDisabled || !paused

    if status == .playing {
      if controlsVisible {
        scheduleControlsHiding()
      }
    } else if paused && !controlsVisible {
      setControlsVisible(true)
    }
  }

  /// Shows the audio track button once the item can play, for a video with a choice of audio tracks
  private func loadAudioTracks() {
    guard !audioTracksRequested, !closing, let item = player.currentItem else { return }
    audioTracksRequested = true
    Task { @MainActor [weak self] in
      guard let self else { return }
      let hasChoice = await self.audioTracks.load(item)
      // Not for an item the fallback stream replaced meanwhile
      guard hasChoice, !self.closing, self.player.currentItem === item else { return }
      self.audioButton.menu = self.audioTracks.menu { [weak self] name in
        self?.audioTrackPicked(name)
      }
      self.audioButton.showsMenuAsPrimaryAction = true
      self.audioButton.accessibilityValue = self.audioTracks.selectedName
      self.audioButton.isHidden = false
    }
  }

  private func audioTrackPicked(_ name: String) {
    audioButton.accessibilityValue = name
    showMessage(name)
    scheduleControlsHiding()
  }

  private func showError(_ reason: String?) {
    guard !failed, !closing else { return }
    failed = true
    print("Cannot play the 360° video: \(reason ?? "unknown error")")
    player.pause()
    spinner.stopAnimating()
    bufferingIndicator.stop()
    errorLabel.isHidden = false
    playPauseButton.isHidden = true
    setControlsVisible(true)
  }

  // KVO and these notifications may come from any thread
  @objc private nonisolated func playerItemDidPlayToEnd(_ notification: Notification) {
    Task { @MainActor [weak self] in
      self?.reachedEnd = true
    }
  }

  @objc private nonisolated func playerItemFailedToPlayToEnd(_ notification: Notification) {
    let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
    let reason = error?.localizedDescription
    let itemId = (notification.object as? AVPlayerItem).map { ObjectIdentifier($0) }
    Task { @MainActor [weak self] in
      guard let self else { return }
      // A late failure of an item the fallback stream replaced
      if let itemId, !self.isCurrentItem(itemId) {
        return
      }
      self.itemFailed(reason)
    }
  }

  @objc private func appDidEnterBackground() {
    player.pause()
  }

  // The motion reference frame may have moved while the app was in the background: the view keeps its heading, and
  // the first sample after the return realigns the phone on it
  @objc private func appWillEnterForeground() {
    guard started, motionEnabled, !closing else { return }
    yaw = Self.heading(of: cameraNode.simdOrientation)
    staleMotionTimestamp = motionManager.deviceMotion?.timestamp
    alignHeadingOnNextMotion = true
  }

  /// Stops the playback, the motion and the refresh when the player closes, idempotent
  private func stop() {
    guard !closing else { return }
    closing = true
    NSObject.cancelPreviousPerformRequests(withTarget: self)
    displayLink?.invalidate()
    displayLink = nil
    bufferingIndicator.stop()
    player.pause()
    motionManager.stopDeviceMotionUpdates()
    if started {
      UIApplication.shared.isIdleTimerDisabled = idleTimerWasDisabled
    }
  }

  /// Tells Flutter, once, the stereo layout and the coverage the player showed last, after the corrections of the user
  private func reportClosed() {
    guard !closedReported else { return }
    closedReported = true
    events.closed(stereoLayout: stereoLayout, coverage: coverage) { result in
      if case .failure(let error) = result {
        print("Cannot tell Flutter that the 360° player closed: \(error.code)")
      }
    }
  }

  // MARK: - Scene

  private func setUpScene() {
    let camera = SCNCamera()
    camera.fieldOfView = fieldOfView
    camera.zNear = 0.1
    camera.zFar = 100
    cameraNode.camera = camera
    cameraNode.position = SCNVector3Zero

    // SceneKit draws the current frame of the player straight onto the sphere: no SpriteKit scene in between, so no
    // vertical flip to undo
    let material = videoMaterial
    material.diffuse.contents = player
    material.lightingModel = .constant
    material.isDoubleSided = true
    // Clamped, an edge of the frame does not blend with the opposite one, the other eye of a stereoscopic video
    material.diffuse.wrapS = .clamp
    material.diffuse.wrapT = .clamp

    if let dualFisheye {
      applyDualFisheye(dualFisheye)
    }

    // Behind a half sphere there is no picture: black, never the clamped edge of the frame
    backMaterial.diffuse.contents = UIColor.black
    backMaterial.lightingModel = .constant
    backMaterial.isDoubleSided = true

    rebuildSphere()

    let scene = SCNScene()
    scene.rootNode.addChildNode(sphereNode)
    scene.rootNode.addChildNode(cameraNode)

    sceneView.scene = scene
    sceneView.pointOfView = cameraNode
    sceneView.backgroundColor = .black
    // Redraws every frame, the video changes without the scene knowing
    sceneView.rendersContinuously = true
    sceneView.isPlaying = true
    sceneView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(sceneView)
    NSLayoutConstraint.activate([
      sceneView.topAnchor.constraint(equalTo: view.topAnchor),
      sceneView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      sceneView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      sceneView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
    ])
  }

  /// Gives the sphere the geometry of the coverage in use. The elements of a geometry take its materials in turn: the
  /// back of a half sphere, its second element, is drawn with the black material. A raw recording covers the whole
  /// sphere, whatever coverage Flutter gave.
  private func rebuildSphere() {
    let shape: SphereCoverage = isRaw ? .full : coverage
    let sphere = Self.makeSphere(radius: 50, rings: 64, segments: 128, coverage: shape)
    switch shape {
    case .full:
      sphere.materials = [videoMaterial]
    case .half:
      sphere.materials = [videoMaterial, backMaterial]
    }
    sphereNode.geometry = sphere
  }

  /// A sphere made to be seen from its centre, with the whole frame on it and not mirrored: the middle of the frame
  /// straight ahead of a camera at rest (towards -z), the right of the frame to its right (+x), the top row at the
  /// zenith. SCNSphere is not used because where its texture seam falls is not documented. SceneKit texture
  /// coordinates start at the top left corner of the image.
  ///
  /// A full sphere is one element, with the frame all around. A half sphere (VR180) is two: the frame over the front
  /// half only, from 90 degrees on the left to 90 degrees on the right, then the back half, for a plain material.
  private static func makeSphere(radius: Float, rings: Int, segments: Int, coverage: SphereCoverage) -> SCNGeometry {
    // Each band of the sphere: the azimuth where it starts, the azimuth it spans and its number of segments. The
    // azimuth is 0 straight ahead and grows to the right.
    let bands: [(start: Float, span: Float, segments: Int)]
    switch coverage {
    case .full:
      bands = [(start: -Float.pi, span: 2 * Float.pi, segments: segments)]
    case .half:
      let halfSegments = max(segments / 2, 1)
      bands = [
        (start: -Float.pi / 2, span: Float.pi, segments: halfSegments),
        (start: Float.pi / 2, span: Float.pi, segments: halfSegments),
      ]
    }

    var vertices: [SCNVector3] = []
    var textureCoordinates: [CGPoint] = []
    var elements: [SCNGeometryElement] = []
    for band in bands {
      // The indices of the band count from its first vertex
      let firstVertex = UInt32(vertices.count)
      for ring in 0...rings {
        let v = Float(ring) / Float(rings)
        // 0 at the zenith, pi at the nadir
        let polar = v * Float.pi
        let y = radius * cos(polar)
        let ringRadius = radius * sin(polar)
        for segment in 0...band.segments {
          let u = Float(segment) / Float(band.segments)
          let azimuth = band.start + u * band.span
          let x = ringRadius * sin(azimuth)
          let z = -ringRadius * cos(azimuth)
          vertices.append(SCNVector3(x: x, y: y, z: z))
          textureCoordinates.append(CGPoint(x: CGFloat(u), y: CGFloat(v)))
        }
      }

      var indices: [UInt32] = []
      indices.reserveCapacity(rings * band.segments * 6)
      let columns = UInt32(band.segments + 1)
      for ring in 0..<UInt32(rings) {
        for segment in 0..<UInt32(band.segments) {
          let topLeft = firstVertex + ring * columns + segment
          let topRight = topLeft + 1
          let bottomLeft = topLeft + columns
          let bottomRight = bottomLeft + 1
          indices.append(contentsOf: [topLeft, bottomLeft, topRight, topRight, bottomLeft, bottomRight])
        }
      }
      elements.append(SCNGeometryElement(indices: indices, primitiveType: .triangles))
    }

    return SCNGeometry(
      sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(textureCoordinates: textureCoordinates)],
      elements: elements
    )
  }

  // MARK: - Stitched raw video

  /// Builds the stitched item of [attempt] and plays it, or moves to the next source when it cannot be built. While it
  /// is built the spinner turns and the player keeps no item.
  private func startStitch(_ attempt: StitchAttempt) {
    guard let stitched, !closing, !failed else { return }
    stitchAttempt = attempt
    stitchAttemptsTried.append(attempt)
    valveUsed = false
    stitchFrameWatch = nil
    preparingStitch = true
    stitchGeneration += 1
    let generation = stitchGeneration
    playbackStateChanged()
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        let built = try await self.buildStitchItem(attempt, spec: stitched.spec, geometry: stitched.geometry)
        guard generation == self.stitchGeneration, !self.closing, !self.failed else { return }
        self.preparingStitch = false
        if case .original = attempt, let next = self.heavyStitchFallback(built) {
          self.switchStitch(to: next, because: "above what the decoder keeps up with", format: built.formats.first)
          return
        }
        self.stitchItem = built
        if built.mode == .composition && attempt == .original(composition: false) {
          // The builder fell back to the composition by itself (a disabled lens track, or lens tracks in one
          // alternate group): a failure of this item must not try the composition again
          self.stitchAttempt = .original(composition: true)
        }
        let size = built.renderSizes[0]
        print(
          "RawStitch: \(built.mode.rawValue), \(built.sourceTrackIDs.count) source(s), "
            + "output \(Int(size.width))x\(Int(size.height))")
        self.install(built.item)
        // A switch resumes once the item is ready (see itemReady); not in the background, which pauses the playback
        if self.pendingResume == nil && self.playRequested && self.started
          && UIApplication.shared.applicationState != .background
        {
          self.player.play()
        }
        self.playbackStateChanged()
      } catch {
        guard generation == self.stitchGeneration, !self.closing else { return }
        self.preparingStitch = false
        self.stitchFailed("\(error)")
      }
    }
  }

  /// The item of [attempt]: the original file (and the second one of a pair), or the server's transcoded streams
  private func buildStitchItem(_ attempt: StitchAttempt, spec: RawStitchSpec, geometry: RawStitchGeometry) async throws
    -> RawStitchItem
  {
    let mainUrl: URL
    let secondUrl: URL?
    let allowDirect: Bool
    switch attempt {
    case .original(let composition):
      mainUrl = videoUrl
      secondUrl = spec.secondUrl.flatMap { URL(string: $0) }
      allowDirect = !composition
    case .transcoded:
      guard let fallbackUrl else {
        throw RawStitchError(reason: "no transcoded stream")
      }
      mainUrl = fallbackUrl
      secondUrl = secondFallbackUrl(spec)
      allowDirect = true
    }
    if spec.layout == .twoFiles && secondUrl == nil {
      throw RawStitchError(reason: "the second file of the pair has no URL")
    }
    let built = try await RawStitchItemBuilder.build(
      geometry: geometry,
      mainAsset: makeAsset(for: mainUrl),
      secondAsset: spec.layout == .twoFiles ? secondUrl.map { makeAsset(for: $0) } : nil,
      allowDirect: allowDirect
    )
    if !mainUrl.isFileURL {
      // Read over HTTP, as in loadItem
      built.item.preferredForwardBufferDuration = Self.streamingForwardBufferDuration
    }
    return built
  }

  /// The transcoded stream of the second file of a pair, nil when there is none or it is the original itself
  private func secondFallbackUrl(_ spec: RawStitchSpec) -> URL? {
    guard let url = spec.secondFallbackUrl.flatMap({ URL(string: $0) }) else { return nil }
    if let second = spec.secondUrl.flatMap({ URL(string: $0) }), second == url {
      return nil
    }
    return url
  }

  /// Whether the server's transcoded streams keep the lenses: a side by side frame keeps both, each file of a pair
  /// keeps its own; the server transcodes one video track of a file, so one lens of the other layouts
  private func canPlayTranscoded(_ spec: RawStitchSpec) -> Bool {
    guard fallbackUrl != nil, !stitchAttemptsTried.contains(.transcoded) else { return false }
    switch spec.layout {
    case .sideBySide:
      return true
    case .twoFiles:
      return secondFallbackUrl(spec) != nil
    case .twoTracks:
      return false
    }
  }

  /// The source to play instead of the original when its lens tracks are above what the decoder keeps up with, nil to
  /// play it anyway (with a message for two streams, once per opening)
  private func heavyStitchFallback(_ built: RawStitchItem) -> StitchAttempt? {
    guard let stitched else { return nil }
    let verdict = VideoDecoderSupport.verdict(forLensFormats: built.formats, frameRate: built.frameRate)
    guard !verdict.supported else { return nil }
    let reason = verdict.reason ?? "above what this device decodes"
    if canPlayTranscoded(stitched.spec) {
      print("RawStitch: the original is too heavy, the transcoded streams play: \(reason)")
      return .transcoded
    }
    print("RawStitch: the raw video may not play smoothly: \(reason)")
    if built.formats.count == 2 && !heavyNoticeShown {
      heavyNoticeShown = true
      let template = stereoText(
        "rawHeavy",
        fallback: "This raw video may not play smoothly on this device ({codec}, two {width}x{height} streams)")
      showMessage(VideoDecoderSupport.switchedMessage(template, format: built.formats.first))
    }
    return nil
  }

  /// A source of the stitched video failed (its item could not be built, AVFoundation failed it, or a lens track
  /// stays without frames): the next source plays from where it stopped, the error label shows after the last one
  private func stitchFailed(_ reason: String) {
    guard let stitched, let attempt = stitchAttempt, !preparingStitch, !failed, !closing else { return }
    print("RawStitch: \(attempt) failed: \(reason)")
    if attempt == .original(composition: false) && stitched.spec.layout == .twoTracks {
      switchStitch(to: .original(composition: true), because: reason, format: nil)
    } else if canPlayTranscoded(stitched.spec) {
      switchStitch(to: .transcoded, because: reason, format: nil)
    } else {
      showError(reason)
    }
  }

  /// Leaves the item in use for [next], keeping the position and the state the user left it in (playing or paused)
  private func switchStitch(to next: StitchAttempt, because reason: String, format: CMFormatDescription?) {
    print("RawStitch: switching to \(next): \(reason)")
    let position = player.currentTime()
    let resumeTime: CMTime? = position.isNumeric && position.seconds > 0 ? position : nil
    pendingResume = (time: resumeTime, play: playRequested)
    player.pause()
    reachedEnd = false
    // The next source may have other audio tracks: they are read again once it is ready
    audioTracksRequested = false
    audioButton.isHidden = true
    // A late failure of the item left behind must not move to yet another source
    detachItem()
    player.replaceCurrentItem(with: nil)
    stitchItem = nil
    if next == .transcoded {
      showMessage(
        VideoDecoderSupport.switchedMessage(
          stereoText("sourceSwitched", fallback: "Playing the transcoded stream"), format: format))
    }
    startStitch(next)
  }

  /// Direct mode: a lens track the item leaves disabled is enabled, so that the player decodes it for the compositor.
  /// A track the file marks disabled (the second lens of an Osmo 360 .OSV) already goes through the composition, see
  /// RawStitchItemBuilder.
  private func enableLensTracks() {
    guard let stitchItem, stitchItem.mode == .direct, let item = player.currentItem, item === stitchItem.item else {
      return
    }
    for track in item.tracks {
      guard let trackId = track.assetTrack?.trackID, stitchItem.sourceTrackIDs.contains(trackId), !track.isEnabled
      else {
        continue
      }
      track.isEnabled = true
      print("RawStitch: enabled lens track \(trackId)")
    }
  }

  /// Once a second while a stitched video is shown: an item that renders no frame, or a lens track without frames in
  /// direct mode, moves to the next source; while it plays, a GPU slower than the frame rate lowers the render size
  /// once
  private func pollStitchStatistics(_ now: CFTimeInterval) {
    guard stitched != nil, !preparingStitch, !failed, !closing, now - lastStatisticsPoll >= 1 else { return }
    lastStatisticsPoll = now
    guard let stitchItem, let item = player.currentItem, item === stitchItem.item else {
      stitchFrameWatch = nil
      return
    }
    let compositor = item.customVideoCompositor as? RawStitchCompositor
    // Before AVFoundation makes the compositor, no frame was rendered either
    let snapshot =
      compositor?.statistics.snapshot()
      ?? RawStitchStatistics.Snapshot(frames: 0, meanGpuMs: 0, missingSourceStreak: 0)
    if stitchProducesNoFrame(item, frames: snapshot.frames, now: now) {
      stitchFailed("no stitched frame")
      return
    }
    if stitchItem.mode == .direct && stitchItem.sourceTrackIDs.count == 2 && snapshot.missingSourceStreak >= 45 {
      stitchFailed("a lens track is not decoded")
      return
    }
    guard player.timeControlStatus == .playing, !valveUsed, snapshot.frames >= 90, stitchItem.renderSizes.count > 1
    else {
      return
    }
    // The nominal frame rate, as for the render sizes: the composition's frame duration may be shorter
    let frameMs = 1000 / Double(stitchItem.frameRate)
    guard frameMs.isFinite, frameMs > 0, snapshot.meanGpuMs > 0.85 * frameMs else { return }
    valveUsed = true
    let smaller = stitchItem.renderSizes[1]
    item.videoComposition = RawStitchItemBuilder.videoComposition(
      instruction: stitchItem.instruction, renderSize: smaller, frameDuration: stitchItem.frameDuration)
    compositor?.statistics.reset()
    stitchFrameWatch = nil
    print(
      "RawStitch: GPU \(String(format: "%.1f", snapshot.meanGpuMs)) ms per frame, render size lowered to "
        + "\(Int(smaller.width))x\(Int(smaller.height))")
  }

  /// Seconds the player may try to play a stitched item without a new frame from the compositor
  private static let stitchFrameTimeout: CFTimeInterval = 4.5

  /// Whether the player has tried to play [item] for stitchFrameTimeout seconds while the compositor's frame count
  /// ([frames]) stayed the same: a lens track AVFoundation never decodes, or SceneKit never pulling the composed
  /// frames, leaves the spinner or a black sphere with the player waiting or even playing. The clock only runs while
  /// the item is ready, the user wants it to play and the player does (not paused by the user, the end or the
  /// background), the app is in the foreground and enough media is loaded, so that a slow network is not taken for a
  /// failure.
  private func stitchProducesNoFrame(_ item: AVPlayerItem, frames: Int, now: CFTimeInterval) -> Bool {
    let trying =
      item.status == .readyToPlay && pendingResume == nil && playRequested && !reachedEnd
      && player.timeControlStatus != .paused && UIApplication.shared.applicationState == .active
      && (item.isPlaybackLikelyToKeepUp || item.isPlaybackBufferFull)
    guard trying else {
      stitchFrameWatch = nil
      return false
    }
    guard let watch = stitchFrameWatch, watch.frames == frames else {
      stitchFrameWatch = (frames: frames, since: now)
      return false
    }
    return now - watch.since >= Self.stitchFrameTimeout
  }

  // MARK: - Raw dual fisheye

  /// Stitches the two fisheye circles of a raw frame on the sphere: the player stays as it is (the geometry, the
  /// player as the diffuse contents), and a surface shader modifier picks, for every pixel, the point of the frame each
  /// lens sees in its direction (see [dualFisheyeShader]). The calibration becomes the arguments of the modifier.
  private func applyDualFisheye(_ calibration: DualFisheyeCalibration) {
    // The modifier first, so that the material observes the keys of its arguments
    videoMaterial.shaderModifiers = [.surface: Self.dualFisheyeShader]
    let leveling = calibration.levelingMatrix
    for index in 0..<2 {
      // From the view to the lens: G levels the view in the body frame, R_i turns the body into the lens. The
      // columns of the transpose are the rows of the product.
      let rows = (calibration.lensRotation(index) * leveling).transpose
      setShaderArgument("rawLens\(index)Row0", Self.vector4(rows.columns.0))
      setShaderArgument("rawLens\(index)Row1", Self.vector4(rows.columns.1))
      setShaderArgument("rawLens\(index)Row2", Self.vector4(rows.columns.2))
      setShaderArgument("rawLens\(index)Projection", calibration.textureProjection(index))
      let lens = calibration.lenses[index]
      setShaderArgument("rawLens\(index)Distortion", SIMD4<Float>(lens.k1, lens.k2, lens.k3, lens.xi ?? 0))
    }
    let lenses = calibration.lenses
    setShaderArgument("rawTangential", SIMD4<Float>(lenses[0].p1, lenses[0].p2, lenses[1].p1, lenses[1].p2))
    let equidistant: Float = calibration.model == .equidistant ? 1 : 0
    setShaderArgument("rawSettings", SIMD4<Float>(equidistant, calibration.squareWidth, 0, 0))
    print("The 360° player stitches a dual fisheye frame, \(calibration.model.rawValue) lens model")
  }

  /// Every argument of the modifier is a float4, which SceneKit binds from an NSValue of an SCNVector4
  private func setShaderArgument(_ key: String, _ value: SIMD4<Float>) {
    let vector = SCNVector4(x: value.x, y: value.y, z: value.z, w: value.w)
    videoMaterial.setValue(NSValue(scnVector4: vector), forKey: key)
  }

  private static func vector4(_ vector: SIMD3<Float>) -> SIMD4<Float> {
    SIMD4<Float>(vector.x, vector.y, vector.z, 0)
  }

  /// The shader maps the calibration on the proportions of the frame it was written for (the fallback stream may be
  /// smaller, not of other proportions): another shape is not the recording the calibration describes, and the log
  /// tells why the stitch then looks wrong
  private func checkDualFisheyeFrame(_ size: CGSize, calibration: DualFisheyeCalibration) {
    let expected = CGFloat(calibration.frameWidth / calibration.frameHeight)
    let ratio = size.width / size.height
    if abs(ratio - expected) > expected * 0.01 {
      print(
        "The dual fisheye frame is \(Int(size.width))x\(Int(size.height)), the calibration was written for "
          + "\(Int(calibration.frameWidth))x\(Int(calibration.frameHeight))"
      )
    }
  }

  /// The surface shader modifier (Metal) of a raw dual fisheye frame, after docs 16-dual-fisheye-spec.md section 3.
  ///
  /// The texture coordinates of the sphere are those of an equirectangular frame (see makeSphere), and the contents
  /// transform stays the identity for a raw frame: they give the direction a pixel shows, in the axes of the spec (x
  /// right, y down, z ahead), exactly where an equirectangular video would show it. For each lens, the direction turns
  /// into the frame of the lens, goes through the Mei projection (or the equidistant one) and lands in the frame, in
  /// texture coordinates from its top left corner, as the frame of the player has them. A lens counts only within its
  /// own square and up to 100 degrees off axis; the two samples blend across the seam, from 85 to 95 degrees off axis
  /// (1 - smoothstep). Where neither lens has a weight, the lens nearer the direction gives the pixel. The samples read
  /// the first level of the texture: the point jumps from one lens to the other at the seam, where the derivatives
  /// would pick a blurred level.
  ///
  /// Arguments, all float4, set by setShaderArgument:
  /// - rawLens0Row0, rawLens0Row1, rawLens0Row2 (and rawLens1...): the rows of R_i * G, from the view to lens i, w
  ///   unused. Rows rather than a float3x3 argument, so that no matrix layout convention stands between Swift and
  ///   Metal: the shader takes dot products.
  /// - rawLens0Projection, rawLens1Projection: (fx, fy, cx, cy) in texture coordinates, see
  ///   DualFisheyeCalibration.textureProjection.
  /// - rawLens0Distortion, rawLens1Distortion: (k1, k2, k3, xi), Mei only.
  /// - rawTangential: (p1, p2) of lens 0, then (p1, p2) of lens 1, Mei only.
  /// - rawSettings: (1 for the equidistant model, 0 for Mei; the width of one lens square in texture coordinates;
  ///   unused; unused).
  ///
  /// The body sits in its own block, so that its names cannot clash with those of the code SceneKit puts around it.
  /// The arguments section holds declarations only: SceneKit reads it line by line.
  private static let dualFisheyeShader = """
    #pragma arguments
    float4 rawLens0Row0;
    float4 rawLens0Row1;
    float4 rawLens0Row2;
    float4 rawLens1Row0;
    float4 rawLens1Row1;
    float4 rawLens1Row2;
    float4 rawLens0Projection;
    float4 rawLens1Projection;
    float4 rawLens0Distortion;
    float4 rawLens1Distortion;
    float4 rawTangential;
    float4 rawSettings;
    #pragma body
    {
      float2 sphereUv = _surface.diffuseTexcoord;
      float longitude = (sphereUv.x * 2.0 - 1.0) * M_PI_F;
      float latitude = M_PI_2_F - sphereUv.y * M_PI_F;
      float3 viewDirection = float3(cos(latitude) * sin(longitude), -sin(latitude), cos(latitude) * cos(longitude));
      float4 colorSum = float4(0.0);
      float weightSum = 0.0;
      float nearestAngle = 4.0;
      float2 nearestUv = float2(0.0);
      for (int lensIndex = 0; lensIndex < 2; lensIndex++) {
        bool firstLens = lensIndex == 0;
        float4 row0 = firstLens ? rawLens0Row0 : rawLens1Row0;
        float4 row1 = firstLens ? rawLens0Row1 : rawLens1Row1;
        float4 row2 = firstLens ? rawLens0Row2 : rawLens1Row2;
        float3 lensDirection = normalize(
          float3(dot(row0.xyz, viewDirection), dot(row1.xyz, viewDirection), dot(row2.xyz, viewDirection)));
        float offAxis = acos(clamp(lensDirection.z, -1.0f, 1.0f));
        float2 lensPoint;
        if (rawSettings.x > 0.5) {
          float planar = length(lensDirection.xy);
          lensPoint = planar > 0.000001 ? lensDirection.xy * (offAxis / planar) : float2(0.0);
        } else {
          float4 distortion = firstLens ? rawLens0Distortion : rawLens1Distortion;
          float2 tangential = firstLens ? rawTangential.xy : rawTangential.zw;
          float2 unified = lensDirection.xy / max(lensDirection.z + distortion.w, 0.001f);
          float r2 = dot(unified, unified);
          float radial = 1.0 + r2 * (distortion.x + r2 * (distortion.y + r2 * distortion.z));
          lensPoint = float2(
            radial * unified.x + 2.0 * tangential.x * unified.x * unified.y
              + tangential.y * (r2 + 2.0 * unified.x * unified.x),
            radial * unified.y + tangential.x * (r2 + 2.0 * unified.y * unified.y)
              + 2.0 * tangential.y * unified.x * unified.y);
        }
        float4 projection = firstLens ? rawLens0Projection : rawLens1Projection;
        float2 lensUv = projection.xy * lensPoint + projection.zw;
        float squareStart = float(lensIndex) * rawSettings.y;
        float squareEnd = squareStart + rawSettings.y;
        bool inSquare = lensUv.x >= squareStart && lensUv.x < squareEnd && lensUv.y >= 0.0 && lensUv.y < 1.0;
        float weight = (inSquare && offAxis < 1.7453293) ? 1.0 - smoothstep(1.4835299f, 1.6580628f, offAxis) : 0.0;
        if (weight > 0.0) {
          colorSum += weight * float4(u_diffuseTexture.sample(u_diffuseTextureSampler, lensUv, metal::level(0.0f)));
          weightSum += weight;
        }
        if (offAxis < nearestAngle) {
          nearestAngle = offAxis;
          nearestUv = clamp(lensUv, float2(squareStart, 0.0f), float2(squareEnd, 1.0f));
        }
      }
      if (weightSum > 0.0) {
        _surface.diffuse = colorSum / weightSum;
      } else {
        _surface.diffuse = float4(u_diffuseTexture.sample(u_diffuseTextureSampler, nearestUv, metal::level(0.0f)));
      }
    }
    """

  // MARK: - View direction

  private func updateCamera() {
    guard !motionEnabled else { return }
    cameraNode.simdOrientation = simd_quatf(angle: yaw, axis: yAxis) * simd_quatf(angle: pitch, axis: xAxis)
  }

  private func startMotion() {
    guard motionManager.isDeviceMotionAvailable else { return }
    alignHeadingOnNextMotion = true
    staleMotionTimestamp = motionManager.deviceMotion?.timestamp
    motionManager.deviceMotionUpdateInterval = 1.0 / 60.0
    // The magnetometer corrects the drift of the heading, where there is one
    let corrected = CMMotionManager.availableAttitudeReferenceFrames().contains(.xArbitraryCorrectedZVertical)
    motionManager.startDeviceMotionUpdates(using: corrected ? .xArbitraryCorrectedZVertical : .xArbitraryZVertical)
  }

  /// Called on every screen refresh: turns the camera with the latest attitude of the phone
  @objc private func step(_ link: CADisplayLink) {
    pollStitchStatistics(link.timestamp)
    guard motionEnabled, let motion = motionManager.deviceMotion, motion.timestamp != staleMotionTimestamp else {
      return
    }
    let sensor = sensorOrientation(motion.attitude.quaternion)
    if alignHeadingOnNextMotion {
      // Keeps the heading of the view: the middle of the video at first, where the drags left it later
      alignHeadingOnNextMotion = false
      yaw -= Self.heading(of: sensor)
    }
    cameraNode.simdOrientation = simd_quatf(angle: yaw, axis: yAxis) * sensor
  }

  /// Camera orientation for an attitude of the phone. CoreMotion's reference frame has z up where SceneKit has y up,
  /// hence the quarter turn around x: the phone held upright looks at the horizon, flat on its back it looks at the
  /// floor. The camera then rolls with the interface so that the top of the screen stays the top of the view.
  private func sensorOrientation(_ attitude: CMQuaternion) -> simd_quatf {
    let device = simd_quatf(ix: Float(attitude.x), iy: Float(attitude.y), iz: Float(attitude.z), r: Float(attitude.w))
    let screen = simd_quatf(angle: Self.screenAngle(screenOrientation), axis: zAxis)
    return Self.zUpToYUp * device * screen
  }

  private static let zUpToYUp = simd_quatf(angle: -Float.pi / 2, axis: xAxis)

  /// Rotation of the interface around the screen normal, from the phone's portrait axes
  private static func screenAngle(_ orientation: UIInterfaceOrientation) -> Float {
    switch orientation {
    case .landscapeLeft:
      return Float.pi / 2
    case .landscapeRight:
      return -Float.pi / 2
    case .portraitUpsideDown:
      return Float.pi
    default:
      return 0
    }
  }

  /// Angle around the vertical axis of where [orientation] looks: 0 towards -z, growing to the left
  private static func heading(of orientation: simd_quatf) -> Float {
    let forward = orientation.act(SIMD3<Float>(0, 0, -1))
    var direction = forward
    if forward.x * forward.x + forward.z * forward.z < 0.01 {
      // Looking straight down, the top of the screen points where the view heads; straight up, away from it
      let up: Float = forward.y < 0 ? 1 : -1
      direction = orientation.act(SIMD3<Float>(0, up, 0))
    }
    return atan2(-direction.x, -direction.z)
  }

  // MARK: - Stereo layout

  /// A phone has one picture for both eyes: a stereoscopic video shows its left eye only, the top half of a top and
  /// bottom frame, the left half of a side by side one. Texture coordinates start at the top left corner of the frame,
  /// so halving them keeps that half, stretched over the whole sphere or over its front half.
  private func applyStereoLayout() {
    // The shader of a raw dual fisheye frame reads the whole frame (see applyDualFisheye), a stitched one is mono
    guard !isRaw else {
      videoMaterial.diffuse.contentsTransform = SCNMatrix4Identity
      return
    }
    switch stereoLayout {
    case .mono:
      videoMaterial.diffuse.contentsTransform = SCNMatrix4Identity
    case .topBottom:
      videoMaterial.diffuse.contentsTransform = SCNMatrix4MakeScale(1, 0.5, 1)
    case .leftRight:
      videoMaterial.diffuse.contentsTransform = SCNMatrix4MakeScale(0.5, 1, 1)
    }
    stereoButton.tintColor = stereoLayout == .mono ? UIColor(white: 1, alpha: 0.4) : UIColor.white
    stereoButton.accessibilityValue = stereoLayoutName(stereoLayout)
  }

  /// AVFoundation does not read the stereo metadata of the file, but the size of the frame tells a stereoscopic video
  /// apart even where Flutter did not know the dimensions
  private func frameSizeKnown(_ size: CGSize) {
    guard !closing else { return }
    frameSize = size
    // A stitched frame is the render size of the composition: nothing to guess
    if stitched != nil {
      return
    }
    if let dualFisheye {
      checkDualFisheyeFrame(size, calibration: dualFisheye)
      return
    }
    guessStereoLayoutFromFrame()
  }

  /// Until the user picks a layout: the stereoscopic layout the shape of the frame tells for the coverage in use, else
  /// the layout Flutter gave. A choice of the user stays.
  private func guessStereoLayoutFromFrame() {
    guard !stereoLayoutChosen, !closing, frameSize.width > 0, frameSize.height > 0 else { return }
    let guess = Self.guessStereoLayout(frameSize, coverage: coverage)
    let layout = guess == .mono ? initialStereoLayout : guess
    guard layout != stereoLayout else { return }
    stereoLayout = layout
    applyStereoLayout()
  }

  /// The guess of Flutter for a full sphere: two 2:1 images one above the other make a square frame, side by side a
  /// 4:1 one. Each eye of a half sphere is square: one above the other they make a 1:2 frame, side by side a 2:1 one.
  private static func guessStereoLayout(_ size: CGSize, coverage: SphereCoverage) -> StereoLayout {
    let ratio = size.width / size.height
    switch coverage {
    case .full:
      if ratio >= 0.9 && ratio <= 1.1 {
        return .topBottom
      }
      if ratio >= 3.6 && ratio <= 4.4 {
        return .leftRight
      }
    case .half:
      if ratio >= 0.45 && ratio <= 0.55 {
        return .topBottom
      }
      if ratio >= 1.8 && ratio <= 2.2 {
        return .leftRight
      }
    }
    return .mono
  }

  private static func nextStereoLayout(after layout: StereoLayout) -> StereoLayout {
    switch layout {
    case .mono:
      return .topBottom
    case .topBottom:
      return .leftRight
    case .leftRight:
      return .mono
    }
  }

  /// A label from Flutter, or its English fallback
  private func stereoText(_ key: String, fallback: String) -> String {
    guard let text = stereoLabels[key], !text.isEmpty else { return fallback }
    return text
  }

  private func stereoLayoutName(_ layout: StereoLayout) -> String {
    switch layout {
    case .mono:
      return stereoText("mono", fallback: "Mono (not 3D)")
    case .topBottom:
      return stereoText("topBottom", fallback: "3D, top and bottom")
    case .leftRight:
      return stereoText("leftRight", fallback: "3D, side by side")
    }
  }

  // MARK: - Coverage

  private func coverageName(_ coverage: SphereCoverage) -> String {
    switch coverage {
    case .full:
      return stereoText("coverage_full", fallback: "360°, full sphere")
    case .half:
      return stereoText("coverage_half", fallback: "180°, half sphere (VR180)")
    }
  }

  /// The button shows the coverage in use, without the fade of a system button
  private func updateCoverageButton() {
    let title = coverage == .half ? "180°" : "360°"
    UIView.performWithoutAnimation {
      self.coverageButton.setTitle(title, for: .normal)
      self.coverageButton.layoutIfNeeded()
    }
    coverageButton.accessibilityValue = coverageName(coverage)
  }

  // MARK: - Gestures

  private func setUpGestures() {
    let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
    let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
    let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
    let recognizers: [UIGestureRecognizer] = [pan, pinch, tap]
    for recognizer in recognizers {
      recognizer.delegate = self
      sceneView.addGestureRecognizer(recognizer)
    }
  }

  // Turning and zooming at once
  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool {
    return !(gestureRecognizer is UITapGestureRecognizer) && !(otherGestureRecognizer is UITapGestureRecognizer)
  }

  @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
    let translation = gesture.translation(in: sceneView)
    gesture.setTranslation(.zero, in: sceneView)
    // The picture follows the finger: a drag to the left turns the view to the right, a drag up turns it down
    let scale = radiansPerPoint * Float(fieldOfView / defaultFieldOfView)
    yaw += Float(translation.x) * scale
    if !motionEnabled {
      pitch = min(max(pitch + Float(translation.y) * scale, -maxPitch), maxPitch)
      updateCamera()
    }
  }

  @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
    switch gesture.state {
    case .began:
      pinchStartFieldOfView = fieldOfView
    case .changed:
      guard gesture.scale > 0 else { return }
      fieldOfView = min(max(pinchStartFieldOfView / gesture.scale, minFieldOfView), maxFieldOfView)
      cameraNode.camera?.fieldOfView = fieldOfView
    default:
      break
    }
  }

  @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
    // The close button stays on screen with an error
    setControlsVisible(!controlsVisible || failed)
  }

  // MARK: - Controls

  private func setUpControls() {
    spinner.color = .white
    spinner.hidesWhenStopped = true
    spinner.translatesAutoresizingMaskIntoConstraints = false
    spinner.startAnimating()
    view.addSubview(spinner)

    errorLabel.text = errorMessage
    errorLabel.textColor = .white
    errorLabel.font = .preferredFont(forTextStyle: .body)
    errorLabel.textAlignment = .center
    errorLabel.numberOfLines = 0
    errorLabel.isHidden = true
    errorLabel.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(errorLabel)

    configure(playPauseButton, symbol: "play.fill", pointSize: 28, action: #selector(playPauseTapped))
    playPauseButton.accessibilityLabel = "Play"
    playPauseButton.backgroundColor = UIColor(white: 0, alpha: 0.45)
    playPauseButton.layer.cornerRadius = 32
    view.addSubview(playPauseButton)

    // Stays on screen when the controls hide
    view.addSubview(bufferingIndicator.view)

    topBar.backgroundColor = UIColor(white: 0, alpha: 0.45)
    topBar.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(topBar)

    configure(closeButton, symbol: "xmark", pointSize: 20, action: #selector(closeTapped))
    closeButton.accessibilityLabel = closeLabel ?? "Close"
    topBar.addSubview(closeButton)

    titleLabel.text = videoTitle
    titleLabel.textColor = .white
    titleLabel.font = .preferredFont(forTextStyle: .headline)
    titleLabel.numberOfLines = 1
    titleLabel.lineBreakMode = .byTruncatingTail
    titleLabel.translatesAutoresizingMaskIntoConstraints = false
    titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    topBar.addSubview(titleLabel)

    // view.3d is in the SF Symbols of iOS 14, the cube is the safety net
    let stereoSymbol = UIImage(systemName: "view.3d") == nil ? "cube" : "view.3d"
    configure(stereoButton, symbol: stereoSymbol, pointSize: 20, action: #selector(stereoTapped))
    stereoButton.accessibilityLabel = stereoText("stereo", fallback: "3D layout")

    configure(motionButton, symbol: "gyroscope", pointSize: 20, action: #selector(motionTapped))
    motionButton.accessibilityLabel = "Gyroscope"

    // A text button, 360° or 180°: see updateCoverageButton
    coverageButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
    coverageButton.tintColor = .white
    coverageButton.translatesAutoresizingMaskIntoConstraints = false
    coverageButton.addTarget(self, action: #selector(coverageTapped), for: .touchUpInside)
    coverageButton.accessibilityLabel = stereoText("coverage", fallback: "Field of view")

    // Opens the menu of the audio tracks; hidden unless the video has a choice of them
    setSymbol(of: audioButton, to: "waveform", pointSize: 20)
    audioButton.tintColor = .white
    audioButton.translatesAutoresizingMaskIntoConstraints = false
    audioButton.accessibilityLabel = audioTracks.buttonLabel
    audioButton.isHidden = true

    // A hidden audio track or gyroscope button gives its room to the title
    let trailingButtons = UIStackView(arrangedSubviews: [audioButton, coverageButton, stereoButton, motionButton])
    trailingButtons.axis = .horizontal
    trailingButtons.translatesAutoresizingMaskIntoConstraints = false
    topBar.addSubview(trailingButtons)

    messageView.backgroundColor = UIColor(white: 0, alpha: 0.6)
    messageView.layer.cornerRadius = 8
    messageView.alpha = 0
    messageView.isUserInteractionEnabled = false
    // VoiceOver reads the message out when it shows
    messageView.accessibilityElementsHidden = true
    messageView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(messageView)

    messageLabel.textColor = .white
    messageLabel.font = .preferredFont(forTextStyle: .subheadline)
    messageLabel.textAlignment = .center
    messageLabel.numberOfLines = 0
    messageLabel.translatesAutoresizingMaskIntoConstraints = false
    messageView.addSubview(messageLabel)

    // Below required, else it fights the zero width the stack view gives the button when it hides
    let motionButtonWidth = motionButton.widthAnchor.constraint(equalToConstant: 44)
    motionButtonWidth.priority = UILayoutPriority(999)
    let audioButtonWidth = audioButton.widthAnchor.constraint(equalToConstant: 44)
    audioButtonWidth.priority = UILayoutPriority(999)
    // These two hide for a raw dual fisheye frame
    let coverageButtonWidth = coverageButton.widthAnchor.constraint(equalToConstant: 52)
    coverageButtonWidth.priority = UILayoutPriority(999)
    let stereoButtonWidth = stereoButton.widthAnchor.constraint(equalToConstant: 44)
    stereoButtonWidth.priority = UILayoutPriority(999)

    let safeArea = view.safeAreaLayoutGuide
    NSLayoutConstraint.activate([
      spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),

      errorLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      errorLabel.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor, constant: 32),
      errorLabel.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor, constant: -32),

      playPauseButton.centerXAnchor.constraint(equalTo: safeArea.centerXAnchor),
      playPauseButton.bottomAnchor.constraint(equalTo: safeArea.bottomAnchor, constant: -24),
      playPauseButton.widthAnchor.constraint(equalToConstant: 64),
      playPauseButton.heightAnchor.constraint(equalToConstant: 64),

      // At the bottom centre, above the play button
      bufferingIndicator.view.centerXAnchor.constraint(equalTo: safeArea.centerXAnchor),
      bufferingIndicator.view.bottomAnchor.constraint(equalTo: playPauseButton.topAnchor, constant: -12),

      // The bar runs under the status bar area, its content stays in the safe area
      topBar.topAnchor.constraint(equalTo: view.topAnchor),
      topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      topBar.bottomAnchor.constraint(equalTo: safeArea.topAnchor, constant: 56),

      closeButton.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor, constant: 8),
      closeButton.bottomAnchor.constraint(equalTo: topBar.bottomAnchor, constant: -6),
      closeButton.widthAnchor.constraint(equalToConstant: 44),
      closeButton.heightAnchor.constraint(equalToConstant: 44),

      trailingButtons.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor, constant: -8),
      trailingButtons.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),

      coverageButtonWidth,
      coverageButton.heightAnchor.constraint(equalToConstant: 44),

      stereoButtonWidth,
      stereoButton.heightAnchor.constraint(equalToConstant: 44),

      motionButtonWidth,
      motionButton.heightAnchor.constraint(equalToConstant: 44),

      audioButtonWidth,
      audioButton.heightAnchor.constraint(equalToConstant: 44),

      titleLabel.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 8),
      titleLabel.trailingAnchor.constraint(equalTo: trailingButtons.leadingAnchor, constant: -8),
      titleLabel.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),

      messageView.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 16),
      messageView.centerXAnchor.constraint(equalTo: safeArea.centerXAnchor),
      messageView.leadingAnchor.constraint(greaterThanOrEqualTo: safeArea.leadingAnchor, constant: 32),
      messageView.trailingAnchor.constraint(lessThanOrEqualTo: safeArea.trailingAnchor, constant: -32),

      messageLabel.topAnchor.constraint(equalTo: messageView.topAnchor, constant: 8),
      messageLabel.bottomAnchor.constraint(equalTo: messageView.bottomAnchor, constant: -8),
      messageLabel.leadingAnchor.constraint(equalTo: messageView.leadingAnchor, constant: 12),
      messageLabel.trailingAnchor.constraint(equalTo: messageView.trailingAnchor, constant: -12),
    ])
  }

  private func configure(_ button: UIButton, symbol: String, pointSize: CGFloat, action: Selector) {
    setSymbol(of: button, to: symbol, pointSize: pointSize)
    button.tintColor = .white
    button.translatesAutoresizingMaskIntoConstraints = false
    button.addTarget(self, action: action, for: .touchUpInside)
  }

  private func setSymbol(of button: UIButton, to symbol: String, pointSize: CGFloat) {
    let configuration = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
    button.setImage(UIImage(systemName: symbol, withConfiguration: configuration), for: .normal)
  }

  private func updateMotionButton() {
    motionButton.tintColor = motionEnabled ? UIColor.white : UIColor(white: 1, alpha: 0.4)
    motionButton.accessibilityValue = motionEnabled ? "On" : "Off"
  }

  private func setControlsVisible(_ visible: Bool) {
    NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(hideControls), object: nil)
    controlsVisible = visible
    UIView.animate(withDuration: 0.2) {
      self.topBar.alpha = visible ? 1 : 0
      self.playPauseButton.alpha = visible ? 1 : 0
    }
    setNeedsUpdateOfHomeIndicatorAutoHidden()
    if visible {
      scheduleControlsHiding()
    }
  }

  private func scheduleControlsHiding() {
    NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(hideControls), object: nil)
    // VoiceOver users keep the controls on screen
    if player.timeControlStatus == .playing && !failed && !closing && !UIAccessibility.isVoiceOverRunning {
      perform(#selector(hideControls), with: nil, afterDelay: controlsHideDelay)
    }
  }

  @objc private func hideControls() {
    setControlsVisible(false)
  }

  /// Shows [text] under the top bar for a moment
  private func showMessage(_ text: String) {
    NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(hideMessage), object: nil)
    messageLabel.text = text
    UIView.animate(withDuration: 0.2) {
      self.messageView.alpha = 1
    }
    perform(#selector(hideMessage), with: nil, afterDelay: messageDuration)
    UIAccessibility.post(notification: .announcement, argument: text)
  }

  @objc private func hideMessage() {
    UIView.animate(withDuration: 0.3) {
      self.messageView.alpha = 0
    }
  }

  @objc private func closeTapped() {
    stop()
    dismiss(animated: true)
  }

  @objc private func playPauseTapped() {
    if player.timeControlStatus == .paused {
      if reachedEnd {
        reachedEnd = false
        player.seek(to: .zero)
      }
      playRequested = true
      player.play()
    } else {
      playRequested = false
      player.pause()
    }
  }

  @objc private func motionTapped() {
    if motionEnabled {
      // The drags carry on from where the motion left the view
      let orientation = cameraNode.simdOrientation
      let forward = orientation.act(SIMD3<Float>(0, 0, -1))
      yaw = Self.heading(of: orientation)
      pitch = min(max(asin(min(max(forward.y, -1), 1)), -maxPitch), maxPitch)
      motionEnabled = false
      motionManager.stopDeviceMotionUpdates()
      updateCamera()
    } else {
      motionEnabled = true
      startMotion()
    }
    updateMotionButton()
    scheduleControlsHiding()
  }

  @objc private func stereoTapped() {
    stereoLayoutChosen = true
    stereoLayout = Self.nextStereoLayout(after: stereoLayout)
    applyStereoLayout()
    showMessage(stereoLayoutName(stereoLayout))
    scheduleControlsHiding()
  }

  /// Switches between the whole sphere and its front half, at once
  @objc private func coverageTapped() {
    coverage = coverage == .full ? .half : .full
    rebuildSphere()
    updateCoverageButton()
    // The shape of the frame may tell another stereo layout for the new coverage
    guessStereoLayoutFromFrame()
    showMessage(coverageName(coverage))
    scheduleControlsHiding()
  }
}
