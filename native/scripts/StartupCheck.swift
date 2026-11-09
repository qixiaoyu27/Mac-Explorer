import AppKit
import CoreGraphics

struct StartupFailure: Error, CustomStringConvertible {
  let description: String
}

func waitUntil(_ description: String, timeout: TimeInterval = 10, _ ready: () -> Bool) throws {
  let deadline = Date().addingTimeInterval(timeout)
  while !ready() {
    guard Date() < deadline else { throw StartupFailure(description: description) }
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
  }
}

func visibleWindow(for app: NSRunningApplication) -> [String: Any]? {
  let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
  return windows.first { window in
    guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier,
      (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
      let bounds = window[kCGWindowBounds as String] as? [String: Any],
      let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double
    else { return false }
    return width >= 900 && height >= 500
  }
}

@main
enum StartupCheck {
  static func main() {
    do {
      guard CommandLine.arguments.count == 3 else {
        throw StartupFailure(description: "Usage: startup-check <app bundle> <fixture directory>")
      }
      let appURL = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
      guard let bundleID = Bundle(url: appURL)?.bundleIdentifier else {
        throw StartupFailure(description: "Application bundle has no identifier")
      }
      guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty else {
        throw StartupFailure(description: "Close the native prototype before the startup check; existing instances are not terminated")
      }
      let executableFixture = FileManager.default.temporaryDirectory.appendingPathComponent("native-executable-reveal-" + UUID().uuidString)
      try FileManager.default.createDirectory(at: executableFixture, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: executableFixture) }
      let executable = executableFixture.appendingPathComponent("Windows fixture.exe")
      let contents = Data("MZ\0Windows executable reveal fixture".utf8)
      try contents.write(to: executable)
      var checks: [[String: Any]] = []
      let launches: [(arguments: [String], documents: [String])] = [
        ([], []), (["--path", CommandLine.arguments[2]], []), ([], []), ([], [executable.path]),
      ]
      for (index, launch) in launches.enumerated() {
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        launcher.arguments = ["-n", "-a", appURL.path] + launch.documents + (launch.arguments.isEmpty ? [] : ["--args"] + launch.arguments)
        try launcher.run()
        launcher.waitUntilExit()
        guard launcher.terminationStatus == 0 else { throw StartupFailure(description: "open failed") }
        var launched: NSRunningApplication?
        try waitUntil("Normal launch never produced a running application (attempt \(index + 1))") {
          launched = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
          return launched != nil
        }
        guard let app = launched else { throw StartupFailure(description: "Application disappeared") }
        app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        var completed = false
        defer {
          if !completed {
            let owned = (CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []).filter { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier }.map { ["bounds": $0[kCGWindowBounds as String] ?? [:], "onscreen": $0[kCGWindowIsOnscreen as String] ?? false, "layer": $0[kCGWindowLayer as String] ?? -1] }
            fputs("Startup diagnostic: pid=\(app.processIdentifier) terminated=\(app.isTerminated) hidden=\(app.isHidden) active=\(app.isActive) windows=\(owned)\n", stderr)
          }
          if !app.isTerminated { _ = app.terminate() }
        }
        try waitUntil("Normal launch never displayed a usable window (attempt \(index + 1))") {
          app.isTerminated || visibleWindow(for: app) != nil
        }
        guard !app.isTerminated else { throw StartupFailure(description: "Application crashed before showing its window") }
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
          guard !app.isTerminated, visibleWindow(for: app) != nil else {
            throw StartupFailure(description: "Normal application exited or lost its window during the stability check")
          }
          RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        checks.append([
          "attempt": index + 1,
          "arguments": launch.arguments,
          "documents": launch.documents,
          "pid": app.processIdentifier,
          "windowVisibleForSeconds": 3,
          "windowBounds": visibleWindow(for: app)?[kCGWindowBounds as String] ?? [:],
        ])
        guard app.terminate() else { throw StartupFailure(description: "Could not close the test-launched app") }
        try waitUntil("Application did not exit normally") { app.isTerminated }
        completed = true
      }
      guard try Data(contentsOf: executable) == contents else { throw StartupFailure(description: "Executable reveal changed its source file") }
      let data = try JSONSerialization.data(withJSONObject: ["passed": true, "launches": checks], options: [.prettyPrinted, .sortedKeys])
      print(String(decoding: data, as: UTF8.self))
    } catch {
      fputs("Normal startup check failed: \(error)\n", stderr)
      exit(1)
    }
  }
}
