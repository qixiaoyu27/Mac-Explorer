import Foundation

public struct FileSearchResult: Sendable {
  public let entries: [FileEntry]
  public let truncated: Bool
  public let skipped: Int
}
public enum FileSearchMode: String, Sendable {
  case text, wildcard, regex
}

public enum FileSearchScope: String, CaseIterable, Sendable { case folder, descendants }
public enum FileSearchKind: String, CaseIterable, Sendable { case any, file, folder, image, video, document, archive }
public enum FileSearchDate: String, CaseIterable, Sendable { case any, today, week, month }
public enum FileSearchSize: String, CaseIterable, Sendable { case any, empty, small, medium, large }

public struct FileSearchFilters: Equatable, Sendable {
  public var scope: FileSearchScope
  public var kind: FileSearchKind
  public var date: FileSearchDate
  public var size: FileSearchSize
  public var tag: String

  public init(scope: FileSearchScope = .descendants, kind: FileSearchKind = .any, date: FileSearchDate = .any, size: FileSearchSize = .any, tag: String = "") {
    self.scope = scope; self.kind = kind; self.date = date; self.size = size; self.tag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public var isDefault: Bool { self == FileSearchFilters() }
  public var propertyList: [String: String] { ["scope": scope.rawValue, "kind": kind.rawValue, "date": date.rawValue, "size": size.rawValue, "tag": tag] }
  public init(propertyList: Any?) {
    let values = propertyList as? [String: String] ?? [:]
    self.init(scope: FileSearchScope(rawValue: values["scope"] ?? "") ?? .descendants,
              kind: FileSearchKind(rawValue: values["kind"] ?? "") ?? .any,
              date: FileSearchDate(rawValue: values["date"] ?? "") ?? .any,
              size: FileSearchSize(rawValue: values["size"] ?? "") ?? .any,
              tag: values["tag"] ?? "")
  }

  public func matches(_ entry: FileEntry, now: Date = Date()) -> Bool {
    guard matchesKind(entry), matchesDate(entry, now: now), matchesSize(entry) else { return false }
    return tag.isEmpty || FinderTags.matches(entry.url, query: tag)
  }

  private func matchesKind(_ entry: FileEntry) -> Bool {
    switch kind {
    case .any: return true
    case .file: return !entry.isDirectory
    case .folder: return entry.isDirectory && !entry.isPackage
    case .image: return ["png", "jpg", "jpeg", "heic", "gif", "webp", "tif", "tiff", "bmp", "svg"].contains(entry.url.pathExtension.lowercased())
    case .video: return ["mp4", "mov", "m4v", "mkv", "avi", "webm"].contains(entry.url.pathExtension.lowercased())
    case .document: return ["pdf", "txt", "md", "rtf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "csv", "pages", "numbers", "key"].contains(entry.url.pathExtension.lowercased())
    case .archive: return ["zip", "zipx", "7z", "rar", "tar", "tgz", "tbz", "tbz2", "txz", "gz", "bz2", "xz"].contains(entry.url.pathExtension.lowercased())
    }
  }

  private func matchesDate(_ entry: FileEntry, now: Date) -> Bool {
    guard date != .any else { return true }
    guard let value = entry.modified else { return false }
    let calendar = Calendar.current
    switch date {
    case .any: return true
    case .today: return calendar.isDate(value, inSameDayAs: now)
    case .week: return value >= calendar.date(byAdding: .day, value: -7, to: now)!
    case .month: return value >= calendar.date(byAdding: .day, value: -30, to: now)!
    }
  }

  private func matchesSize(_ entry: FileEntry) -> Bool {
    guard size != .any else { return true }
    guard !entry.isDirectory else { return false }
    switch size {
    case .any: return true
    case .empty: return entry.size == 0
    case .small: return entry.size > 0 && entry.size < 10 * 1024 * 1024
    case .medium: return entry.size >= 10 * 1024 * 1024 && entry.size < 100 * 1024 * 1024
    case .large: return entry.size >= 100 * 1024 * 1024
    }
  }
}

public enum FileSearch {
  public static func search(in directory: URL, query: String, showHidden: Bool, mode: FileSearchMode = .text, filters: FileSearchFilters = .init()) throws -> FileSearchResult {
    let expression: NSRegularExpression?
    if query.isEmpty || mode == .text { expression = nil } else {
      let pattern = mode == .wildcard
        ? "\\A" + query.map { $0 == "*" ? ".*" : $0 == "?" ? "." : NSRegularExpression.escapedPattern(for: String($0)) }.joined() + "\\z"
        : query
      do { expression = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) }
      catch { throw NSError(domain: "FileSearch", code: 1, userInfo: [NSLocalizedDescriptionKey: NL("正则表达式无效")]) }
    }
    var queue = [directory], cursor = 0, visited = 0, skipped = 0
    var matches: [FileEntry] = []
    while cursor < queue.count && visited < 30_000 && matches.count < 1_000 {
      try Task.checkCancellation()
      let current = queue[cursor]; cursor += 1
      let snapshot: DirectorySnapshot
      do { snapshot = try DirectoryReader.read(current) }
      catch is CancellationError { throw CancellationError() }
      catch { if cursor == 1 { throw error }; skipped += 1; continue }
      skipped += snapshot.skippedCount
      for entry in snapshot.entries where showHidden || !entry.isHidden {
        try Task.checkCancellation(); visited += 1
        let matched: Bool
        if let expression {
          var found = false, timedOut = false
          let started = ProcessInfo.processInfo.systemUptime
          expression.enumerateMatches(in: entry.name, options: .reportProgress, range: NSRange(entry.name.startIndex..., in: entry.name)) { result, _, stop in
            if Task.isCancelled || ProcessInfo.processInfo.systemUptime - started > 0.05 {
              timedOut = true; stop.pointee = true
            } else if result != nil { found = true; stop.pointee = true }
          }
          try Task.checkCancellation()
          if timedOut { throw NSError(domain: "FileSearch", code: 2, userInfo: [NSLocalizedDescriptionKey: NL("搜索表达式过于复杂")]) }
          matched = found
        } else { matched = query.isEmpty || entry.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        if matched && filters.matches(entry) { matches.append(entry) }
        if filters.scope == .descendants && entry.isDirectory && !entry.isSymbolicLink && !entry.isPackage { queue.append(entry.url) }
        if visited >= 30_000 || matches.count >= 1_000 { break }
      }
    }
    return FileSearchResult(entries: matches, truncated: visited >= 30_000 || matches.count >= 1_000, skipped: skipped)
  }
}
