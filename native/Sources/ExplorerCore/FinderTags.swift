import Foundation
import Darwin

/// Read Finder tag metadata only when explicitly requested.
public enum FinderTags {
  public static func names(at url: URL) throws -> [String] {
    return normalize(try storedNames(at: url))
  }

  public static func commonNames(in urls: [URL]) throws -> [String] {
    guard let first = urls.first else { return [] }
    var common = Set(try names(at: first))
    for url in urls.dropFirst() { common.formIntersection(try names(at: url)) }
    return common.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
  }

  public static func set(_ names: [String], on urls: [URL], replacing initial: [String]) -> FileActionResult {
    let normalized = normalize(names)
    let removed = Set(normalize(initial).map(key)).subtracting(normalized.map(key))
    var succeeded: [URL] = [], errors: [String] = []
    for url in urls {
      do {
        let current = try storedNames(at: url)
        var updated = current.filter { !removed.contains(key($0)) }
        var existing = Set(updated.map(key))
        updated += normalized.filter { existing.insert(key($0)).inserted }.map { $0 + "\n0" }
        if updated != current { try write(updated, to: url) }
        succeeded.append(url)
      } catch { errors.append("\(url.path)：\(error.localizedDescription)") }
    }
    return FileActionResult(succeeded: succeeded, errors: errors, changes: [])
  }

  public static func matches(_ url: URL, query: String) -> Bool {
    let wanted = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !wanted.isEmpty else { return true }
    return (try? names(at: url))?.contains { $0.range(of: wanted, options: [.caseInsensitive, .diacriticInsensitive]) != nil } == true
  }

  public static func normalize(_ values: [String]) -> [String] {
    var seen = Set<String>(), result: [String] = []
    for value in values {
      // Finder's colored-tag representation can append a newline and color id.
      let name = value.split(separator: "\n", maxSplits: 1).first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !name.isEmpty, name.count <= 255 else { continue }
      if seen.insert(key(name)).inserted { result.append(name) }
    }
    return Array(result.prefix(30))
  }

  private static func key(_ value: String) -> String {
    String(value.split(separator: "\n", maxSplits: 1).first ?? "").trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
  }

  private static func storedNames(at url: URL) throws -> [String] {
    let attribute = "com.apple.metadata:_kMDItemUserTags"
    let count = url.path.withCString { Darwin.getxattr($0, attribute, nil, 0, 0, 0) }
    if count == -1 && errno == ENOATTR { return [] }
    guard count >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    var data = Data(count: count)
    let read = data.withUnsafeMutableBytes { buffer in
      url.path.withCString { Darwin.getxattr($0, attribute, buffer.baseAddress, count, 0, 0) }
    }
    guard read >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    data.count = read
    guard let names = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String] else { throw CocoaError(.propertyListReadCorrupt) }
    return names
  }

  private static func write(_ names: [String], to url: URL) throws {
    // The Swift URL overlay makes tagNames read-only. Finder itself persists
    // this metadata as a binary property-list extended attribute.
    let path = url.path
    if names.isEmpty {
      let result = path.withCString { Darwin.removexattr($0, "com.apple.metadata:_kMDItemUserTags", 0) }
      guard result == 0 || errno == ENOATTR else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
      return
    }
    let data = try PropertyListSerialization.data(fromPropertyList: names, format: .binary, options: 0)
    let result = data.withUnsafeBytes { buffer in
      path.withCString { Darwin.setxattr($0, "com.apple.metadata:_kMDItemUserTags", buffer.baseAddress, data.count, 0, 0) }
    }
    guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
  }
}
