import AppKit
import ExplorerCore

@main enum NavigationUIChecks {
  @MainActor static func main() async {
    do {
      NSApplication.shared.setActivationPolicy(.prohibited)
      NativeLanguage.load(from: URL(fileURLWithPath: CommandLine.arguments[1])); NativeLanguage.mode = "zh-CN"
      let checks = try await NativeNavigationStateChecks.run(showsWindows: false) + NativeWorkflowChecks.run(output: URL(fileURLWithPath: CommandLine.arguments[2])) + NativeSearchTagChecks.run()
      precondition(!NSApp.windows.contains { $0.isVisible }, "Headless checks displayed a window")
      try JSONSerialization.data(withJSONObject: ["passed": true, "checks": checks], options: [.prettyPrinted]).write(to: URL(fileURLWithPath: CommandLine.arguments[2]).appendingPathComponent("report.json"))
    } catch { fputs("NavigationUIChecks FAILED: \(error)\n", stderr); exit(1) }
  }
}
