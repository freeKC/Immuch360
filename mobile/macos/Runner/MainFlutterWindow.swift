import Cocoa
import FlutterMacOS
import Network

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    OpenFilesChannel.shared.attach(to: flutterViewController)
    NetworkCostChannel.shared.attach(to: flutterViewController)
    SessionPresenceChannel.shared.attach(to: flutterViewController)

    super.awakeFromNib()
  }
}

/// Tells Dart when the session locks or unlocks and when the displays sleep or wake
/// (lib/desktop/window/session_presence.dart), on the channel the Windows runner uses: the webcam of Spatial 2.5D
/// closes while nobody can be in front of the computer.
final class SessionPresenceChannel {
  static let shared = SessionPresenceChannel()

  private var channel: FlutterMethodChannel?
  private var observers: [(NotificationCenter, NSObjectProtocol)] = []

  func attach(to controller: FlutterViewController) {
    channel = FlutterMethodChannel(
      name: "immuch360/session", binaryMessenger: controller.engine.binaryMessenger)
    let distributed = DistributedNotificationCenter.default()
    let workspace = NSWorkspace.shared.notificationCenter
    for (center, name, message) in [
      (distributed as NotificationCenter, Notification.Name("com.apple.screenIsLocked"), "locked"),
      (distributed as NotificationCenter, Notification.Name("com.apple.screenIsUnlocked"), "unlocked"),
      (workspace, NSWorkspace.screensDidSleepNotification, "displayOff"),
      (workspace, NSWorkspace.screensDidWakeNotification, "displayOn"),
    ] {
      let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        self?.channel?.invokeMethod(message, arguments: nil)
      }
      observers.append((center, observer))
    }
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

/// Tells Dart whether the connection is metered now (lib/desktop/platform/metered_connection.dart): an expensive path
/// (an iPhone hotspot) or a constrained one (Low Data Mode). The AI components never update by themselves on one.
final class NetworkCostChannel {
  static let shared = NetworkCostChannel()

  private let monitor = NWPathMonitor()
  private let queue = DispatchQueue(label: "immuch360.network-cost")
  // Read and written on the queue only
  private var path: NWPath?
  private var channel: FlutterMethodChannel?

  func attach(to controller: FlutterViewController) {
    monitor.pathUpdateHandler = { [weak self] path in
      self?.path = path
    }
    monitor.start(queue: queue)
    let channel = FlutterMethodChannel(
      name: "immuch360/network", binaryMessenger: controller.engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "isMetered" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let self = self else {
        result(nil)
        return
      }
      self.queue.async {
        let current = self.path ?? self.monitor.currentPath
        // macOS 12 at least (the deployment target): isConstrained is there
        let metered = current.isExpensive || current.isConstrained
        DispatchQueue.main.async {
          result(NSNumber(value: metered))
        }
      }
    }
    self.channel = channel
  }
}
