import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    OpenFilesChannel.shared.attach(to: flutterViewController)

    super.awakeFromNib()
  }
}

/// Hands Dart the files to open while the app runs (lib/desktop/window/single_instance.dart), on the channel the Windows
/// and Linux runners use: those the Finder opens with the app (AppDelegate) and those dropped on the window.
final class OpenFilesChannel {
  static let shared = OpenFilesChannel()

  private var channel: FlutterMethodChannel?
  // Files handed over before the window existed
  private var pending: [String] = []

  func attach(to controller: FlutterViewController) {
    channel = FlutterMethodChannel(
      name: "immuch360/instance", binaryMessenger: controller.engine.binaryMessenger)
    let dropView = FileDropView(frame: controller.view.bounds) { [weak self] paths in
      self?.open(paths)
    }
    dropView.autoresizingMask = [.width, .height]
    controller.view.addSubview(dropView)
    let waiting = pending
    pending = []
    open(waiting)
  }

  func open(_ paths: [String]) {
    if paths.isEmpty {
      return
    }
    guard let channel = channel else {
      pending.append(contentsOf: paths)
      return
    }
    channel.invokeMethod("openFiles", arguments: paths)
  }
}

/// A view over the Flutter view that takes the files and folders dropped on the window; the mouse goes through it to
/// the Flutter view.
final class FileDropView: NSView {
  private let onFiles: ([String]) -> Void

  init(frame: NSRect, onFiles: @escaping ([String]) -> Void) {
    self.onFiles = onFiles
    super.init(frame: frame)
    registerForDraggedTypes([.fileURL])
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not used")
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    return nil
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    return paths(of: sender).isEmpty ? [] : .copy
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    let dropped = paths(of: sender)
    if dropped.isEmpty {
      return false
    }
    onFiles(dropped)
    return true
  }

  private func paths(of info: NSDraggingInfo) -> [String] {
    let urls =
      info.draggingPasteboard.readObjects(
        forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    return urls.map { $0.path }
  }
}
