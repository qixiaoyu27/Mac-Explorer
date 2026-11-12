import Foundation

public enum EntrySort: String, CaseIterable, Sendable {
  case name
  case modified
  case created
  case added
  case size
  case kind
}

public enum EntryQuery {
  public static func apply(
    _ entries: [FileEntry],
    showHidden: Bool,
    query: String,
    sort: EntrySort,
    ascending: Bool,
    foldersFirst: Bool = true
  ) -> [FileEntry] {
    let locale = NativeLanguage.formatLocale
    let textOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
    let nameOptions: String.CompareOptions = [.numeric, .caseInsensitive, .diacriticInsensitive]
    let kinds: [String: String] = sort == .kind ? Dictionary(entries.map { ($0.id, $0.kind) }, uniquingKeysWith: { first, _ in first }) : [:]
    return entries.filter { entry in
      (showHidden || !entry.isHidden)
        && (query.isEmpty || entry.name.range(of: query, options: textOptions, locale: locale) != nil)
    }.sorted { left, right in
      if foldersFirst && left.isDirectory != right.isDirectory { return left.isDirectory }

      var order: ComparisonResult
      switch sort {
      case .name:
        order = left.name.compare(right.name, options: nameOptions, locale: locale)
      case .modified, .created, .added:
        let leftDate = sort == .added ? left.added : sort == .created ? left.created : left.modified
        let rightDate = sort == .added ? right.added : sort == .created ? right.created : right.modified
        switch (leftDate, rightDate) {
        case let (leftDate?, rightDate?): order = compare(leftDate, rightDate)
        case (nil, .some): order = .orderedAscending
        case (.some, nil): order = .orderedDescending
        case (nil, nil): order = .orderedSame
        }
      case .size:
        order = compare(left.size, right.size)
      case .kind:
        order = (kinds[left.id] ?? left.kind).compare(kinds[right.id] ?? right.kind, options: nameOptions, locale: locale)
      }
      if order == .orderedSame {
        order = left.name.compare(right.name, options: nameOptions, locale: locale)
      }
      if order == .orderedSame {
        order = left.url.path.compare(right.url.path, options: .literal)
      }
      return ascending ? order == .orderedAscending : order == .orderedDescending
    }
  }

  private static func compare<Value: Comparable>(_ left: Value, _ right: Value) -> ComparisonResult {
    if left < right { return .orderedAscending }
    if left > right { return .orderedDescending }
    return .orderedSame
  }
}
