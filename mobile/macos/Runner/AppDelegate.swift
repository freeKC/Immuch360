import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  // Files opened with the app from the Finder ("Open with", a file dropped on the icon of the app): macOS starts the
  // app, or brings the copy that runs to the front, and hands them over here. They go to Dart as the files of a later
  // start (lib/desktop/window/single_instance.dart); any other URL goes on to the plugins, as FlutterAppDelegate does.
  override func application(_ application: NSApplication, open urls: [URL]) {
    let others = urls.filter { !$0.isFileURL }
    if !others.isEmpty {
      super.application(application, open: others)
    }
    OpenFilesChannel.shared.open(urls.filter { $0.isFileURL }.map { $0.path })
  }
}
