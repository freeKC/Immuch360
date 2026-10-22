import AVFoundation
import UIKit

/// A full screen camera view that reads one QR code (AVCaptureMetadataOutput, done by the camera hardware), with the
/// prompt of Flutter above a Cancel button. [onDone] gets the text of the first code read, or nil when the user
/// cancelled or the camera could not start; it is called once.
final class QrScanViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
  private let prompt: String
  private let cancelLabel: String
  private var onDone: ((String?) -> Void)?
  private let session = AVCaptureSession()
  private let sessionQueue = DispatchQueue(label: "immuch360.qr-scan")
  private var previewLayer: AVCaptureVideoPreviewLayer?

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

    let preview = AVCaptureVideoPreviewLayer(session: session)
    preview.videoGravity = .resizeAspectFill
    view.layer.addSublayer(preview)
    previewLayer = preview

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

    sessionQueue.async { [weak self] in
      self?.configureSession()
    }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    previewLayer?.frame = view.bounds
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    let session = self.session
    sessionQueue.async {
      if session.isRunning {
        session.stopRunning()
      }
    }
  }

  private func configureSession() {
    guard let camera = AVCaptureDevice.default(for: .video),
      let input = try? AVCaptureDeviceInput(device: camera),
      session.canAddInput(input)
    else {
      DispatchQueue.main.async { [weak self] in self?.done(nil) }
      return
    }
    session.beginConfiguration()
    session.addInput(input)
    let output = AVCaptureMetadataOutput()
    guard session.canAddOutput(output) else {
      session.commitConfiguration()
      DispatchQueue.main.async { [weak self] in self?.done(nil) }
      return
    }
    session.addOutput(output)
    output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
    // Set once the output is in the session, which tells which types the camera reads
    if output.availableMetadataObjectTypes.contains(.qr) {
      output.metadataObjectTypes = [.qr]
    }
    session.commitConfiguration()
    session.startRunning()
  }

  func metadataOutput(
    _ output: AVCaptureMetadataOutput,
    didOutput metadataObjects: [AVMetadataObject],
    from connection: AVCaptureConnection
  ) {
    for object in metadataObjects {
      if let code = object as? AVMetadataMachineReadableCodeObject, code.type == .qr, let text = code.stringValue {
        done(text)
        return
      }
    }
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
