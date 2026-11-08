import Foundation

private final class UpdateFixtureProtocol: URLProtocol {
  static var responses: [String: Data] = [:]
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let payload = Self.responses[request.url!.absoluteString]
    let response = HTTPURLResponse(url: request.url!, statusCode: payload == nil ? 404 : 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": String(payload?.count ?? 0)])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    if let payload { client?.urlProtocol(self, didLoad: payload) }
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

@main
struct SystemChecks {
  static func main() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("NativeSystemChecks-" + UUID().uuidString).resolvingSymlinksInPath()
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    var checks = 0
    func check(_ condition: @autoclosure () throws -> Bool, _ name: String) throws { guard try condition() else { throw NSError(domain: "Check", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }; checks += 1 }
    func rejected(_ name: String, _ action: () throws -> Void) throws { do { try action() } catch { checks += 1; return }; throw NSError(domain: "Check", code: 1, userInfo: [NSLocalizedDescriptionKey: "Accepted " + name]) }
    func write(_ value: [String: Any], _ url: URL) throws { try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0).write(to: url, options: .atomic) }
    func read(_ url: URL) throws -> NSDictionary { try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as! NSDictionary }
    let suite = "NativeUpdateScheduleChecks." + UUID().uuidString
    let preferences = UserDefaults(suiteName: suite)!
    defer { preferences.removePersistentDomain(forName: suite) }
    let now = Date(timeIntervalSince1970: 1_000_000)
    try check(NativeUpdateFrequency.saved(in: preferences) == .daily, "Default frequency is daily")
    for frequency in NativeUpdateFrequency.allCases {
      preferences.set(frequency.rawValue, forKey: NativeUpdateFrequency.preferenceKey)
      try check(NativeUpdateFrequency.saved(in: UserDefaults(suiteName: suite)!) == frequency, "Frequency persists")
      try check(frequency.isDue(lastCheck: nil, now: now, launching: true) == (frequency != .never), "First launch policy")
    }
    for (frequency, interval) in [(NativeUpdateFrequency.daily, 86_400.0), (.weekly, 604_800.0)] {
      try check(!frequency.isDue(lastCheck: now.addingTimeInterval(-interval + 1), now: now, launching: true), "Do not check early after restart")
      try check(frequency.isDue(lastCheck: now.addingTimeInterval(-interval), now: now, launching: false), "Check at interval while running")
      try check(frequency.isDue(lastCheck: now.addingTimeInterval(1), now: now, launching: false), "Recover from clock rollback")
    }
    try check(!NativeUpdateFrequency.launch.isDue(lastCheck: nil, now: now, launching: false), "Every launch does not repeat while running")
    try check(!NativeUpdateFrequency.never.isDue(lastCheck: nil, now: now, launching: false), "Never suppresses periodic checks")
    let system = root.appendingPathComponent("system.plist"), backup = root.appendingPathComponent("backup.plist")
    let original: [String: Any] = ["global":"local.macexplorer.desktop", "handlers":[["LSHandlerContentType":"public.folder","LSHandlerRoleAll":"local.macexplorer.desktop"], ["LSHandlerContentType":"public.text","LSHandlerRoleAll":"editor.app"]]]
    try write(original, system)
    let viewer = NativeFileViewer(backupURL: backup, fixture: system)
    try check(!viewer.perform("status").enabled, "Electron viewer is independent")
    try check(viewer.perform("enable").canRestore, "Enable with restorable backup")
    try check(read(system)["global"] as? String == "local.macexplorer.native-prototype", "Native bundle id")
    _ = try viewer.perform("enable")
    _ = try viewer.perform("restore")
    try check(read(system).isEqual(to: original), "Restore all original associations")
    try check(!fm.fileExists(atPath: backup.path), "Remove completed backup")
    let failing = NativeFileViewer(backupURL: backup, fixture: system, failFirstWrite: true)
    try rejected("partial preference save") { _ = try failing.perform("enable") }
    try check(read(system).isEqual(to: original), "Rollback partial preference write")
    _ = try viewer.perform("enable")
    var concurrent = try read(system) as! [String: Any]
    concurrent["global"] = "other.app"; try write(concurrent, system)
    try rejected("changed default viewer") { _ = try viewer.perform("restore") }
    try check(read(system).isEqual(to: concurrent), "Do not override another app")
    try check(fm.fileExists(atPath: backup.path), "Retain recovery backup on conflict")
    try fm.removeItem(at: backup); try write(original, system)
    let unsafeBackup = root.appendingPathComponent("unsafe-backup")
    try fm.createSymbolicLink(at: backup, withDestinationURL: unsafeBackup)
    try rejected("symlink backup") { _ = try viewer.perform("enable") }
    try check(read(system).isEqual(to: original), "Symlink rejection preserves preferences")
    try fm.removeItem(at: backup)
    let native = "local.macexplorer.native-prototype"
    let dead: Set<String> = ["com.removed.viewer", "com.removed.folders"]
    let aware = NativeFileViewer(backupURL: backup, fixture: system, appExists: { !dead.contains($0) })
    try check(aware.shouldPromptAtLaunch(suppressed: false, bundleID: native), "Prompt when another working viewer is set")
    try check(!aware.perform("status").staleViewer, "Working viewer is not stale")
    try check(!aware.shouldPromptAtLaunch(suppressed: true, bundleID: native), "Don't ask again suppresses the prompt")
    try check(!aware.shouldPromptAtLaunch(suppressed: false, bundleID: "local.macexplorer.native-validation"), "Validation bundle never prompts")
    try check(!aware.shouldPromptAtLaunch(suppressed: false, bundleID: nil), "Unknown bundle never prompts")
    try check(!fm.fileExists(atPath: backup.path) && read(system).isEqual(to: original), "Prompt decision writes nothing")
    let staleOriginal: [String: Any] = ["global":"com.removed.viewer", "handlers":[["LSHandlerContentType":"public.folder","LSHandlerRoleAll":"com.removed.folders"], ["LSHandlerContentType":"public.folder","LSHandlerRoleViewer":"com.apple.finder"], ["LSHandlerContentType":"public.text","LSHandlerRoleAll":"editor.app"]]]
    try write(staleOriginal, system)
    try check(aware.perform("status").staleViewer && aware.perform("status").canEnable, "Removed viewer is stale and replaceable")
    try check(aware.shouldPromptAtLaunch(suppressed: false, bundleID: native), "Prompt when the viewer was removed")
    try check(aware.perform("enable").canRestore, "Enable over a removed viewer")
    try check(read(system)["global"] as? String == native, "Enable replaces a removed viewer")
    try check(!aware.perform("status").canEnable && !aware.perform("status").staleViewer, "Enabled viewer needs no prompt")
    try check(!aware.shouldPromptAtLaunch(suppressed: false, bundleID: native), "Enabled viewer never prompts")
    _ = try aware.perform("restore")
    let afterStale = try read(system)
    try check(afterStale["global"] == nil, "Restore clears a removed viewer so Finder takes over")
    let staleHandlers = afterStale["handlers"] as! [[String: Any]]
    try check(staleHandlers.count == 2 && !staleHandlers.contains { $0["LSHandlerRoleAll"] as? String == "com.removed.folders" } && staleHandlers.contains { $0["LSHandlerRoleViewer"] as? String == "com.apple.finder" } && staleHandlers.contains { $0["LSHandlerRoleAll"] as? String == "editor.app" }, "Restore drops only removed folder handlers")
    try check(!fm.fileExists(atPath: backup.path), "Restore over a removed viewer completes")
    try write(original, system)
    _ = try aware.perform("enable")
    var taken = try read(system) as! [String: Any]
    taken["global"] = "other.app"; try write(taken, system)
    try check(!aware.shouldPromptAtLaunch(suppressed: false, bundleID: native), "Conflict with retained backup never prompts")
    try check(read(system).isEqual(to: taken), "Conflict prompt decision preserves the other app")
    try fm.removeItem(at: backup)
    try check(NativeUpdateValidation.compare("0.9.9", "1.0.0") == -1, "Major version update")
    try check(NativeUpdateValidation.compare("1.10.0", "1.2.9") == 1, "Numeric minor ordering")
    try rejected("invalid version") { _ = try NativeUpdateValidation.compare("1.0.0-beta", "1.0.0") }
    let version = "1.2.3", archive = "Mac-Explorer-Native-1.2.3-mac-arm64.zip", base = "https://github.com/qixiaoyu27/Mac-Explorer/releases/download/v1.2.3/"
    var release: [String: Any] = ["tag_name":"v" + version,"draft":false,"prerelease":false,"assets":[["name":archive,"size":120,"browser_download_url":base+archive], ["name":"SHA256SUMS-native.txt","size":100,"browser_download_url":base+"SHA256SUMS-native.txt"]]]
    func parsed() throws -> NativeRelease { try NativeUpdateValidation.release(JSONSerialization.data(withJSONObject: release)) }
    try check(parsed().version == version && parsed().bytes == 120, "Native release accepted")
    release["draft"] = true; try rejected("draft release") { _ = try parsed() }; release["draft"] = false
    release["prerelease"] = true; try rejected("prerelease") { _ = try parsed() }; release["prerelease"] = false
    let nativeAssets = release["assets"]!
    release["assets"] = [["name":"Mac-Explorer-1.2.3-mac-arm64.zip","size":120,"browser_download_url":base+"Mac-Explorer-1.2.3-mac-arm64.zip"]]
    try rejected("Electron archive") { _ = try parsed() }; release["assets"] = nativeAssets
    var assets = release["assets"] as! [[String: Any]]
    assets[0]["browser_download_url"] = "https://example.com/" + archive; release["assets"] = assets
    try rejected("foreign asset URL") { _ = try parsed() }; release["assets"] = nativeAssets
    assets = release["assets"] as! [[String: Any]]; assets.append(assets[0]); release["assets"] = assets
    try rejected("duplicate asset") { _ = try parsed() }; release["assets"] = nativeAssets
    assets = release["assets"] as! [[String: Any]]; assets[0]["size"] = true; release["assets"] = assets
    try rejected("boolean asset size") { _ = try parsed() }; release["assets"] = nativeAssets
    let hash = String(repeating: "a", count: 64)
    try check(NativeUpdateValidation.checksum(hash+"  "+archive+"\n", archive: archive) == hash, "SHA256 exact asset")
    try rejected("duplicate checksum") { _ = try NativeUpdateValidation.checksum(hash+"  "+archive+"\n"+hash+"  "+archive, archive: archive) }
    try rejected("wrong checksum asset") { _ = try NativeUpdateValidation.checksum(hash+"  electron.zip", archive: archive) }
    try rejected("invalid bundle") { try NativeUpdateValidation.validateApp(root.appendingPathComponent("Mac Explorer.app")) }
    let app = root.appendingPathComponent(NativeUpdateValidation.appName)
    try fm.createDirectory(at: app, withIntermediateDirectories: true)
    try Data("payload".utf8).write(to: app.appendingPathComponent("payload"))
    let zip = root.appendingPathComponent("valid.zip")
    _ = try NativeCommand.run(executable: "/usr/bin/ditto", arguments: ["-c","-k","--norsrc","--keepParent",app.path,zip.path])
    try NativeUpdateValidation.validateArchive(zip); checks += 1
    try fm.createSymbolicLink(at: app.appendingPathComponent("unsafe"), withDestinationURL: root)
    let linked = root.appendingPathComponent("linked.zip")
    _ = try NativeCommand.run(executable: "/usr/bin/ditto", arguments: ["-c","-k","--norsrc","--keepParent",app.path,linked.path])
    try rejected("symlink archive") { try NativeUpdateValidation.validateArchive(linked) }
    let foreign = root.appendingPathComponent("foreign.zip"), file = root.appendingPathComponent("outside")
    try Data("outside".utf8).write(to: file)
    _ = try NativeCommand.run(executable: "/usr/bin/ditto", arguments: ["-c","-k","--norsrc","--keepParent",file.path,foreign.path])
    try rejected("foreign archive path") { try NativeUpdateValidation.validateArchive(foreign) }
    let code = root.appendingPathComponent("main.c")
    try Data("int main(void) { return 0; }\n".utf8).write(to: code)
    let executable = root.appendingPathComponent("fixture-executable")
    _ = try NativeCommand.run(executable: "/usr/bin/clang", arguments: ["-arch", "arm64", code.path, "-o", executable.path])
    func signedApp(_ directory: String, version: String) throws -> URL {
      let app = root.appendingPathComponent(directory).appendingPathComponent(NativeUpdateValidation.appName)
      try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
      try fm.createDirectory(at: app.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
      try fm.copyItem(at: executable, to: app.appendingPathComponent("Contents/MacOS/MacExplorerNative"))
      try write(["CFBundleIdentifier": NativeUpdateValidation.bundleID, "CFBundleExecutable": "MacExplorerNative", "CFBundleShortVersionString": version, "CFBundlePackageType":"APPL"], app.appendingPathComponent("Contents/Info.plist"))
      for name in ["install-native.sh", "update-native.sh"] { try Data("#!/bin/bash\nexit 0\n".utf8).write(to: app.appendingPathComponent("Contents/Resources/" + name)) }
      _ = try NativeCommand.run(executable: "/usr/bin/codesign", arguments: ["--force", "--sign", "-", app.path])
      return app
    }
    let installed = try signedApp("installed", version: "1.0.0"), replacement = try signedApp("replacement", version: "1.2.3")
    let updateZip = root.appendingPathComponent(archive)
    _ = try NativeCommand.run(executable: "/usr/bin/ditto", arguments: ["-c", "-k", "--norsrc", "--keepParent", replacement.path, updateZip.path])
    let updateBytes = try Data(contentsOf: updateZip)
    let digest = try NativeCommand.run(executable: "/usr/bin/shasum", arguments: ["-a", "256", updateZip.path]).text.split(separator: " ").first!
    var available = release
    var availableAssets = nativeAssets as! [[String: Any]]; availableAssets[0]["size"] = updateBytes.count
    available["assets"] = availableAssets
    UpdateFixtureProtocol.responses = [
      "https://api.github.com/repos/qixiaoyu27/Mac-Explorer/releases?per_page=100": try JSONSerialization.data(withJSONObject: [available]),
      base + archive: updateBytes,
      base + "SHA256SUMS-native.txt": Data("\(digest)  \(archive)\n".utf8),
    ]
    let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [UpdateFixtureProtocol.self]
    let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
    let cache = root.appendingPathComponent("cache"), updates = NativeUpdates(version: "1.0.0", app: installed, cache: cache, session: session)
    await updates.check()
    let checkedState = await updates.state
    try check(checkedState.status == "available", "Fixture update available")
    await updates.download()
    let downloaded = await updates.state
    try check(downloaded.status == "ready", "Signed Native update downloaded and verified: " + downloaded.error)
    try check(downloaded.downloaded == Int64(updateBytes.count), "Download exact size")
    try check((try read(installed.appendingPathComponent("Contents/Info.plist")))["CFBundleShortVersionString"] as? String == "1.0.0", "Download never replaces running application")
    let installer = try await updates.installer()
    let beforeLaunch = await updates.state
    try check(beforeLaunch.status == "ready", "Preparing installer does not begin installation")
    let preparedDirectories = try fm.contentsOfDirectory(at: cache, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("download-") }
    try check(preparedDirectories.allSatisfy { !fm.fileExists(atPath: $0.appendingPathComponent("install.log").path) }, "No installer spawned before termination acceptance")
    do { try installer.launch(pid: 0); fatalError("Accepted invalid PID") } catch { checks += 1 }
    try Data("1\n".utf8).write(to: cache.appendingPathComponent("last-install-result"))
    let restored = NativeUpdates(version: "1.0.0", app: installed, cache: cache, session: session)
    let restoredState = await restored.state
    try check(!restoredState.error.isEmpty, "Restore installer failure after restart")
    UpdateFixtureProtocol.responses[base + "SHA256SUMS-native.txt"] = Data("\(String(repeating: "0", count: 64))  \(archive)\n".utf8)
    let failed = NativeUpdates(version: "1.0.0", app: installed, cache: root.appendingPathComponent("failed-cache"), session: session)
    await failed.check(); await failed.download()
    let failedState = await failed.state
    try check(failedState.status == "error", "Checksum mismatch never becomes ready")
    print("Native update/file-viewer checks passed: \(checks); all defaults writes used temporary fixtures.")
  }
}
