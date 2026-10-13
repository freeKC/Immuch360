// Asks Launch Services which apps open a file of each extension, as Finder does for "Open with", and checks that the
// app given is one of them. Run on the macOS runner after the build, once the app is registered (lsregister -f):
//
//   swift open_with.swift "<path>/Immuch360 Desktop.app" jpg insv ...
//
// The files are empty: Launch Services types them by their extension, as Finder lists them.
import AppKit

let arguments = CommandLine.arguments
guard arguments.count > 2, let wanted = Bundle(url: URL(fileURLWithPath: arguments[1]))?.bundleIdentifier else {
    print("usage: open_with.swift <app> <extension> ...")
    exit(2)
}
let folder = FileManager.default.temporaryDirectory.appendingPathComponent("immuch360-open-with")
try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
var missing: [String] = []
for ext in arguments.dropFirst(2) {
    let file = folder.appendingPathComponent("sample.\(ext)")
    FileManager.default.createFile(atPath: file.path, contents: Data())
    let apps = NSWorkspace.shared.urlsForApplications(toOpen: file)
    let offered = apps.contains { Bundle(url: $0)?.bundleIdentifier == wanted }
    let current = NSWorkspace.shared.urlForApplication(toOpen: file).flatMap { Bundle(url: $0)?.bundleIdentifier } ?? "none"
    print(".\(ext): \(offered ? "offered" : "not offered"), \(apps.count) apps, default \(current)")
    if !offered {
        missing.append(ext)
    }
}
if !missing.isEmpty {
    print("\(wanted) is not offered for: \(missing.joined(separator: " "))")
    exit(1)
}
print("\(wanted) is offered for the \(arguments.count - 2) extensions")
