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
private let radiansPerPoint: Float = 0.2 * Float.pi / 180
private let controlsHideDelay: TimeInterval = 4
private let xAxis = SIMD3<Float>(1, 0, 0)
private let yAxis = SIMD3<Float>(0, 1, 0)
private let zAxis = SIMD3<Float>(0, 0, 1)

/// Plays an equirectangular video full screen, from the centre of a sphere textured with the video.
///
/// Drags turn the view (the picture follows the finger, so a drag to the left turns the view to the right), a pinch
/// zooms. While the gyroscope button is on, the motion of the phone turns the view and drags only turn it around the
/// vertical axis. A tap on the video shows or hides the controls, which also hide on their own while the video plays.
final class SphericalVideoViewController: UIViewController, UIGestureRecognizerDelegate {
  private let videoUrl: URL
  private let headers: [String: String]
  private let videoTitle: String
  private let closeLabel: String?
  private let errorMessage: String

  private let player = AVPlayer()
  private let sceneView = SCNView(frame: .zero)
  private let cameraNode = SCNNode()
  private let motionManager = CMMotionManager()
  private var displayLink: CADisplayLink?
  private var statusObservation: NSKeyValueObservation?
  private var timeControlObservation: NSKeyValueObservation?

  private let topBar = UIView()
  private let closeButton = UIButton(type: .system)
  private let titleLabel = UILabel()
  private let motionButton = UIButton(type: .system)
  private let playPauseButton = UIButton(type: .system)
  private let spinner = UIActivityIndicatorView(style: .large)
  private let errorLabel = UILabel()

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

  private var controlsVisible = true
  private var failed = false
  private var reachedEnd = false
  private var started = false
  private var closing = false
  private var idleTimerWasDisabled = false

  /// [errorMessage] comes translated from Flutter, English is the fallback
  init(url: URL, headers: [String: String], title: String, closeLabel: String?, errorMessage: String?) {
    videoUrl = url
    self.headers = headers
    videoTitle = title
    self.closeLabel = closeLabel
    self.errorMessage = errorMessage ?? "This video cannot be played"
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
    updateMotionButton()
    updateCamera()

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(appDidEnterBackground),
      name: UIApplication.didEnterBackgroundNotification,
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
    player.replaceCurrentItem(with: nil)
    sceneView.isPlaying = false
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

  private func setUpPlayer() {
    let item = AVPlayerItem(asset: makeAsset())
    player.replaceCurrentItem(with: item)

    statusObservation = item.observe(\.status, options: [.new]) { [weak self] observed, _ in
      guard observed.status == .failed else { return }
      let reason = observed.error?.localizedDescription
      Task { @MainActor [weak self] in
        self?.showError(reason)
      }
    }
    timeControlObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] _, _ in
      Task { @MainActor [weak self] in
        self?.playbackStateChanged()
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

  private func playbackStateChanged() {
    guard started, !closing else { return }
    let status = player.timeControlStatus
    let paused = status == .paused
    setSymbol(of: playPauseButton, to: paused ? "play.fill" : "pause.fill", pointSize: 28)
    playPauseButton.accessibilityLabel = paused ? "Play" : "Pause"
    if status == .waitingToPlayAtSpecifiedRate && !failed {
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

  private func showError(_ reason: String?) {
    guard !failed, !closing else { return }
    failed = true
    print("Cannot play the 360° video: \(reason ?? "unknown error")")
    player.pause()
    spinner.stopAnimating()
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
    Task { @MainActor [weak self] in
      self?.showError(reason)
    }
  }

  @objc private func appDidEnterBackground() {
    player.pause()
  }

  /// Stops the playback, the motion and the refresh when the player closes, idempotent
  private func stop() {
    guard !closing else { return }
    closing = true
    NSObject.cancelPreviousPerformRequests(withTarget: self)
    displayLink?.invalidate()
    displayLink = nil
    player.pause()
    motionManager.stopDeviceMotionUpdates()
    if started {
      UIApplication.shared.isIdleTimerDisabled = idleTimerWasDisabled
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
    let material = SCNMaterial()
    material.diffuse.contents = player
    material.lightingModel = .constant
    material.isDoubleSided = true

    let sphere = Self.makeSphere(radius: 50, rings: 64, segments: 128)
    sphere.materials = [material]

    let scene = SCNScene()
    scene.rootNode.addChildNode(SCNNode(geometry: sphere))
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

  /// A sphere made to be seen from its centre, with the whole frame on it and not mirrored: the middle of the frame
  /// straight ahead of a camera at rest (towards -z), the right of the frame to its right (+x), the top row at the
  /// zenith. SCNSphere is not used because where its texture seam falls is not documented. SceneKit texture
  /// coordinates start at the top left corner of the image.
  private static func makeSphere(radius: Float, rings: Int, segments: Int) -> SCNGeometry {
    var vertices: [SCNVector3] = []
    var textureCoordinates: [CGPoint] = []
    vertices.reserveCapacity((rings + 1) * (segments + 1))
    textureCoordinates.reserveCapacity((rings + 1) * (segments + 1))
    for ring in 0...rings {
      let v = Float(ring) / Float(rings)
      // 0 at the zenith, pi at the nadir
      let polar = v * Float.pi
      let y = radius * cos(polar)
      let ringRadius = radius * sin(polar)
      for segment in 0...segments {
        let u = Float(segment) / Float(segments)
        // 0 straight ahead, growing to the right
        let azimuth = (u - 0.5) * 2 * Float.pi
        let x = ringRadius * sin(azimuth)
        let z = -ringRadius * cos(azimuth)
        vertices.append(SCNVector3(x: x, y: y, z: z))
        textureCoordinates.append(CGPoint(x: CGFloat(u), y: CGFloat(v)))
      }
    }

    var indices: [UInt32] = []
    indices.reserveCapacity(rings * segments * 6)
    let columns = UInt32(segments + 1)
    for ring in 0..<UInt32(rings) {
      for segment in 0..<UInt32(segments) {
        let topLeft = ring * columns + segment
        let topRight = topLeft + 1
        let bottomLeft = topLeft + columns
        let bottomRight = bottomLeft + 1
        indices.append(contentsOf: [topLeft, bottomLeft, topRight, topRight, bottomLeft, bottomRight])
      }
    }

    return SCNGeometry(
      sources: [SCNGeometrySource(vertices: vertices), SCNGeometrySource(textureCoordinates: textureCoordinates)],
      elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)]
    )
  }

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
    motionManager.startDeviceMotionUpdates(using: .xArbitraryZVertical)
  }

  /// Called on every screen refresh: turns the camera with the latest attitude of the phone
  @objc private func step(_ link: CADisplayLink) {
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

    configure(motionButton, symbol: "gyroscope", pointSize: 20, action: #selector(motionTapped))
    motionButton.accessibilityLabel = "Gyroscope"
    topBar.addSubview(motionButton)

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

      // The bar runs under the status bar area, its content stays in the safe area
      topBar.topAnchor.constraint(equalTo: view.topAnchor),
      topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      topBar.bottomAnchor.constraint(equalTo: safeArea.topAnchor, constant: 56),

      closeButton.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor, constant: 8),
      closeButton.bottomAnchor.constraint(equalTo: topBar.bottomAnchor, constant: -6),
      closeButton.widthAnchor.constraint(equalToConstant: 44),
      closeButton.heightAnchor.constraint(equalToConstant: 44),

      motionButton.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor, constant: -8),
      motionButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
      motionButton.widthAnchor.constraint(equalToConstant: 44),
      motionButton.heightAnchor.constraint(equalToConstant: 44),

      titleLabel.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 8),
      titleLabel.trailingAnchor.constraint(equalTo: motionButton.leadingAnchor, constant: -8),
      titleLabel.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
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
    if player.timeControlStatus == .playing && !failed && !closing {
      perform(#selector(hideControls), with: nil, afterDelay: controlsHideDelay)
    }
  }

  @objc private func hideControls() {
    setControlsVisible(false)
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
      player.play()
    } else {
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
}
