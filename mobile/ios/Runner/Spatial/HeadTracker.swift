import AVFoundation
import QuartzCore
import UIKit

/// What the head tracker knows at a given moment, read by the player on every frame.
struct HeadTrackingState {
  /// Horizontal position of the face centre, filtered, in [-0.5, 0.5]: positive when the head is to the user's right
  var headX: Double = 0
  /// When the last face was seen (CACurrentMediaTime), nil before the first one
  var lastFaceTime: CFTimeInterval?
  /// Face samples received during the last second, 0 once the face is lost
  var trackingFps: Double = 0
  /// Share of the camera frames of the last second that held a face, from 0 to 1, 0 once the face is lost
  var confidence: Double = 0
  /// The capture session runs (false while stopped, interrupted or failed)
  var running = false
  /// The front camera cannot be used for face tracking on this device
  var failed = false
}

/// Follows the horizontal position of the user's head with the front camera, through the face metadata that the
/// camera hardware computes itself (AVCaptureMetadataOutput), the cheapest way to find a face on iOS. Nothing is
/// recorded, stored or sent: only the position of the face centre leaves this class.
///
/// Orientation. AVFoundation gives the face bounds in the coordinates of the unrotated, unmirrored sensor picture.
/// A video data output is added to the session only for its connection, set to the interface orientation and
/// mirrored: transformedMetadataObject(for:connection:) turns the bounds into the coordinates of that upright,
/// mirrored picture, the picture a mirror would show (no frame is ever delivered, the output has no delegate). In a
/// mirror, a head that moves to the user's right moves to the right of the picture, so headX = midX - 0.5 is
/// positive when the head moves to the user's right, in both landscape orientations alike.
final class HeadTracker: NSObject, AVCaptureMetadataOutputObjectsDelegate {
  /// How long a face may be missing before it counts as lost
  static let lostDelay: CFTimeInterval = 0.3

  /// Whether the device has a front camera, cheap and without any permission prompt
  static var frontCameraAvailable: Bool {
    AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) != nil
  }

  // Everything below is used on the capture queue only, except the state behind the lock
  private let session = AVCaptureSession()
  private let queue = DispatchQueue(label: "app.alextran.immich.spatial.head-tracker")
  private let metadataOutput = AVCaptureMetadataOutput()
  private let orientationOutput = AVCaptureVideoDataOutput()
  private let filter = OneEuroFilter(minCutoff: 1.0, beta: 0.02, derivativeCutoff: 1.0)
  private var configured = false
  private var configurationFailed = false
  private var wanted = false
  private var videoOrientation = AVCaptureVideoOrientation.landscapeRight

  private let lock = NSLock()
  private var state = HeadTrackingState()
  // When the faces of the last second were seen, behind the lock as well: the tracking rate and the confidence are
  // worked out when the state is read, because the metadata output stops calling once no face is in view
  private var faceTimes: [CFTimeInterval] = []

  private var observers: [NSObjectProtocol] = []

  override init() {
    super.init()
    let center = NotificationCenter.default
    observers.append(
      center.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: nil) { [weak self] note in
        let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
        self?.sessionFailed(error)
      }
    )
    observers.append(
      center.addObserver(forName: .AVCaptureSessionWasInterrupted, object: session, queue: nil) { [weak self] _ in
        // Another app took the camera, or the app went to split view on iPad: the face counts as lost meanwhile
        self?.updateState { $0.running = false }
      }
    )
    observers.append(
      center.addObserver(forName: .AVCaptureSessionInterruptionEnded, object: session, queue: nil) { [weak self] _ in
        self?.queue.async { [weak self] in
          guard let self else { return }
          self.filter.reset()
          self.updateState { $0.running = self.session.isRunning }
        }
      }
    )
  }

  deinit {
    for observer in observers {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  /// Starts the camera, setting the session up on first use. The camera permission must already be granted.
  func start(orientation: UIInterfaceOrientation) {
    let videoOrientation = Self.videoOrientation(for: orientation)
    queue.async { [weak self] in
      guard let self else { return }
      self.videoOrientation = videoOrientation
      self.wanted = true
      if !self.configured {
        self.configure()
      }
      guard !self.configurationFailed else { return }
      self.applyOrientation()
      self.filter.reset()
      self.lock.lock()
      self.faceTimes.removeAll()
      self.state.lastFaceTime = nil
      self.state.trackingFps = 0
      self.state.confidence = 0
      self.lock.unlock()
      if !self.session.isRunning {
        // Blocks until the camera runs, hence the capture queue
        self.session.startRunning()
      }
      let running = self.session.isRunning
      self.updateState { $0.running = running }
    }
  }

  /// Stops the camera, idempotent. The session stays set up for a later start.
  func stop() {
    // Holds the tracker until the camera is off, even if the player lets go of it meanwhile
    queue.async { [self] in
      self.wanted = false
      if self.session.isRunning {
        self.session.stopRunning()
      }
      self.updateState { $0.running = false }
    }
  }

  /// Stops the camera and lets go of it for good, when the player closes
  func release() {
    for observer in observers {
      NotificationCenter.default.removeObserver(observer)
    }
    observers.removeAll()
    queue.async { [self] in
      self.wanted = false
      self.metadataOutput.setMetadataObjectsDelegate(nil, queue: nil)
      if self.session.isRunning {
        self.session.stopRunning()
      }
      self.session.beginConfiguration()
      for input in self.session.inputs {
        self.session.removeInput(input)
      }
      for output in self.session.outputs {
        self.session.removeOutput(output)
      }
      self.session.commitConfiguration()
      self.configured = false
      self.updateState { $0.running = false }
    }
  }

  /// Follows a rotation of the interface, so that headX keeps growing towards the user's right
  func setInterfaceOrientation(_ orientation: UIInterfaceOrientation) {
    let videoOrientation = Self.videoOrientation(for: orientation)
    queue.async { [weak self] in
      guard let self else { return }
      guard videoOrientation != self.videoOrientation else { return }
      self.videoOrientation = videoOrientation
      self.applyOrientation()
      self.filter.reset()
    }
  }

  /// The latest state, safe to call from any thread. The tracking rate and the confidence count the faces of the
  /// last second, and drop to 0 once no face came for the lost delay.
  func snapshot() -> HeadTrackingState {
    let now = CACurrentMediaTime()
    lock.lock()
    defer { lock.unlock() }
    faceTimes.removeAll { now - $0 > 1 }
    var result = state
    if let last = faceTimes.last, now - last <= Self.lostDelay {
      result.trackingFps = Double(faceTimes.count)
      // The camera runs at 30 frames per second and the metadata output reports a face on each of them
      result.confidence = min(1, result.trackingFps / 30)
    } else {
      result.trackingFps = 0
      result.confidence = 0
    }
    return result
  }

  // MARK: - Capture queue

  private func configure() {
    configured = true
    session.beginConfiguration()
    defer { session.commitConfiguration() }

    // The smallest picture is enough to find a face and keeps the camera cheap
    if session.canSetSessionPreset(.vga640x480) {
      session.sessionPreset = .vga640x480
    }
    guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
      let input = try? AVCaptureDeviceInput(device: camera),
      session.canAddInput(input)
    else {
      markConfigurationFailed("no usable front camera")
      return
    }
    session.addInput(input)

    guard session.canAddOutput(metadataOutput) else {
      markConfigurationFailed("cannot add the metadata output")
      return
    }
    session.addOutput(metadataOutput)
    // The available types are only known once the output is attached to the camera
    guard metadataOutput.availableMetadataObjectTypes.contains(.face) else {
      markConfigurationFailed("the front camera does not detect faces")
      return
    }
    metadataOutput.metadataObjectTypes = [.face]
    metadataOutput.setMetadataObjectsDelegate(self, queue: queue)

    if session.canAddOutput(orientationOutput) {
      orientationOutput.alwaysDiscardsLateVideoFrames = true
      session.addOutput(orientationOutput)
    }
  }

  private func markConfigurationFailed(_ reason: String) {
    print("Spatial head tracking unavailable: \(reason)")
    configurationFailed = true
    updateState {
      $0.failed = true
      $0.running = false
    }
  }

  /// Sets the connection of the orientation output to an upright picture for the interface, mirrored like a mirror.
  /// Mirroring must be taken off its automatic mode first, else setting it raises an exception.
  private func applyOrientation() {
    guard let connection = orientationOutput.connection(with: .video) else { return }
    if connection.isVideoOrientationSupported {
      connection.videoOrientation = videoOrientation
    }
    if connection.isVideoMirroringSupported {
      connection.automaticallyAdjustsVideoMirroring = false
      connection.isVideoMirrored = true
    }
  }

  func metadataOutput(
    _ output: AVCaptureMetadataOutput,
    didOutput metadataObjects: [AVMetadataObject],
    from connection: AVCaptureConnection
  ) {
    let now = CACurrentMediaTime()
    // The largest face is the one closest to the screen, the viewer
    let face = metadataObjects
      .compactMap { $0 as? AVMetadataFaceObject }
      .max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
    let position = face.flatMap { horizontalPosition(of: $0) }
    lock.lock()
    if position != nil {
      faceTimes.append(now)
    }
    faceTimes.removeAll { now - $0 > 1 }
    lock.unlock()

    guard let headX = position else { return }
    let previous = snapshot().lastFaceTime
    if let previous, now - previous > Self.lostDelay {
      // A face found again after a loss starts afresh, not from where the old one was
      filter.reset()
    }
    let filtered = filter.filter(headX, at: now)
    updateState {
      $0.headX = filtered
      $0.lastFaceTime = now
      $0.running = true
    }
  }

  /// Face centre in [-0.5, 0.5], positive towards the user's right (see the class comment)
  private func horizontalPosition(of face: AVMetadataFaceObject) -> Double? {
    if let connection = orientationOutput.connection(with: .video),
      let transformed = orientationOutput.transformedMetadataObject(for: face, connection: connection)
    {
      return Self.clampedHalf(Double(transformed.bounds.midX) - 0.5)
    }
    // Without the conversion, the raw sensor coordinates. The front sensor gives an upright, unmirrored picture
    // with the interface in landscape left (as seen by the camera, the user's right is on the left of the
    // picture), and the same picture upside down in landscape right.
    let rawX = Double(face.bounds.midX)
    switch videoOrientation {
    case .landscapeLeft:
      return Self.clampedHalf(0.5 - rawX)
    case .landscapeRight:
      return Self.clampedHalf(rawX - 0.5)
    default:
      // Portrait: the sensor's long side runs along the height of the screen
      return Self.clampedHalf(Double(face.bounds.midY) - 0.5)
    }
  }

  private func sessionFailed(_ error: NSError?) {
    print("Spatial head tracking camera error: \(error?.localizedDescription ?? "unknown")")
    queue.async { [weak self] in
      guard let self else { return }
      // The media services restart on their own after a reset: the session can run again
      if error?.code == AVError.Code.mediaServicesWereReset.rawValue, self.wanted, !self.session.isRunning {
        self.session.startRunning()
      }
      let running = self.session.isRunning
      self.updateState { $0.running = running }
    }
  }

  private func updateState(_ change: (inout HeadTrackingState) -> Void) {
    lock.lock()
    change(&state)
    lock.unlock()
  }

  private static func clampedHalf(_ value: Double) -> Double {
    min(max(value, -0.5), 0.5)
  }

  /// AVCaptureVideoOrientation names the same position of the home button as UIInterfaceOrientation
  private static func videoOrientation(for orientation: UIInterfaceOrientation) -> AVCaptureVideoOrientation {
    switch orientation {
    case .landscapeLeft:
      return .landscapeLeft
    case .portrait:
      return .portrait
    case .portraitUpsideDown:
      return .portraitUpsideDown
    default:
      return .landscapeRight
    }
  }
}

/// Turns the head position into the viewpoint of the synthesised picture: 0 is the left camera, 0.5 the middle, 1
/// the right camera.
///
/// The position where the head is when tracking starts, and on Recenter, is the middle. The viewpoint then follows
/// the head with [sensitivity], within [minimum, maximum]. When the face is lost the viewpoint holds for 300 ms, then
/// eases back to the middle over a second; when it comes back, the viewpoint glides to the head instead of jumping.
struct HeadViewpoint {
  static let minimum = 0.15
  static let maximum = 0.85
  static let middle = 0.5
  static let returnDuration: CFTimeInterval = 1.0
  static let glideDuration: CFTimeInterval = 0.25

  var sensitivity = 2.0
  private(set) var value = HeadViewpoint.middle

  private var headXCenter: Double?
  // The viewpoint when the face was last seen, where the return to the middle starts
  private var lastTrackedValue = HeadViewpoint.middle
  private var tracking = false
  private var glideStart: CFTimeInterval?
  private var glideFrom = HeadViewpoint.middle

  /// The next face sample becomes the middle. Also used when tracking starts.
  mutating func recenter(now: CFTimeInterval) {
    headXCenter = nil
    startGlide(now: now)
  }

  /// Puts the viewpoint straight to [newValue], for the manual slider
  mutating func set(_ newValue: Double) {
    value = min(max(newValue, 0), 1)
    lastTrackedValue = value
    glideStart = nil
  }

  /// The viewpoint for this frame
  mutating func update(state: HeadTrackingState, now: CFTimeInterval) -> Double {
    if let faceTime = state.lastFaceTime, state.running, now - faceTime <= HeadTracker.lostDelay {
      if !tracking {
        tracking = true
        startGlide(now: now)
      }
      if headXCenter == nil {
        headXCenter = state.headX
      }
      let offset = (state.headX - (headXCenter ?? state.headX)) * sensitivity
      let target = min(max(Self.middle + offset, Self.minimum), Self.maximum)
      if let start = glideStart, now - start < Self.glideDuration {
        value = glideFrom + (target - glideFrom) * Self.smoothstep((now - start) / Self.glideDuration)
      } else {
        glideStart = nil
        value = target
      }
      lastTrackedValue = value
      return value
    }

    // No face: the last viewpoint holds for the lost delay (the time the face has been missing, measured from its
    // last sample), then eases back to the middle
    if tracking {
      tracking = false
      glideStart = nil
    }
    let lostFor = state.lastFaceTime.map { now - $0 } ?? .infinity
    let progress = min(max((lostFor - HeadTracker.lostDelay) / Self.returnDuration, 0), 1)
    value = lastTrackedValue + (Self.middle - lastTrackedValue) * Self.smoothstep(progress)
    if progress >= 1 {
      lastTrackedValue = Self.middle
    }
    return value
  }

  /// Whether the face counts as lost at [now]
  static func isLost(_ state: HeadTrackingState, now: CFTimeInterval) -> Bool {
    guard state.running, let faceTime = state.lastFaceTime else { return true }
    return now - faceTime > HeadTracker.lostDelay
  }

  private mutating func startGlide(now: CFTimeInterval) {
    glideStart = now
    glideFrom = value
  }

  private static func smoothstep(_ t: Double) -> Double {
    let x = min(max(t, 0), 1)
    return x * x * (3 - 2 * x)
  }
}
