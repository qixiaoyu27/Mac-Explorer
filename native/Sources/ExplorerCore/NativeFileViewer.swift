import Foundation
import CoreFoundation

public struct NativeFileViewerState {
  public let enabled: Bool
  public let canRestore: Bool
  public let error: String
  public let canEnable: Bool
  public let staleViewer: Bool
}

public final class NativeFileViewer {
  // NSFileViewer is a compatibility preference, not a complete Finder replacement.
  public static let promptSuppressedKey = "fileViewerPromptSuppressed"
  private let appID = "local.macexplorer.native-prototype"
  let domain = "com.apple.LaunchServices/com.apple.launchservices.secure" as CFString
  let key = "NSFileViewer" as CFString
  private let testFile: URL?
  private let backupURL: URL
  private let appExists: (String) -> Bool
  public init(backupURL: URL, fixture: URL? = nil, failFirstWrite: Bool = false, appExists: @escaping (String) -> Bool = { _ in true }) { self.backupURL = backupURL; self.testFile = fixture; self.failNextWrite = fixture != nil && failFirstWrite; self.appExists = appExists }
  private var ours: [[String: Any]] { [["LSHandlerContentType": "public.folder", "LSHandlerRoleAll": appID]] }
  let missingBackup = "缺少有效的原设置备份，无法自动恢复。"
  let conflict = "文件查看器设置已被其他应用更改，已停止操作以保留这些更改。"
  func failure(_ message: String) -> NSError { NSError(domain: "MacExplorer.FileViewer", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
  func same(_ a: Any?, _ b: Any?) -> Bool { (a as? NSObject ?? NSNull()).isEqual(b as? NSObject ?? NSNull()) }
  func folders(_ records: [[String: Any]]) -> [[String: Any]] { records.filter { ($0["LSHandlerContentType"] as? String) == "public.folder" } }
  // A viewer preference survives its application's removal, and AppKit then falls back to Finder.
  func stale(_ value: Any?) -> Bool {
    guard let id = value as? String, !id.isEmpty, id != "-", id != appID else { return false }
    return !appExists(id)
  }
  func staleHandler(_ record: [String: Any]) -> Bool { record.contains { $0.key.hasPrefix("LSHandlerRole") && stale($0.value) } }
  func enableBlocker(before: [String: Any], original: [[String: Any]], owned: Bool, backup: [String: Any]?, backupError: String) -> String? {
    if !backupError.isEmpty { return backupError }
    guard let backup else {
      return !same(before["global"], appID) && !folders(original).contains(where: { $0.values.contains { same($0, appID) } }) ? nil : missingBackup
    }
    return owned || (same(before["global"], backup["global"]) && same(folders(original), previousFolders(backup))) ? nil : conflict
  }
  func read() throws -> [String: Any] {
    if let file = testFile {
      guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
      guard let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: file), format: nil) as? [String: Any] else { throw failure("无法读取文件查看器设置。") }
      return value
    }
    var result: [String: Any] = [:]
    result["global"] = CFPreferencesCopyValue(key, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    result["handlers"] = CFPreferencesCopyAppValue("LSHandlers" as CFString, domain)
    return result
  }
  func records(_ state: [String: Any]) throws -> [[String: Any]] {
    if state["handlers"] == nil { return [] }
    guard let value = state["handlers"] as? [[String: Any]] else { throw failure("无法读取文件查看器设置。") }
    return value
  }
  private var failNextWrite: Bool
  func write(_ state: [String: Any]) throws {
    if let file = testFile {
      if failNextWrite {
        failNextWrite = false
        var partial = try read(); partial["global"] = state["global"]
        try PropertyListSerialization.data(fromPropertyList: partial, format: .xml, options: 0).write(to: file, options: .atomic)
        throw failure("无法保存文件查看器设置。")
      }
      try PropertyListSerialization.data(fromPropertyList: state, format: .xml, options: 0).write(to: file, options: .atomic)
      return
    }
    CFPreferencesSetValue(key, state["global"] as CFPropertyList?, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    CFPreferencesSetAppValue("LSHandlers" as CFString, state["handlers"] as CFPropertyList?, domain)
    let globalOK = CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    let foldersOK = CFPreferencesAppSynchronize(domain)
    guard globalOK && foldersOK else { throw failure("无法保存文件查看器设置。") }
  }
  func apply(_ next: [String: Any], before: [String: Any]) throws {
    do {
      try write(next)
      guard same(try read(), next) else { throw failure("无法保存文件查看器设置。") }
    } catch {
      try? write(before)
      guard same(try read(), before) else { throw failure("保存失败且未能完整恢复，请保留原设置备份并重试。") }
      throw error
    }
  }
  func loadBackup(_ url: URL) throws -> [String: Any] {
    guard (try url.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { throw failure(missingBackup) }
    guard let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any],
      let globalExists = value["globalExists"] as? Bool, value["handlersExist"] is Bool,
      let entries = value["folders"] as? [[String: Any]],
      globalExists == (value["global"] != nil), (!globalExists || value["global"] is String),
      entries.allSatisfy({ ($0["index"] as? Int).map { $0 >= 0 } == true && ($0["value"] as? [String: Any])?["LSHandlerContentType"] as? String == "public.folder" }) else { throw failure(missingBackup) }
    return value
  }
  func previousFolders(_ backup: [String: Any]) -> [[String: Any]] { (backup["folders"] as! [[String: Any]]).map { $0["value"] as! [String: Any] } }
  public func perform(_ action: String) throws -> NativeFileViewerState {
    guard ["status", "enable", "restore"].contains(action) else { throw failure("无效的文件查看器设置。") }
    let before = try read()
    let original = try records(before)
    let owned = same(before["global"], appID) && same(folders(original), ours)
    var backup: [String: Any]?
    var backupError = ""
    if FileManager.default.fileExists(atPath: backupURL.path) {
      do { backup = try loadBackup(backupURL) } catch { backupError = missingBackup }
    }
    if action == "enable" {
      if let blocker = enableBlocker(before: before, original: original, owned: owned, backup: backup, backupError: backupError) { throw failure(blocker) }
      if backup == nil {
        var value: [String: Any] = ["globalExists": before["global"] != nil, "handlersExist": before["handlers"] != nil,
          "folders": original.enumerated().filter { ($0.element["LSHandlerContentType"] as? String) == "public.folder" }.map { ["index": $0.offset, "value": $0.element] as [String: Any] }]
        value["global"] = before["global"]
        try FileManager.default.createDirectory(at: backupURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0).write(to: backupURL, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
        backup = value
      }
      var next = before; next["global"] = appID
      next["handlers"] = original.filter { ($0["LSHandlerContentType"] as? String) != "public.folder" } + ours
      try apply(next, before: before)
    } else if action == "restore" {
      guard let backup else { throw failure(missingBackup) }
      guard owned else { throw failure(conflict) }
      var next = before
      next["global"] = stale(backup["global"]) ? nil : backup["global"]
      var restored = original.filter { ($0["LSHandlerContentType"] as? String) != "public.folder" }
      for entry in backup["folders"] as! [[String: Any]] where !staleHandler(entry["value"] as! [String: Any]) { restored.insert(entry["value"] as! [String: Any], at: min(entry["index"] as! Int, restored.count)) }
      next["handlers"] = restored.isEmpty && !(backup["handlersExist"] as! Bool) ? nil : restored
      try apply(next, before: before)
      try FileManager.default.removeItem(at: backupURL)
    }
    let state = try read(); let current = try records(state)
    let enabled = same(state["global"], appID) || folders(current).contains { $0.values.contains { same($0, appID) } }
    let canRestore = same(state["global"], appID) && same(folders(current), ours) && (try? loadBackup(backupURL)) != nil
    let message = enabled && !canRestore ? (backupError.isEmpty && backup != nil ? conflict : missingBackup) : ""
    var blockerBackup: [String: Any]?, blockerError = ""
    if FileManager.default.fileExists(atPath: backupURL.path) {
      do { blockerBackup = try loadBackup(backupURL) } catch { blockerError = missingBackup }
    }
    let currentOwned = same(state["global"], appID) && same(folders(current), ours)
    let canEnable = !enabled && enableBlocker(before: state, original: current, owned: currentOwned, backup: blockerBackup, backupError: blockerError) == nil
    return NativeFileViewerState(enabled: enabled, canRestore: canRestore, error: message, canEnable: canEnable, staleViewer: !enabled && (stale(state["global"]) || folders(current).contains(where: staleHandler)))
  }
  // Ask on each launch until the user opts out, and only from the bundle these preferences would point at.
  public func shouldPromptAtLaunch(suppressed: Bool, bundleID: String?) -> Bool {
    guard !suppressed, bundleID == appID, let state = try? perform("status") else { return false }
    return state.canEnable
  }
}
