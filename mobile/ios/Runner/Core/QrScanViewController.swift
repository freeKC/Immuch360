import AVFoundation
import UIKit

/// The camera of the QR code scanner, apart from the view controller as HeadTracker is: the session is set up and run
/// on its own queue, and [onCode] gets the text of the first QR code read, on the main queue, once.
final class QrCaptureSession: NSObject, AVCaptureMetadataOutputObjectsDelegate {
  let session = AVCaptureSession()
  private let queue = DispatchQueue(label: "app.alextran.immich.pairing.qr-scan")
  private let metadataOutput = AVCaptureMetadataOutput()
  private var configured = false
  private var delivered = false
  private let onCode: (String) -> Void
  private let onFailure: () -> Void

  init(onCode: @escaping (String) -> Void, onFailure: @escaping () -> Void) {
    self.onCode = onCode
    self.onFailure = onFailure
    super.init()
  }

  /// Sets the camera up on first use and starts it. The camera permission must already be granted.
  func start() {
    queue.async { [weak self] in
      guard let self = self else { return }
      if !self.configured {
        guard self.configure() else {
          DispatchQueue.main.async { self.onFailure() }
          return
        }
        self.configured = true
      }
      if !self.session.isRunning {
        // Blocks until the camera runs, hence the queue
        self.session.startRunning()
      }
    }
  }

  /// Stops the camera; holds the object until it is off
  func stop() {
    queue.async { [self] in
      self.metadataOutput.setMetadataObjectsDelegate(nil, queue: nil)
      if self.session.isRunning {
        self.session.stopRunning()
      }
    }
  }

  private func configure() -> Bool {
    guard let camera = AVCaptureDevice.default(for: .video),
      let input = try? AVCaptureDeviceInput(device: camera)
    else {
      return false
    }
    session.beginConfiguration()
    defer { session.commitConfiguration() }
    guard session.canAddInput(input), session.canAddOutput(metadataOutput) else {
      return false
    }
    session.addInput(input)
    session.addOutput(metadataOutput)
    // Set once the output is in the session, which tells which types the camera reads
    guard metadataOutput.availableMetadataObjectTypes.contains(.qr) else {
      return false
    }
    metadataOutput.metadataObjectTypes = [.qr]
    metadataOutput.setMetadataObjectsDelegate(self, queue: queue)
    return true
  }

  func metadataOutput(
    _ output: AVCaptureMetadataOutput,
    didOutput metadataObjects: [AVMetadataObject],
    from connection: AVCaptureConnection
  ) {
    guard !delivered else { return }
    for object in metadataObjects {
      if let code = object as? AVMetadataMachineReadableCodeObject, code.type == .qr, let text = code.stringValue {
        delivered = true
        let onCode = self.onCode
        DispatchQueue.main.async { onCode(text) }
        return
      }
    }
  }
}

/// A full screen camera view that reads one QR code, with the prompt of Flutter above a Cancel button. [onDone] gets
/// the text of the first code read, or nil when the user cancelled or the camera could not start; it is called once.
final class QrScanViewController: UIViewController {
  private let prompt: String
  private let cancelLabel: String
  private var onDone: ((String?) -> Void)?
  private var capture: QrCaptureSession?

  init(prompt: String, cancelLabel: String, onDone: @escaping (String?) -> Void) {
    self.prompt = prompt
    self.cancelLabel = cancelLabel
    self.onDone = onDone
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not used")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black

    let capture = QrCaptureSession(
      onCode: { [weak self] text in self?.done(text) },
      onFailure: { [weak self] in self?.done(nil) }
    )
    self.capture = capture
    let preview = AVCaptureVideoPreviewLayer(session: capture.session)
    preview.videoGravity = .resizeAspectFill
    preview.frame = view.bounds
    view.layer.addSublayer(preview)

    let label = UILabel()
    label.text = prompt
    label.textColor = .white
    label.textAlignment = .center
    label.numberOfLines = 0
    label.font = UIFont.preferredFont(forTextStyle: .headline)
    label.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(label)

    var configuration = UIButton.Configuration.filled()
    configuration.title = cancelLabel
    configuration.baseBackgroundColor = UIColor(white: 0, alpha: 0.6)
    configuration.baseForegroundColor = .white
    configuration.cornerStyle = .capsule
    configuration.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 24, bottom: 10, trailing: 24)
    let cancel = UIButton(configuration: configuration)
    cancel.translatesAutoresizingMaskIntoConstraints = false
    cancel.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
    view.addSubview(cancel)

    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
      label.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
      label.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
      cancel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      cancel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
    ])

    capture.start()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    view.layer.sublayers?.compactMap { $0 as? AVCaptureVideoPreviewLayer }.forEach { $0.frame = view.bounds }
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    capture?.stop()
  }

  @objc private func cancelTapped() {
    done(nil)
  }

  private func done(_ text: String?) {
    guard let onDone = onDone else { return }
    self.onDone = nil
    dismiss(animated: true) {
      onDone(text)
    }
  }
}
