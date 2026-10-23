import Foundation
import CoreServices

public struct FinderServer: Codable, Equatable, Sendable {
  public let address: String
  public let name: String
  public init(address: String, name: String) { self.address = address; self.name = name }
}
public struct FinderServersResult: Sendable {
  public let servers: [FinderServer]
  public let skipped: Int
}
public enum FinderServersReader {
  /// Import offline SMB addresses only. Never resolve DNS, mount a share or retain URL credentials.
  public static func filter(_ candidates: [FinderServer], skipped: Int = 0) -> FinderServersResult {
    var seen = Set<String>(), servers: [FinderServer] = [], skipped = skipped
    for candidate in candidates {
      guard candidate.address.utf8.count <= 2048,
            !candidate.address.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
            var components = URLComponents(string: candidate.address), components.scheme?.lowercased() == "smb" else { skipped += 1; continue }
      components.user = nil; components.password = nil; components.scheme = "smb"
      components.host = components.host?.lowercased()
      if components.port == 445 { components.port = nil }
      if components.path == "/" { components.path = "" }
      guard let value = components.string, let url = try? NativeNetwork.validate(value) else { skipped += 1; continue }
      let address = url.absoluteString
      guard seen.insert(address).inserted else { continue }
      let proposed = candidate.name.trimmingCharacters(in: .whitespacesAndNewlines)
      let name = proposed.isEmpty || proposed.contains("://") || proposed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) ? (url.host ?? address) : String(proposed.prefix(512))
      servers.append(FinderServer(address: address, name: name))
    }
    return FinderServersResult(servers: servers, skipped: skipped)
  }
  /// Modern Finder stores the list in a bounded keyed archive. Decode only Foundation
  /// value classes; bookmark resolution explicitly forbids UI and volume mounting.
  public static func decodeSnapshot(_ data: Data) throws -> FinderServersResult {
    guard data.count <= 4 * 1024 * 1024,
          let archive = try NSKeyedUnarchiver.unarchivedObject(ofClasses: [NSDictionary.self, NSArray.self, NSString.self, NSData.self, NSNumber.self, NSDate.self, NSUUID.self], from: data) as? [String: Any],
          let items = archive["items"] as? [[String: Any]], items.count <= 2000 else { throw readFailure() }
    var candidates: [FinderServer] = [], skipped = 0
    for item in items {
      var stale = false
      guard let bookmark = item["Bookmark"] as? Data,
            let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale) else { skipped += 1; continue }
      candidates.append(FinderServer(address: url.absoluteString, name: item["Name"] as? String ?? ""))
    }
    return filter(candidates, skipped: skipped)
  }
  private static func readFailure() -> NSError {
    NSError(domain: "FinderServers", code: 1, userInfo: [NSLocalizedDescriptionKey: NL("无法读取 Finder 收藏的服务器。")])
  }
  private static func readArchive() throws -> FinderServersResult? {
    let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/com.apple.sharedfilelist")
    for version in [4, 3, 2] {
      let file = directory.appendingPathComponent("com.apple.LSSharedFileList.FavoriteServers.sfl\(version)")
      guard FileManager.default.fileExists(atPath: file.path) else { continue }
      // Prefer the newest present snapshot; never substitute an older stale list on failure.
      let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
      let data = try handle.read(upToCount: 4 * 1024 * 1024 + 1) ?? Data()
      return try decodeSnapshot(data)
    }
    return nil
  }
  public static func read() throws -> FinderServersResult {
    // Same read-only deprecated SharedFileList API as folder favorites. The server-list
    // identifier is exported by SharedFileList but absent from the Swift SDK overlay.
    let identifier = "com.apple.LSSharedFileList.FavoriteServers" as CFString
    guard let list = LSSharedFileListCreate(nil, identifier, nil)?.takeRetainedValue(),
          let snapshot = LSSharedFileListCopySnapshot(list, nil)?.takeRetainedValue() as? [LSSharedFileListItem] else {
      if let archive = try readArchive() { return archive }; throw readFailure()
    }
    // Recent macOS versions can return an empty legacy snapshot despite populated .sfl4 data.
    if snapshot.isEmpty, let archive = try readArchive() { return archive }
    var candidates: [FinderServer] = [], skipped = 0
    let flags = UInt32(kLSSharedFileListNoUserInteraction | kLSSharedFileListDoNotMountVolumes)
    for item in snapshot {
      guard let url = LSSharedFileListItemCopyResolvedURL(item, flags, nil)?.takeRetainedValue() as URL? else { skipped += 1; continue }
      candidates.append(FinderServer(address: url.absoluteString, name: LSSharedFileListItemCopyDisplayName(item).takeRetainedValue() as String))
    }
    return filter(candidates, skipped: skipped)
  }
}
public enum NativeServerFavorites {
  public static let preferenceKey = "finderServerFavorites"
  public static let didChange = Notification.Name("NativeServerFavoritesChanged")
  public static func load(_ defaults: UserDefaults) -> [FinderServer] {
    guard let data = defaults.data(forKey: preferenceKey), data.count <= 4 * 1024 * 1024,
          let saved = try? JSONDecoder().decode([FinderServer].self, from: data) else { return [] }
    return FinderServersReader.filter(Array(saved.prefix(500))).servers
  }
  @discardableResult
  public static func merge(_ incoming: [FinderServer], into defaults: UserDefaults) throws -> Int {
    let existing = load(defaults)
    let merged = Array(FinderServersReader.filter(existing + incoming).servers.prefix(500))
    try save(merged, to: defaults)
    return merged.count - existing.count
  }
  public static func remove(_ address: String, from defaults: UserDefaults) throws {
    try save(load(defaults).filter { $0.address != address }, to: defaults)
  }
  private static func save(_ servers: [FinderServer], to defaults: UserDefaults) throws {
    defaults.set(try JSONEncoder().encode(servers), forKey: preferenceKey)
    NotificationCenter.default.post(name: didChange, object: defaults)
  }
}
