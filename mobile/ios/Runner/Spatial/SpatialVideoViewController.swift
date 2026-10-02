import AVFoundation
import CoreMotion
import CoreVideo
import Metal
import MetalKit
import UIKit
import native_video_player
import simd

private let defaultFieldOfView: Float = 80
private let minFieldOfView: Float = 50
private let maxFieldOfView: Float = 100
private let maxPitch: Float = 85 * Float.pi / 180
// Drag speed at the default field of view, slower when zoomed in
private let radiansPerPoint: Float = 0.12 * Float.pi / 180
private let controlsHideDelay: TimeInterval = 3
private let messageDuration: TimeInterval = 2
private let longMessageDuration: TimeInterval = 3
private let defaultSensitivity: Float = 2.0
// Turning the phone to look around a 360 degree video also moves the face in the front camera, which would throw the
// viewpoint to one side. A change of the motion attitude above this angle between two readings counts as a turn:
// the viewpoint holds still, and once the phone has been steady for the settle delay the face becomes the new centre
private let turnMoveRadians: Float = 0.15 * Float.pi / 180
private let turnSettleDelay: CFTimeInterval = 0.4
private let xAxis = SIMD3<Float>(1, 0, 0)
private let yAxis = SIMD3<Float>(0, 1, 0)
private let zAxis = SIMD3<Float>(0, 0, 1)

/// Whether the head drives the viewpoint
private enum HeadTracking {
  /// Before the camera permission is known
  case waiting
  case active
  /// The camera permission was refused: the manual viewpoint slider takes over
  case denied
  /// No usable front camera: the slider takes over as well
  case unavailable
}

/// The experimental Spatial 2.5D player: a stereoscopic video shown on the flat screen as a window on the scene. The
/// front camera follows the user's head, and the picture is synthesised, on the GPU, from the viewpoint between the
/// two eyes of the video that matches the head (see SpatialRenderer). Landscape only, like the 360 degree player.
///
/// The controls hide on their own after 3 seconds of playback, a tap on the video shows or hides them. A swipe down
/// closes a flat video; 360 degree videos turn with drags, the motion of the phone, and zoom with a pinch. Their
/// coverage button (360° or 180°) tells whether they cover the whole sphere or only its front half, as VR180 videos
/// do. A video with several audio tracks (languages, commentary) shows an audio track button, see
/// [AudioTrackChooser]. Flutter hears about the close through [SpatialVideoEvents], with the position, so that its
/// normal player resumes there, and with the layout and the projection shown last.
final class SpatialVideoViewController: UIViewController, MTKViewDelegate, UIGestureRecognizerDelegate {
  private let videoUrl: URL
  private let headers: [String: String]
  private let videoTitle: String
  // A flat video stays flat; a 360 degree one switches between the full sphere and its front half with the coverage
  // button
  private var projection: SpatialProjection
  private let startPositionMs: Int64
  private let autoplay: Bool
  private let debugOverlay: Bool
  private let labels: [String: String]
  private let events: SpatialVideoEvents
  private let audioTracks: AudioTrackChooser

  private let player = AVPlayer()
  private var videoOutput: AVPlayerItemVideoOutput?
  private var metalView: MTKView?
  private var renderer: SpatialRenderer?
  private var textureCache: CVMetalTextureCache?
  // The latest video frame, drawn again while no new one comes
  private var currentFrame: CVMetalTexture?
  // When the texture cache last let go of the textures no frame uses any more
  private var lastCacheFlush: CFTimeInterval = 0
  // Without Metal, the left eye through an AVPlayerLayer, cropped by its container
  private var fallbackContainer: UIView?
  private var fallbackLayer: AVPlayerLayer?
  // The view under the controls: the Metal view or the fallback container
  private let surface = UIView()

  private let headTracker = HeadTracker()
  private var viewpoint = HeadViewpoint()
  private var headTracking = HeadTracking.waiting
  // The debug slider moved: it drives the viewpoint until Recenter
  private var manualViewpoint = false
  private var lastViewpoint: Double = 0.5
  private var trackingLostShown = false

  private let motionManager = CMMotionManager()
  private var statusObservation: NSKeyValueObservation?
  private var timeControlObservation: NSKeyValueObservation?
  private var presentationSizeObservation: NSKeyValueObservation?
  private var timeObserver: Any?
  private var statsTimer: Timer?

  // What the layout menu shows (auto included), and the layout in use
  private var selectedLayout: SpatialStereoLayout
  private var resolvedLayout: SpatialStereoLayout = .sideBySide
  private var presentationSize = CGSize.zero
  // An Apple spatial video (MV-HEVC, iPhone 15 Pro and later, Vision Pro): its frame holds one eye only
  private var isMultiview = false

  // 360 degree videos, as in SphericalVideoViewController: yaw grows to the left, pitch upwards (drags only)
  private var yaw: Float = 0
  private var pitch: Float = 0
  private var fieldOfView = defaultFieldOfView
  private var pinchStartFieldOfView = defaultFieldOfView
  private var motionEnabled = false
  private var attitude: simd_quatf?
  // The phone is turning: the head viewpoint holds until the turn ends (see turnMoveRadians)
  private var viewTurning = false
  private var lastTurnMove: CFTimeInterval = 0
  private var lastSensorAttitude: simd_quatf?
  private var staleMotionTimestamp: TimeInterval?
  private var alignHeadingOnNextMotion = false
  private var screenOrientation = UIInterfaceOrientation.landscapeRight

  private let topBar = UIView()
  private let closeButton = UIButton(type: .system)
  private let titleLabel = UILabel()
  private let coverageButton = UIButton(type: .system)
  private let layoutButton = UIButton(type: .system)
  private let audioButton = UIButton(type: .system)
  private let recenterButton = UIButton(type: .system)
  private let disparityButton = UIButton(type: .system)
  private let bottomBar = UIView()
  private let playPauseButton = UIButton(type: .system)
  private let currentTimeLabel = UILabel()
  private let seekSlider = UISlider()
  private let durationLabel = UILabel()
  private let sensitivityLabel = UILabel()
  private let sensitivitySlider = UISlider()
  private let viewpointSlider = UISlider()
  private let statsLabel = UILabel()
  private let spinner = UIActivityIndicatorView(style: .large)
  private let errorLabel = UILabel()
  private let messageView = UIView()
  private let messageLabel = UILabel()
  private let trackingView = UIView()
  private let trackingLabel = UILabel()

  private var controlsVisible = true
  private var failed = false
  private var reachedEnd = false
  private var started = false
  private var readyHandled = false
  private var playbackStarted = false
  private var scrubbing = false
  private var closing = false
  private var idleTimerWasDisabled = false
  // Where playback was when the player stopped, sent to Flutter once the audio session is dealt with
  private var closeState: (positionMs: Int64, wasPlaying: Bool)?
  private var closedReported = false
  private var audioTracksRequested = false

  /// [request] carries the translated labels, English is the fallback. [events] is told once when the player closes.
  init(url: URL, request: SpatialOpenRequest, events: SpatialVideoEvents) {
    videoUrl = url
    headers = request.headers
    videoTitle = request.title
    projection = request.projection
    startPositionMs = max(request.startPositionMs, 0)
    autoplay = request.autoplay
    debugOverlay = request.debugOverlay
    labels = request.labels
    selectedLayout = request.layout
    self.events = events
    audioTracks = AudioTrackChooser(labels: request.labels)
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

  // Landscape only, like the 360 degree player: the two eyes of a video are seen best across the long side
  override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }

  // The landscape side the phone already leans to. UIDeviceOrientation and UIInterfaceOrientation name the
  // landscape sides the other way round.
  override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
    UIDevice.current.orientation == .landscapeRight ? .landscapeLeft : .landscapeRight
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
    view.accessibilityLabel = text("spatial", "Spatial 2.5D")
    resolvedLayout = resolveLayout()
    setUpRendering()
    setUpPlayer()
    setUpControls()
    setUpGestures()
    applyLayout()
    updateViewpointControls()

    if isSpherical {
      motionEnabled = motionManager.isDeviceMotionAvailable
    }

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
    if debugOverlay {
      statsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.updateStats()
        }
      }
    }
    // The item may have become ready before the player showed: the spinner, the play button and the idle timer
    // follow the playback state from now on
    playbackStateChanged()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard !closing, headTracking == .waiting else { return }
    // The camera permission is asked here, when the player is on screen, not at app start
    startHeadTracking()
    if renderer?.stats().stereoAvailable != true {
      showMessage(text("unavailable", "Spatial 2.5D is not available on this device"), duration: longMessageDuration)
    }
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    stop()
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    // Frees the decoder, the buffered video, the camera and the GPU textures
    statusObservation?.invalidate()
    timeControlObservation?.invalidate()
    presentationSizeObservation?.invalidate()
    if let timeObserver {
      player.removeTimeObserver(timeObserver)
      self.timeObserver = nil
    }
    if let item = player.currentItem, let videoOutput {
      item.remove(videoOutput)
    }
    videoOutput = nil
    player.replaceCurrentItem(with: nil)
    fallbackLayer?.player = nil
    metalView?.isPaused = true
    metalView?.delegate = nil
    metalView?.releaseDrawables()
    currentFrame = nil
    if let textureCache {
      CVMetalTextureCacheFlush(textureCache, 0)
    }
    textureCache = nil
    renderer = nil
    // Lets the music the video interrupted resume, before Flutter hears about the close: a deactivation once the
    // Flutter player plays again would stop it. When Flutter is about to resume playback, the session stays active
    // for it, so that the interrupted app does not start again over the video.
    if closeState?.wasPlaying != true {
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    reportClosed()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    if let orientation = view.window?.windowScene?.interfaceOrientation, orientation != .unknown,
      orientation != screenOrientation
    {
      screenOrientation = orientation
      // The head position flips with the interface: it is measured again from the middle
      headTracker.setInterfaceOrientation(orientation)
      if headTracking == .active {
        viewpoint.recenter(now: CACurrentMediaTime())
      }
    }
    layoutFallback()
  }

  // MARK: - Rendering

  private func setUpRendering() {
    surface.backgroundColor = .black
    surface.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(surface)
    NSLayoutConstraint.activate([
      surface.topAnchor.constraint(equalTo: view.topAnchor),
      surface.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      surface.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      surface.trailingAnchor.constraint(equalTo: view.trailingAnchor),
    ])

    guard let device = MTLCreateSystemDefaultDevice() else {
      setUpFallback("no Metal device")
      return
    }
    let metalView = MTKView(frame: .zero, device: device)
    metalView.colorPixelFormat = .bgra8Unorm
    guard let renderer = SpatialRenderer(device: device, pixelFormat: metalView.colorPixelFormat) else {
      setUpFallback("the renderer cannot start")
      return
    }
    var cache: CVMetalTextureCache?
    guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
      let cache
    else {
      setUpFallback("no texture cache")
      return
    }

    metalView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    metalView.preferredFramesPerSecond = 60
    metalView.enableSetNeedsDisplay = false
    metalView.isPaused = false
    metalView.framebufferOnly = true
    // Two pixels per point are sharper than any video eye on a phone, and less than half the pixels of a 3x screen
    let screenScale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 2
    metalView.contentScaleFactor = min(screenScale, 2)
    metalView.backgroundColor = .black
    metalView.delegate = self
    metalView.translatesAutoresizingMaskIntoConstraints = false
    surface.addSubview(metalView)
    NSLayoutConstraint.activate([
      metalView.topAnchor.constraint(equalTo: surface.topAnchor),
      metalView.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
      metalView.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
      metalView.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
    ])

    renderer.projection = projection
    renderer.fov = fieldOfView
    self.metalView = metalView
    self.renderer = renderer
    textureCache = cache
  }

  /// The last resort, never a black screen: the left eye of the video through a player layer, inside a container
  /// that crops the other eye away
  private func setUpFallback(_ reason: String) {
    print("Spatial player falls back to the left eye: \(reason)")
    let container = UIView()
    container.clipsToBounds = true
    container.isUserInteractionEnabled = false
    surface.addSubview(container)
    let layer = AVPlayerLayer(player: player)
    layer.videoGravity = .resize
    container.layer.addSublayer(layer)
    fallbackContainer = container
    fallbackLayer = layer
  }

  /// Places the fallback layer so that the left eye fills its container, letterboxed in the view
  private func layoutFallback() {
    guard let container = fallbackContainer, let layer = fallbackLayer else { return }
    let bounds = surface.bounds
    guard bounds.width > 0, bounds.height > 0 else { return }
    let eye = SpatialRenderer.eyeRects(for: resolvedLayout).left
    var aspect = Float(bounds.width / bounds.height)
    if presentationSize.width > 0, presentationSize.height > 0 {
      aspect = SpatialRenderer.displayAspect(
        frameWidth: Float(presentationSize.width),
        frameHeight: Float(presentationSize.height),
        rect: eye,
        layout: resolvedLayout
      )
    }
    var width = bounds.width
    var height = width / CGFloat(aspect)
    if height > bounds.height {
      height = bounds.height
      width = height * CGFloat(aspect)
    }
    let eyeX = CGFloat(eye.x)
    let eyeY = CGFloat(eye.y)
    let eyeWidth = CGFloat(eye.z)
    let eyeHeight = CGFloat(eye.w)
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    container.frame = CGRect(
      x: (bounds.width - width) / 2,
      y: (bounds.height - height) / 2,
      width: width,
      height: height
    )
    layer.frame = CGRect(
      x: -eyeX / eyeWidth * width,
      y: -eyeY / eyeHeight * height,
      width: width / eyeWidth,
      height: height / eyeHeight
    )
    CATransaction.commit()
  }

  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

  /// Called on every screen refresh: the newest video frame, the viewpoint, the view direction, then the renderer
  func draw(in view: MTKView) {
    guard !closing, let renderer else { return }
    let now = CACurrentMediaTime()
    if let videoOutput, let textureCache {
      let itemTime = videoOutput.itemTime(forHostTime: now)
      if videoOutput.hasNewPixelBuffer(forItemTime: itemTime),
        let pixelBuffer = videoOutput.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil),
        let frame = Self.makeTexture(from: pixelBuffer, cache: textureCache)
      {
        currentFrame = frame
      }
      // Once a second, the cache lets go of the textures of the frames already shown
      if now - lastCacheFlush >= 1 {
        lastCacheFlush = now
        CVMetalTextureCacheFlush(textureCache, 0)
      }
    }
    guard let frame = currentFrame, let texture = CVMetalTextureGetTexture(frame) else { return }

    lastViewpoint = currentViewpoint(now: now)
    renderer.viewpoint = Float(lastViewpoint)
    if isSpherical {
      updateViewDirection()
      renderer.yaw = yaw
      renderer.pitch = pitch
      renderer.fov = fieldOfView
      renderer.attitude = motionEnabled ? attitude : nil
    }
    renderer.draw(in: view, source: texture, retaining: frame)
  }

  /// A Metal texture over the pixel buffer, without a copy
  private static func makeTexture(from pixelBuffer: CVPixelBuffer, cache: CVMetalTextureCache) -> CVMetalTexture? {
    var texture: CVMetalTexture?
    let status = CVMetalTextureCacheCreateTextureFromImage(
      kCFAllocatorDefault,
      cache,
      pixelBuffer,
      nil,
      .bgra8Unorm,
      CVPixelBufferGetWidth(pixelBuffer),
      CVPixelBufferGetHeight(pixelBuffer),
      0,
      &texture
    )
    guard status == kCVReturnSuccess else {
      // Frees what the cache holds, so that the next frame has a better chance
      CVMetalTextureCacheFlush(cache, 0)
      return nil
    }
    return texture
  }

  // MARK: - Player

  /// Seconds of media buffered ahead for a video read over HTTP
  private static let streamingForwardBufferDuration: TimeInterval = 15

  private func setUpPlayer() {
    let asset = makeAsset()
    let item = AVPlayerItem(asset: asset)
    if !videoUrl.isFileURL {
      // Read over HTTP (the media bridge of a network share, a server): more media buffered ahead, so that a share
      // that answers in bursts does not stall the playback every few seconds. Local files keep the defaults.
      item.preferredForwardBufferDuration = Self.streamingForwardBufferDuration
    }
    if renderer != nil {
      let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey as String: true,
      ])
      item.add(output)
      videoOutput = output
    }
    // The audio track of the language picked last, where the video has one
    AudioTrackChooser.preferSavedLanguage(player)
    player.replaceCurrentItem(with: item)
    detectMultiview(asset)

    statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] observed, _ in
      let status = observed.status
      let reason = observed.error?.localizedDescription
      Task { @MainActor [weak self] in
        if status == .failed {
          self?.showError(reason)
        } else if status == .readyToPlay {
          self?.itemReady()
        }
      }
    }
    timeControlObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] _, _ in
      Task { @MainActor [weak self] in
        self?.playbackStateChanged()
      }
    }
    // Zero until the first frame is known
    presentationSizeObservation = item.observe(\.presentationSize, options: [.initial, .new]) {
      [weak self] observed, _ in
      let size = observed.presentationSize
      guard size.width > 0, size.height > 0 else { return }
      Task { @MainActor [weak self] in
        self?.frameSizeKnown(size)
      }
    }
    timeObserver = player.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.updateTimeDisplay()
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
  }

  /// Local files play as they are. Server videos take the route of the Flutter video player (native_video_player):
  /// through its local proxy when the server asks for a client certificate or basic auth, else straight to the
  /// server with the custom headers and the session cookies. Those cookies live in the app group storage, which
  /// AVFoundation does not read by itself.
  private func makeAsset() -> AVURLAsset {
    if videoUrl.isFileURL {
      return AVURLAsset(url: videoUrl)
    }
    if let proxyUrl = VideoProxyServer.shared.proxyURL(for: videoUrl) {
      return AVURLAsset(url: proxyUrl)
    }
    let cookies = URLSessionManager.cookieStorage.cookies(for: videoUrl) ?? []
    var httpHeaders = HTTPCookie.requestHeaderFields(with: cookies)
    httpHeaders.merge(headers) { _, custom in custom }
    return AVURLAsset(url: videoUrl, options: ["AVURLAssetHTTPHeaderFieldsKey": httpHeaders])
  }

  /// Once the item can play: the start position first, then the playback if asked
  private func itemReady() {
    guard !readyHandled, !closing else { return }
    readyHandled = true
    loadAudioTracks()
    updateTimeDisplay()
    guard startPositionMs > 0 else {
      startPlayback()
      return
    }
    let start = CMTime(value: CMTimeValue(startPositionMs), timescale: 1000)
    player.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.startPlayback()
      }
    }
  }

  /// Shows the audio track button for a video with a choice of audio tracks
  private func loadAudioTracks() {
    guard !audioTracksRequested, !closing, let item = player.currentItem else { return }
    audioTracksRequested = true
    Task { @MainActor [weak self] in
      guard let self else { return }
      let hasChoice = await self.audioTracks.load(item)
      guard hasChoice, !self.closing else { return }
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
    showMessage(name, duration: messageDuration)
    scheduleControlsHiding()
  }

  private func startPlayback() {
    guard !closing, !failed, !playbackStarted else { return }
    playbackStarted = true
    renderer?.resetHistory()
    updateTimeDisplay()
    if autoplay {
      player.play()
    } else {
      setControlsVisible(true)
    }
    // Opened paused, timeControlStatus stays paused and its observation does not fire again: the spinner, the play
    // button and the idle timer are brought up to date here
    playbackStateChanged()
  }

  private func playbackStateChanged() {
    guard started, !closing else { return }
    let status = player.timeControlStatus
    let paused = status == .paused
    setSymbol(of: playPauseButton, to: paused ? "play.fill" : "pause.fill", pointSize: 22)
    playPauseButton.accessibilityLabel = paused ? "Play" : "Pause"
    if (status == .waitingToPlayAtSpecifiedRate || !readyHandled) && !failed {
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
    } else if paused && !controlsVisible && !scrubbing {
      setControlsVisible(true)
    }
  }

  private func showError(_ reason: String?) {
    guard !failed, !closing else { return }
    failed = true
    print("Cannot play the Spatial video: \(reason ?? "unknown error")")
    player.pause()
    spinner.stopAnimating()
    errorLabel.isHidden = false
    playPauseButton.isEnabled = false
    seekSlider.isEnabled = false
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
    Task { @MainActor [weak self] in
      self?.showError(reason)
    }
  }

  @objc private func appDidEnterBackground() {
    player.pause()
    // No GPU work in the background
    metalView?.isPaused = true
    if headTracking == .active {
      headTracker.stop()
    }
  }

  @objc private func appWillEnterForeground() {
    guard started, !closing else { return }
    metalView?.isPaused = false
    let now = CACurrentMediaTime()
    switch headTracking {
    case .active:
      viewpoint.recenter(now: now)
      headTracker.start(orientation: screenOrientation)
    case .denied:
      // The permission may have been granted in the Settings meanwhile
      if AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
        activateHeadTracking()
      }
    case .waiting, .unavailable:
      break
    }
    // The motion reference frame may have moved while the app was in the background: the view keeps its heading,
    // and the first sample after the return realigns the phone on it
    if motionEnabled {
      yaw = Self.heading(of: currentOrientation())
      staleMotionTimestamp = motionManager.deviceMotion?.timestamp
      alignHeadingOnNextMotion = true
    }
  }

  /// Stops the playback, the camera, the motion and the refresh when the player closes, and keeps where playback was
  /// for Flutter, told in viewDidDisappear. Idempotent.
  private func stop() {
    guard !closing else { return }
    // Before the pause, which changes timeControlStatus
    closeState = captureCloseState()
    closing = true
    NSObject.cancelPreviousPerformRequests(withTarget: self)
    statsTimer?.invalidate()
    statsTimer = nil
    metalView?.isPaused = true
    player.pause()
    motionManager.stopDeviceMotionUpdates()
    headTracker.release()
    if started {
      UIApplication.shared.isIdleTimerDisabled = idleTimerWasDisabled
    }
  }

  /// Where playback is, and whether it plays
  private func captureCloseState() -> (positionMs: Int64, wasPlaying: Bool) {
    var positionMs = startPositionMs
    var wasPlaying = autoplay && !failed
    if playbackStarted {
      let seconds = CMTimeGetSeconds(player.currentTime())
      if seconds.isFinite, seconds >= 0 {
        positionMs = Int64((seconds * 1000).rounded())
      }
      wasPlaying = player.timeControlStatus != .paused && !failed
    }
    return (positionMs, wasPlaying)
  }

  /// Tells Flutter, once, where playback was, and the layout and the projection in use
  private func reportClosed() {
    guard !closedReported else { return }
    closedReported = true
    let state = closeState ?? captureCloseState()
    events.closed(
      positionMs: state.positionMs,
      wasPlaying: state.wasPlaying,
      layout: selectedLayout,
      projection: projection
    ) { result in
      if case .failure(let error) = result {
        print("Cannot tell Flutter that the Spatial player closed: \(error.code)")
      }
    }
  }

  // MARK: - Stereo layout

  /// The layout chosen in the menu, or for auto the guess from the shape of the frame. AVFoundation does not read
  /// the stereo metadata of the file (st3d).
  ///
  /// An Apple spatial video (MV-HEVC) is played whole, as a mono picture: AVPlayerItemVideoOutput only gives its
  /// first eye, in a normal frame that must not be split. Decoding both eyes (AVPlayerVideoOutput with a stereo
  /// output specification, iOS 17 and later) is left for later.
  private func resolveLayout() -> SpatialStereoLayout {
    guard selectedLayout == .auto else { return selectedLayout }
    if isMultiview {
      return SpatialStereoLayout.none
    }
    return Self.guessLayout(presentationSize, projection: projection)
  }

  /// The guess from the shape of the frame. Unlike the Android player, a 16:9 flat frame is kept whole: on iOS such
  /// a video is far more often a plain one (or the first eye of a spatial video) than half side by side, which the
  /// layout menu still offers.
  private static func guessLayout(_ size: CGSize, projection: SpatialProjection) -> SpatialStereoLayout {
    guard size.width > 0, size.height > 0 else {
      // VR180 videos are side by side far more often than not
      return projection == .equirectangular ? .topBottom : .sideBySide
    }
    let ratio = size.width / size.height
    switch projection {
    case .flat:
      // Two 16:9 eyes side by side make a 32:9 frame, one above the other a 16:18 one; a 16:9 frame carries no sign
      // of stereo and stays whole; anything else is taken for half side by side
      if ratio >= 3.2 && ratio <= 3.9 {
        return .sideBySide
      }
      if ratio >= 0.8 && ratio <= 0.95 {
        return .topBottom
      }
      if ratio >= 1.7 && ratio <= 1.85 {
        return SpatialStereoLayout.none
      }
      return .sideBySide
    case .equirectangular:
      // Two 2:1 eyes one above the other make a square frame, side by side a 4:1 one
      if ratio >= 0.9 && ratio <= 1.1 {
        return .topBottom
      }
      if ratio >= 3.6 && ratio <= 4.4 {
        return .sideBySide
      }
      return SpatialStereoLayout.none
    case .equirectangular180:
      // The eyes of a half sphere are square: side by side they make a 2:1 frame, one above the other a 1:2 one
      if ratio >= 1.8 && ratio <= 2.2 {
        return .sideBySide
      }
      if ratio >= 0.45 && ratio <= 0.55 {
        return .topBottom
      }
      return SpatialStereoLayout.none
    }
  }

  /// Looks for the stereo multiview video track of an Apple spatial video, known from iOS 17 on. Below, the file
  /// counts as an ordinary one.
  private func detectMultiview(_ asset: AVURLAsset) {
    guard #available(iOS 17.0, *) else { return }
    Task { @MainActor [weak self] in
      let tracks = (try? await asset.loadTracks(withMediaCharacteristic: .containsStereoMultiviewVideo)) ?? []
      guard let self, !self.closing, !tracks.isEmpty, !self.isMultiview else { return }
      self.isMultiview = true
      self.applyLayout()
      if self.selectedLayout == .auto {
        self.showMessage(self.layoutName(SpatialStereoLayout.none), duration: longMessageDuration)
      }
    }
  }

  private func frameSizeKnown(_ size: CGSize) {
    guard !closing, size != presentationSize else { return }
    presentationSize = size
    applyLayout()
  }

  private func applyLayout() {
    resolvedLayout = resolveLayout()
    renderer?.layout = resolvedLayout
    layoutFallback()
    updateLayoutMenu()
  }

  private func layoutChosen(_ layout: SpatialStereoLayout) {
    selectedLayout = layout
    applyLayout()
    showMessage(layoutName(layout), duration: messageDuration)
    scheduleControlsHiding()
  }

  private func updateLayoutMenu() {
    let actions = SpatialStereoLayout.allCases.map { layout in
      UIAction(title: layoutName(layout), state: layout == selectedLayout ? .on : .off) { [weak self] _ in
        self?.layoutChosen(layout)
      }
    }
    layoutButton.menu = UIMenu(title: text("layout", "Stereo layout"), children: actions)
    layoutButton.showsMenuAsPrimaryAction = true
    layoutButton.accessibilityValue = layoutName(selectedLayout)
  }

  private func layoutName(_ layout: SpatialStereoLayout) -> String {
    switch layout {
    case .auto:
      return text("layoutAuto", "Auto")
    case .sideBySide:
      return text("layoutSideBySide", "Side by side")
    case .topBottom:
      return text("layoutTopBottom", "Top and bottom")
    case .sideBySideSwapped:
      return text("layoutSideBySideSwapped", "Side by side, eyes swapped")
    case .topBottomSwapped:
      return text("layoutTopBottomSwapped", "Top and bottom, eyes swapped")
    case .none:
      return text("layoutNone", "Not stereoscopic")
    }
  }

  /// A label from Flutter, or its English fallback
  private func text(_ key: String, _ fallback: String) -> String {
    guard let value = labels[key], !value.isEmpty else { return fallback }
    return value
  }

  // MARK: - Coverage (360 degree videos)

  /// A 360 or 180 degree video, seen through a viewport, rather than a flat one
  private var isSpherical: Bool { projection != .flat }

  private func coverageName(_ projection: SpatialProjection) -> String {
    if projection == .equirectangular180 {
      return text("coverage_half", "180°, half sphere (VR180)")
    }
    return text("coverage_full", "360°, full sphere")
  }

  /// The button shows the coverage in use, without the fade of a system button
  private func updateCoverageButton() {
    let title = projection == .equirectangular180 ? "180°" : "360°"
    UIView.performWithoutAnimation {
      self.coverageButton.setTitle(title, for: .normal)
      self.coverageButton.layoutIfNeeded()
    }
    coverageButton.accessibilityValue = coverageName(projection)
  }

  // MARK: - Head tracking and viewpoint

  private func startHeadTracking() {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
      activateHeadTracking()
    case .notDetermined:
      AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
        Task { @MainActor [weak self] in
          guard let self, !self.closing else { return }
          if granted {
            self.activateHeadTracking()
          } else {
            self.headTrackingDenied()
          }
        }
      }
    default:
      headTrackingDenied()
    }
  }

  private func activateHeadTracking() {
    guard !closing else { return }
    guard HeadTracker.frontCameraAvailable else {
      headTracking = .unavailable
      updateViewpointControls()
      return
    }
    headTracking = .active
    manualViewpoint = false
    viewpoint.recenter(now: CACurrentMediaTime())
    headTracker.start(orientation: screenOrientation)
    updateViewpointControls()
  }

  private func headTrackingDenied() {
    headTracking = .denied
    updateViewpointControls()
    setControlsVisible(true)
    showMessage(
      text("cameraDenied", "Camera access refused: use the slider to move the viewpoint"),
      duration: longMessageDuration
    )
  }

  /// The viewpoint for this frame: the slider without head tracking or once moved by hand, else the head
  private func currentViewpoint(now: CFTimeInterval) -> Double {
    guard headTracking == .active, !manualViewpoint else {
      setTrackingLostShown(false)
      return Double(viewpointSlider.value)
    }
    let state = headTracker.snapshot()
    if state.failed {
      // The front camera cannot track faces after all
      headTracking = .unavailable
      updateViewpointControls()
      setTrackingLostShown(false)
      return Double(viewpointSlider.value)
    }
    if viewTurning {
      if now - lastTurnMove > turnSettleDelay {
        viewTurning = false
        viewpoint.recenter(now: now)
      } else {
        // The face moves because the phone turns, not the head: the viewpoint keeps its value
        setTrackingLostShown(false)
        return viewpoint.value
      }
    }
    let value = viewpoint.update(state: state, now: now)
    setTrackingLostShown(HeadViewpoint.isLost(state, now: now))
    if debugOverlay && !viewpointSlider.isTracking {
      viewpointSlider.value = Float(value)
    }
    return value
  }

  private func setTrackingLostShown(_ shown: Bool) {
    guard shown != trackingLostShown else { return }
    trackingLostShown = shown
    UIView.animate(withDuration: 0.2) {
      self.trackingView.alpha = shown ? 1 : 0
    }
  }

  /// The manual slider shows in the debug overlay, and whenever the head cannot drive the viewpoint
  private func updateViewpointControls() {
    let headDrives = headTracking == .active || headTracking == .waiting
    viewpointSlider.isHidden = !(debugOverlay || !headDrives)
    if !headDrives {
      viewpointSlider.value = Float(HeadViewpoint.middle)
    }
    sensitivityLabel.isHidden = !headDrives
    sensitivitySlider.isHidden = !headDrives
  }

  // MARK: - View direction (360 degree videos)

  private func startMotion() {
    guard motionManager.isDeviceMotionAvailable else { return }
    alignHeadingOnNextMotion = true
    staleMotionTimestamp = motionManager.deviceMotion?.timestamp
    motionManager.deviceMotionUpdateInterval = 1.0 / 60.0
    // The magnetometer corrects the drift of the heading, where there is one
    let corrected = CMMotionManager.availableAttitudeReferenceFrames().contains(.xArbitraryCorrectedZVertical)
    motionManager.startDeviceMotionUpdates(using: corrected ? .xArbitraryCorrectedZVertical : .xArbitraryZVertical)
  }

  /// Takes the latest attitude of the phone, as the 360 degree player does
  private func updateViewDirection() {
    guard motionEnabled, let motion = motionManager.deviceMotion, motion.timestamp != staleMotionTimestamp else {
      return
    }
    let sensor = sensorOrientation(motion.attitude.quaternion)
    if alignHeadingOnNextMotion {
      // Keeps the heading of the view: the middle of the video at first, where the drags left it later
      alignHeadingOnNextMotion = false
      yaw -= Self.heading(of: sensor)
    }
    attitude = sensor
    if let last = lastSensorAttitude, (sensor * last.inverse).angle > turnMoveRadians {
      lastTurnMove = CACurrentMediaTime()
      viewTurning = true
    }
    lastSensorAttitude = sensor
  }

  /// Where the camera looks now, in the frame of the renderer
  private func currentOrientation() -> simd_quatf {
    let yawRotation = simd_quatf(angle: yaw, axis: yAxis)
    if motionEnabled, let attitude {
      return yawRotation * attitude
    }
    return yawRotation * simd_quatf(angle: pitch, axis: xAxis)
  }

  /// Camera orientation for an attitude of the phone. CoreMotion's reference frame has z up where the renderer has y
  /// up, hence the quarter turn around x: the phone held upright looks at the horizon, flat on its back it looks at
  /// the floor. The camera then rolls with the interface so that the top of the screen stays the top of the view.
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

  // MARK: - Gestures

  private func setUpGestures() {
    let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
    tap.delegate = self
    surface.addGestureRecognizer(tap)
    if isSpherical {
      let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
      let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
      pan.delegate = self
      pinch.delegate = self
      surface.addGestureRecognizer(pan)
      surface.addGestureRecognizer(pinch)
    } else {
      // A flat video has no drag to turn the view: a swipe down closes the player
      let swipe = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipeDown(_:)))
      swipe.direction = .down
      surface.addGestureRecognizer(swipe)
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
    let translation = gesture.translation(in: surface)
    gesture.setTranslation(.zero, in: surface)
    // The picture follows the finger: a drag to the left turns the view to the right, a drag up turns it down
    let scale = radiansPerPoint * fieldOfView / defaultFieldOfView
    yaw += Float(translation.x) * scale
    if !motionEnabled {
      pitch = min(max(pitch + Float(translation.y) * scale, -maxPitch), maxPitch)
    }
  }

  @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
    switch gesture.state {
    case .began:
      pinchStartFieldOfView = fieldOfView
    case .changed:
      guard gesture.scale > 0 else { return }
      fieldOfView = min(max(pinchStartFieldOfView / Float(gesture.scale), minFieldOfView), maxFieldOfView)
    default:
      break
    }
  }

  @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
    // The close button stays on screen with an error
    setControlsVisible(!controlsVisible || failed)
  }

  @objc private func handleSwipeDown(_ gesture: UISwipeGestureRecognizer) {
    closeTapped()
  }

  // MARK: - Controls

  private func setUpControls() {
    spinner.color = .white
    spinner.hidesWhenStopped = true
    spinner.translatesAutoresizingMaskIntoConstraints = false
    spinner.startAnimating()
    view.addSubview(spinner)

    errorLabel.text = text("error", "Unable to play this video")
    errorLabel.textColor = .white
    errorLabel.font = .preferredFont(forTextStyle: .body)
    errorLabel.textAlignment = .center
    errorLabel.numberOfLines = 0
    errorLabel.isHidden = true
    errorLabel.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(errorLabel)

    // Top bar: close, title, then, in the debug overlay, the disparity view, the audio tracks of a video with a
    // choice of them, the coverage of a 360 degree video, the layout menu and Recenter
    topBar.backgroundColor = UIColor(white: 0, alpha: 0.45)
    topBar.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(topBar)

    configure(closeButton, symbol: "xmark", pointSize: 20, action: #selector(closeTapped))
    closeButton.accessibilityLabel = text("close", "Close")
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
    let layoutSymbol = UIImage(systemName: "view.3d") == nil ? "cube" : "view.3d"
    configure(layoutButton, symbol: layoutSymbol, pointSize: 20, action: nil)
    layoutButton.accessibilityLabel = text("layout", "Stereo layout")

    // Opens the menu of the audio tracks; hidden unless the video has a choice of them
    configure(audioButton, symbol: "waveform", pointSize: 20, action: nil)
    audioButton.accessibilityLabel = audioTracks.buttonLabel
    audioButton.isHidden = true

    configure(recenterButton, symbol: "scope", pointSize: 20, action: #selector(recenterTapped))
    recenterButton.accessibilityLabel = text("recenter", "Recenter")

    configure(disparityButton, symbol: "square.stack.3d.down.right", pointSize: 20, action: #selector(disparityTapped))
    disparityButton.accessibilityLabel = "Disparity map"
    disparityButton.isHidden = !debugOverlay
    updateDisparityButton()

    // A text button, 360° or 180°: see updateCoverageButton. A flat video has no coverage to choose.
    coverageButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
    coverageButton.tintColor = .white
    coverageButton.translatesAutoresizingMaskIntoConstraints = false
    coverageButton.addTarget(self, action: #selector(coverageTapped), for: .touchUpInside)
    coverageButton.accessibilityLabel = text("coverage", "Field of view")
    coverageButton.isHidden = !isSpherical
    updateCoverageButton()

    let trailingButtons = UIStackView(arrangedSubviews: [
      disparityButton, audioButton, coverageButton, layoutButton, recenterButton,
    ])
    trailingButtons.axis = .horizontal
    trailingButtons.spacing = 4
    trailingButtons.translatesAutoresizingMaskIntoConstraints = false
    topBar.addSubview(trailingButtons)

    // Bottom bar: play and pause, the seek bar between the times, then the sensitivity and the manual viewpoint
    bottomBar.backgroundColor = UIColor(white: 0, alpha: 0.45)
    bottomBar.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(bottomBar)

    configure(playPauseButton, symbol: "play.fill", pointSize: 22, action: #selector(playPauseTapped))
    playPauseButton.accessibilityLabel = "Play"

    for label in [currentTimeLabel, durationLabel] {
      label.textColor = .white
      label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
      label.text = "0:00"
      label.setContentHuggingPriority(.required, for: .horizontal)
      label.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    seekSlider.minimumValue = 0
    seekSlider.maximumValue = 1
    seekSlider.minimumTrackTintColor = .white
    seekSlider.addTarget(self, action: #selector(seekBegan), for: .touchDown)
    seekSlider.addTarget(self, action: #selector(seekChanged), for: .valueChanged)
    seekSlider.addTarget(self, action: #selector(seekEnded), for: [.touchUpInside, .touchUpOutside, .touchCancel])

    sensitivityLabel.text = text("sensitivity", "Head sensitivity")
    sensitivityLabel.textColor = .white
    sensitivityLabel.font = .preferredFont(forTextStyle: .footnote)
    sensitivityLabel.setContentHuggingPriority(.required, for: .horizontal)
    sensitivityLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

    sensitivitySlider.minimumValue = 0.5
    sensitivitySlider.maximumValue = 4.0
    sensitivitySlider.value = defaultSensitivity
    sensitivitySlider.minimumTrackTintColor = .white
    sensitivitySlider.accessibilityLabel = text("sensitivity", "Head sensitivity")
    sensitivitySlider.addTarget(self, action: #selector(sensitivityChanged), for: .valueChanged)
    viewpoint.sensitivity = Double(defaultSensitivity)

    // From the left eye to the right eye of the video
    viewpointSlider.minimumValue = 0
    viewpointSlider.maximumValue = 1
    viewpointSlider.value = Float(HeadViewpoint.middle)
    viewpointSlider.minimumTrackTintColor = .white
    viewpointSlider.minimumValueImage = UIImage(systemName: "arrow.left")
    viewpointSlider.maximumValueImage = UIImage(systemName: "arrow.right")
    viewpointSlider.tintColor = .white
    viewpointSlider.accessibilityLabel = "Viewpoint"
    viewpointSlider.addTarget(self, action: #selector(viewpointChanged), for: .valueChanged)

    let timeRow = UIStackView(arrangedSubviews: [playPauseButton, currentTimeLabel, seekSlider, durationLabel])
    timeRow.axis = .horizontal
    timeRow.alignment = .center
    timeRow.spacing = 12

    let viewpointRow = UIStackView(arrangedSubviews: [sensitivityLabel, sensitivitySlider, viewpointSlider])
    viewpointRow.axis = .horizontal
    viewpointRow.alignment = .center
    viewpointRow.spacing = 12

    let bottomStack = UIStackView(arrangedSubviews: [timeRow, viewpointRow])
    bottomStack.axis = .vertical
    bottomStack.spacing = 4
    bottomStack.translatesAutoresizingMaskIntoConstraints = false
    bottomBar.addSubview(bottomStack)

    statsLabel.textColor = .white
    statsLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    statsLabel.numberOfLines = 0
    statsLabel.backgroundColor = UIColor(white: 0, alpha: 0.5)
    statsLabel.isHidden = !debugOverlay
    statsLabel.isUserInteractionEnabled = false
    statsLabel.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(statsLabel)

    for (pill, label) in [(messageView, messageLabel), (trackingView, trackingLabel)] {
      pill.backgroundColor = UIColor(white: 0, alpha: 0.6)
      pill.layer.cornerRadius = 8
      pill.alpha = 0
      pill.isUserInteractionEnabled = false
      pill.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(pill)
      label.textColor = .white
      label.font = .preferredFont(forTextStyle: .subheadline)
      label.textAlignment = .center
      label.numberOfLines = 0
      label.translatesAutoresizingMaskIntoConstraints = false
      pill.addSubview(label)
      NSLayoutConstraint.activate([
        label.topAnchor.constraint(equalTo: pill.topAnchor, constant: 8),
        label.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -8),
        label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 12),
        label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -12),
      ])
    }
    // VoiceOver reads the transient message out when it shows
    messageView.accessibilityElementsHidden = true
    trackingLabel.text = text("trackingLost", "Face not found, looking for it")

    // Below required, else they fight the zero width the stack views give hidden items
    let disparityButtonWidth = disparityButton.widthAnchor.constraint(equalToConstant: 44)
    disparityButtonWidth.priority = UILayoutPriority(999)
    let coverageButtonWidth = coverageButton.widthAnchor.constraint(equalToConstant: 52)
    coverageButtonWidth.priority = UILayoutPriority(999)
    let audioButtonWidth = audioButton.widthAnchor.constraint(equalToConstant: 44)
    audioButtonWidth.priority = UILayoutPriority(999)
    let sensitivitySliderWidth = sensitivitySlider.widthAnchor.constraint(equalToConstant: 160)
    sensitivitySliderWidth.priority = UILayoutPriority(999)

    let safeArea = view.safeAreaLayoutGuide
    NSLayoutConstraint.activate([
      spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),

      errorLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      errorLabel.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor, constant: 32),
      errorLabel.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor, constant: -32),

      // The bars run to the edges of the screen, their content stays in the safe area
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
      disparityButtonWidth,
      disparityButton.heightAnchor.constraint(equalToConstant: 44),
      coverageButtonWidth,
      coverageButton.heightAnchor.constraint(equalToConstant: 44),
      audioButtonWidth,
      audioButton.heightAnchor.constraint(equalToConstant: 44),
      layoutButton.widthAnchor.constraint(equalToConstant: 44),
      layoutButton.heightAnchor.constraint(equalToConstant: 44),
      recenterButton.widthAnchor.constraint(equalToConstant: 44),
      recenterButton.heightAnchor.constraint(equalToConstant: 44),

      titleLabel.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 8),
      titleLabel.trailingAnchor.constraint(equalTo: trailingButtons.leadingAnchor, constant: -8),
      titleLabel.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),

      bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      bottomBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      bottomStack.topAnchor.constraint(equalTo: bottomBar.topAnchor, constant: 8),
      bottomStack.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor, constant: 16),
      bottomStack.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor, constant: -16),
      bottomStack.bottomAnchor.constraint(equalTo: safeArea.bottomAnchor, constant: -8),

      playPauseButton.widthAnchor.constraint(equalToConstant: 44),
      playPauseButton.heightAnchor.constraint(equalToConstant: 44),
      sensitivitySliderWidth,
      viewpointRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),

      statsLabel.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 8),
      statsLabel.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor, constant: 16),
      statsLabel.trailingAnchor.constraint(lessThanOrEqualTo: safeArea.trailingAnchor, constant: -16),

      messageView.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 16),
      messageView.centerXAnchor.constraint(equalTo: safeArea.centerXAnchor),
      messageView.leadingAnchor.constraint(greaterThanOrEqualTo: safeArea.leadingAnchor, constant: 32),
      messageView.trailingAnchor.constraint(lessThanOrEqualTo: safeArea.trailingAnchor, constant: -32),

      trackingView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor, constant: -12),
      trackingView.centerXAnchor.constraint(equalTo: safeArea.centerXAnchor),
      trackingView.leadingAnchor.constraint(greaterThanOrEqualTo: safeArea.leadingAnchor, constant: 32),
      trackingView.trailingAnchor.constraint(lessThanOrEqualTo: safeArea.trailingAnchor, constant: -32),
    ])
  }

  private func configure(_ button: UIButton, symbol: String, pointSize: CGFloat, action: Selector?) {
    setSymbol(of: button, to: symbol, pointSize: pointSize)
    button.tintColor = .white
    button.translatesAutoresizingMaskIntoConstraints = false
    if let action {
      button.addTarget(self, action: action, for: .touchUpInside)
    }
  }

  private func setSymbol(of button: UIButton, to symbol: String, pointSize: CGFloat) {
    let configuration = UIImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
    button.setImage(UIImage(systemName: symbol, withConfiguration: configuration), for: .normal)
  }

  private func updateDisparityButton() {
    let on = renderer?.showDisparity == true
    disparityButton.tintColor = on ? UIColor.white : UIColor(white: 1, alpha: 0.4)
    disparityButton.accessibilityValue = on ? "On" : "Off"
  }

  private func setControlsVisible(_ visible: Bool) {
    NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(hideControls), object: nil)
    controlsVisible = visible
    UIView.animate(withDuration: 0.2) {
      self.topBar.alpha = visible ? 1 : 0
      self.bottomBar.alpha = visible ? 1 : 0
    }
    setNeedsUpdateOfHomeIndicatorAutoHidden()
    if visible {
      scheduleControlsHiding()
    }
  }

  private func scheduleControlsHiding() {
    NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(hideControls), object: nil)
    // VoiceOver users keep the controls on screen
    if player.timeControlStatus == .playing && !failed && !closing && !scrubbing
      && !UIAccessibility.isVoiceOverRunning
    {
      perform(#selector(hideControls), with: nil, afterDelay: controlsHideDelay)
    }
  }

  @objc private func hideControls() {
    setControlsVisible(false)
  }

  /// Shows [message] under the top bar for [duration] seconds
  private func showMessage(_ message: String, duration: TimeInterval) {
    NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(hideMessage), object: nil)
    messageLabel.text = message
    UIView.animate(withDuration: 0.2) {
      self.messageView.alpha = 1
    }
    perform(#selector(hideMessage), with: nil, afterDelay: duration)
    UIAccessibility.post(notification: .announcement, argument: message)
  }

  @objc private func hideMessage() {
    UIView.animate(withDuration: 0.3) {
      self.messageView.alpha = 0
    }
  }

  private func updateTimeDisplay() {
    guard !closing, let item = player.currentItem else { return }
    let duration = CMTimeGetSeconds(item.duration)
    if duration.isFinite, duration > 0 {
      seekSlider.maximumValue = Float(duration)
      durationLabel.text = Self.format(duration)
    }
    guard !scrubbing else { return }
    let current = CMTimeGetSeconds(player.currentTime())
    if current.isFinite {
      seekSlider.value = Float(current)
      currentTimeLabel.text = Self.format(current)
    }
  }

  private static func format(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds.rounded(.down))
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let remainder = total % 60
    if hours > 0 {
      return String(format: "%d:%02d:%02d", hours, minutes, remainder)
    }
    return String(format: "%d:%02d", minutes, remainder)
  }

  private func updateStats() {
    guard !closing else { return }
    let head = headTracker.snapshot()
    var lines: [String] = []
    if let stats = renderer?.stats() {
      lines.append(
        String(
          format: "%@ %ldx%ld  GPU %.1f ms  %.0f fps  disparity %.0f/s%@",
          stats.quality.name,
          stats.mapWidth,
          stats.mapHeight,
          stats.gpuMs,
          stats.renderFps,
          stats.disparityFps,
          stats.stereoAvailable ? "" : "  (left eye only)"
        )
      )
    } else {
      lines.append("Fallback player, left eye only")
    }
    lines.append(
      String(
        format: "head x %+.3f  %.0f fps  confidence %.2f  %@",
        head.headX,
        head.trackingFps,
        head.confidence,
        head.running ? "running" : "stopped"
      )
    )
    lines.append(String(format: "viewpoint %.2f  layout %@", lastViewpoint, layoutName(resolvedLayout)))
    statsLabel.text = lines.joined(separator: "\n")
  }

  // MARK: - Actions

  @objc private func closeTapped() {
    stop()
    dismiss(animated: true)
  }

  @objc private func playPauseTapped() {
    if player.timeControlStatus == .paused {
      if reachedEnd {
        reachedEnd = false
        player.seek(to: .zero)
        renderer?.resetHistory()
      }
      player.play()
    } else {
      player.pause()
    }
  }

  @objc private func seekBegan() {
    scrubbing = true
    NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(hideControls), object: nil)
  }

  @objc private func seekChanged() {
    let seconds = Double(seekSlider.value)
    currentTimeLabel.text = Self.format(seconds)
    // Quick, inexact seeks while the finger moves, an exact one when it lifts
    let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
    player.seek(
      to: CMTime(seconds: seconds, preferredTimescale: 600),
      toleranceBefore: tolerance,
      toleranceAfter: tolerance
    )
    renderer?.resetHistory()
  }

  @objc private func seekEnded() {
    let seconds = Double(seekSlider.value)
    reachedEnd = false
    player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) {
      [weak self] _ in
      Task { @MainActor [weak self] in
        self?.scrubbing = false
        self?.renderer?.resetHistory()
        self?.scheduleControlsHiding()
      }
    }
  }

  @objc private func recenterTapped() {
    manualViewpoint = false
    if headTracking == .active {
      viewpoint.recenter(now: CACurrentMediaTime())
    } else {
      viewpointSlider.value = Float(HeadViewpoint.middle)
    }
    scheduleControlsHiding()
  }

  @objc private func sensitivityChanged() {
    viewpoint.sensitivity = Double(sensitivitySlider.value)
    scheduleControlsHiding()
  }

  @objc private func viewpointChanged() {
    // While the head drives the viewpoint, the debug slider takes over until Recenter
    if headTracking == .active {
      manualViewpoint = true
    }
    scheduleControlsHiding()
  }

  @objc private func disparityTapped() {
    guard let renderer else { return }
    renderer.showDisparity.toggle()
    updateDisparityButton()
    scheduleControlsHiding()
  }

  /// Switches a 360 degree video between the whole sphere and its front half, at once
  @objc private func coverageTapped() {
    guard isSpherical else { return }
    projection = projection == .equirectangular180 ? .equirectangular : .equirectangular180
    renderer?.projection = projection
    // The shape of the frame may tell another stereo layout for the new coverage, when the layout is automatic
    applyLayout()
    updateCoverageButton()
    showMessage(coverageName(projection), duration: messageDuration)
    scheduleControlsHiding()
  }
}
