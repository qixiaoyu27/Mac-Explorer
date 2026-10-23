import Foundation

public struct NativeSavedWindow: Codable, Sendable {
  public let locations: [String]
  public let frame: String
  public init(locations: [String], frame: String) { self.locations = locations; self.frame = frame }
}
public enum NativeSessions {
  public static let restoreAfterQuitKey = "restoreWindowsAfterQuit"
  public static func validLocation(_ value: String) -> URL? {
    guard value.utf8.count <= 32768, !value.contains("\0"), let url = URL(string: value) else { return nil }
    if url.isFileURL, url.path.hasPrefix("/"), url.query == nil, url.fragment == nil, url.user == nil, url.password == nil, url.host == nil || url.host == "" || url.host == "localhost" { return url }
    if url.scheme == "explorer", ["computer", "trash", "airdrop", "network"].contains(url.host ?? ""), url.query == nil, url.fragment == nil { return url }
    return nil
  }
  public static func load(_ defaults: UserDefaults) -> [NativeSavedWindow] {
    guard let data = defaults.data(forKey: "nativeWindows"), data.count <= 1024 * 1024, let windows = try? JSONDecoder().decode([NativeSavedWindow].self, from: data) else { return [] }
    return windows.prefix(12).map { NativeSavedWindow(locations: Array($0.locations.filter { validLocation($0) != nil }.prefix(100)), frame: String($0.frame.prefix(512))) }.filter { !$0.locations.isEmpty }
  }
  public static func save(_ windows: [NativeSavedWindow], to defaults: UserDefaults) throws {
    let valid = windows.prefix(12).map { NativeSavedWindow(locations: Array($0.locations.filter { validLocation($0) != nil }.prefix(100)), frame: String($0.frame.prefix(512))) }
    defaults.set(try JSONEncoder().encode(valid), forKey: "nativeWindows")
  }
}


/// Only the two supported landing pages can be persisted; explicit paths take precedence.
public enum NativeStartLocation: String, Sendable {
  case home, computer
  public static let preferenceKey = "startLocation"
  public static func load(_ defaults: UserDefaults) -> Self {
    defaults.string(forKey: preferenceKey).flatMap(Self.init(rawValue:)) ?? .home
  }
  public func url(home: URL) -> URL {
    self == .computer ? URL(string: "explorer://computer")! : home
  }
  public static func initialURL(explicit: String?, defaults: UserDefaults, home: URL) -> URL {
    if let explicit { return NativeSessions.validLocation(explicit) ?? URL(fileURLWithPath: explicit) }
    return load(defaults).url(home: home)
  }
}
