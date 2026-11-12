import Foundation

@main
struct CoreValidation {
  static func main() async throws {
    let manager = FileManager.default
    let root = manager.temporaryDirectory.appendingPathComponent("ExplorerCoreValidation-\(UUID().uuidString)")
    try manager.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? manager.removeItem(at: root) }
    let folder = root.appendingPathComponent("folder")
    let package = root.appendingPathComponent("Example.app")
    try manager.createDirectory(at: folder, withIntermediateDirectories: true)
    try manager.createDirectory(at: package, withIntermediateDirectories: true)
    let payload = Data("unchanged data".utf8)
    let file = root.appendingPathComponent("notes.txt")
    try payload.write(to: file)
    try payload.write(to: folder.appendingPathComponent("nested.txt"))
    try payload.write(to: root.appendingPathComponent(".hidden"))
    let modified = Date(timeIntervalSince1970: 1_700_000_000)
    try manager.setAttributes([.modificationDate: modified, .posixPermissions: 0o640], ofItemAtPath: file.path)
    for (name, target) in ["file-link": file, "folder-link": folder, "package-link": package,
      "broken-link": root.appendingPathComponent("missing")] {
      try manager.createSymbolicLink(at: root.appendingPathComponent(name), withDestinationURL: target)
    }
    try manager.createSymbolicLink(atPath: root.appendingPathComponent("relative-link").path, withDestinationPath: "folder")
    let added = Date(timeIntervalSince1970: 1_710_000_000)
    try (file as NSURL).setResourceValue(added, forKey: .addedToDirectoryDateKey)
    let beforePaths = try manager.subpathsOfDirectory(atPath: root.path).sorted()
    let beforeAttributes = try manager.attributesOfItem(atPath: file.path)
    let beforeLinks = try ["file-link", "folder-link", "package-link", "broken-link", "relative-link"].map {
      try manager.destinationOfSymbolicLink(atPath: root.appendingPathComponent($0).path)
    }
    var count = 0
    func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
      guard try condition() else { throw NSError(domain: "Validation", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }
      count += 1
    }
    let snapshot = try DirectoryReader.read(root)
    let entries = Dictionary(uniqueKeysWithValues: snapshot.entries.map { ($0.name, $0) })
    try check(snapshot.directory == root, "Snapshot directory")
    try check(snapshot.entries.count == 9, "Nonrecursive entry count")
    try check(snapshot.skippedCount == 0, "Skipped metadata")
    try check(snapshot.elapsedMilliseconds >= 0 && snapshot.elapsedMilliseconds.isFinite, "Elapsed timing")
    try check(entries["notes.txt"]?.size == Int64(payload.count), "File size")
    try check(entries["notes.txt"]?.modified == modified, "Modification date")
    try check(entries["notes.txt"]?.added == added, "Directory read uses the system added date independently of modification date")
    try check(try FileSearch.search(in: root, query: "notes", showHidden: false).entries.first?.added == added, "Search preserves added dates")
    try check(entries["notes.txt"]?.kind == "文本文档", "File kind")
    try check(entries["folder"]?.kind == "文件夹", "Directory kind")
    try check(entries["folder"]?.size == 0, "Directory size")
    try check(entries[".hidden"]?.isHidden == true, "Hidden files")
    try check(entries["Example.app"]?.isDirectory == true && entries["Example.app"]?.isPackage == true, "Package directory")
    try check(entries["file-link"]?.isSymbolicLink == true && entries["file-link"]?.isDirectory == false, "File link")
    try check(entries["folder-link"]?.isSymbolicLink == true && entries["folder-link"]?.isDirectory == true, "Directory link")
    try check(entries["package-link"]?.isSymbolicLink == true && entries["package-link"]?.isPackage == true, "Package link")
    try check(entries["broken-link"]?.isSymbolicLink == true && entries["broken-link"]?.isDirectory == false, "Broken link visible")
    try check(entries["relative-link"]?.isSymbolicLink == true && entries["relative-link"]?.isDirectory == true, "Relative directory link")
    let link = root.appendingPathComponent("folder-link")
    let linkedSnapshot = try DirectoryReader.read(link)
    try check(linkedSnapshot.directory == link, "Directory link snapshot path")
    try check(linkedSnapshot.entries.map(\.name) == ["nested.txt"], "Directory link browsing")
    try check(linkedSnapshot.entries.first?.url.path == link.appendingPathComponent("nested.txt").path, "Directory link child path")
    try check(try Data(contentsOf: linkedSnapshot.entries[0].url) == payload, "Directory link child contents")
    for url in [URL(string: "https://example.invalid/")!, URL(string: "file://remote.invalid/folder")!,
      URL(string: "file:relative")!, URL(string: "relative")!, URL(string: "child", relativeTo: root)!,
      URL(string: "file:///tmp/folder?query")!, URL(string: "file:///tmp/folder#fragment")!,
      root.appendingPathComponent("missing"), file, root.appendingPathComponent("broken-link"), root.appendingPathComponent("file-link")] {
      var rejected = false
      do { _ = try DirectoryReader.read(url) } catch { rejected = true }
      try check(rejected, "Invalid input rejected: \(url)")
    }
    func entry(_ name: String, folder: Bool = false, size: Int64 = 0, modified: Double? = nil, created: Double? = nil, added: Double? = nil,
      hidden: Bool = false, path: String? = nil) -> FileEntry {
      FileEntry(url: root.appendingPathComponent(path ?? name), name: name, isDirectory: folder,
        isSymbolicLink: false, isPackage: false, size: size,
        modified: modified.map { Date(timeIntervalSince1970: $0) }, isHidden: hidden, created: created.map { Date(timeIntervalSince1970: $0) }, added: added.map { Date(timeIntervalSince1970: $0) })
    }
    func names(_ entries: [FileEntry], sort: EntrySort = .name, ascending: Bool = true, foldersFirst: Bool = true) -> [String] {
      EntryQuery.apply(entries, showHidden: true, query: "", sort: sort, ascending: ascending, foldersFirst: foldersFirst).map(\.name)
    }
    let sortEntries = [entry("file10"), entry("folder10", folder: true), entry("file2"), entry("folder2", folder: true)]
    try check(names(sortEntries) == ["folder2", "folder10", "file2", "file10"], "Natural ascending folders first")
    try check(names(sortEntries, ascending: false) == ["folder10", "folder2", "file10", "file2"], "Natural descending folders first")
    for sort in EntrySort.allCases {
      for ascending in [true, false] {
        let sorted = EntryQuery.apply(sortEntries, showHidden: true, query: "", sort: sort, ascending: ascending)
        try check(sorted.map(\.isDirectory) == [true, true, false, false], "Folders first: \(sort) \(ascending)")
      }
    }
    let sizes = [entry("item10", size: 10), entry("large", size: 100), entry("item2", size: 10), entry("small", size: 1)]
    try check(names(sizes, sort: .size) == ["small", "item2", "item10", "large"], "Size ascending")
    try check(names(sizes, sort: .size, ascending: false) == ["large", "item10", "item2", "small"], "Size descending")
    let dates = [entry("new", modified: 200), entry("unknown"), entry("old10", modified: 100), entry("old2", modified: 100)]
    try check(names(dates, sort: .modified) == ["unknown", "old2", "old10", "new"], "Modified ascending")
    try check(names(dates, sort: .modified, ascending: false) == ["new", "old10", "old2", "unknown"], "Modified descending")
    let created = [entry("new", modified: -100, created: 200), entry("unknown", modified: 999),
      entry("old10", created: 100), entry("old2", created: 100), entry("epoch", created: 0), entry("early", created: -1)]
    try check(names(created, sort: .created) == ["unknown", "early", "epoch", "old2", "old10", "new"], "Created ascending keeps missing, early and epoch dates distinct")
    try check(names(created, sort: .created, ascending: false) == ["new", "old10", "old2", "epoch", "early", "unknown"], "Created descending with natural name ties")
    let creationFolders = [entry("file", created: -1), entry("folder", folder: true, created: 100)]
    for ascending in [true, false] {
      try check(names(creationFolders, sort: .created, ascending: ascending) == ["folder", "file"], "Created sort keeps folders first with different dates")
    }
    let addedDates = [entry("new", modified: -100, created: -100, added: 200), entry("unknown", modified: 999, created: 999),
      entry("old10", added: 100), entry("old2", added: 100), entry("folder", folder: true, added: 150)]
    try check(names(addedDates, sort: .added, ascending: false) == ["folder", "new", "old10", "old2", "unknown"], "Added sort preserves folders-first default and does not substitute missing dates")
    try check(names(addedDates, sort: .added, ascending: false, foldersFirst: false) == ["new", "folder", "old10", "old2", "unknown"], "Mixed added-date descending and natural ties")
    try check(names(addedDates, sort: .added, foldersFirst: false) == ["unknown", "old2", "old10", "folder", "new"], "Mixed added-date ascending")
    try check(names(creationFolders, sort: .created, foldersFirst: false) == ["file", "folder"], "Folders-first can be disabled for creation dates")
    try check(names(sortEntries, foldersFirst: false) == ["file2", "file10", "folder2", "folder10"], "Folders-first can be disabled for names")
    let sameNames = [entry("same", created: 1, path: "b/same"), entry("same", created: 1, path: "a/same")]
    for ascending in [true, false] {
      let result = EntryQuery.apply(sameNames, showHidden: true, query: "", sort: .created, ascending: ascending)
      try check(result.map(\.url) == (ascending ? sameNames.reversed().map(\.url) : sameNames.map(\.url)), "Created equal names use literal paths")
    }
    let kinds = [entry("z.txt"), entry("z.jpg"), entry("a.txt"), entry("a.jpg")]
    try check(names(kinds, sort: .kind) == ["a.txt", "z.txt", "a.jpg", "z.jpg"], "Localized kind ascending")
    try check(names(kinds, sort: .kind, ascending: false) == ["z.jpg", "a.jpg", "z.txt", "a.txt"], "Localized kind descending")
    let ties = [entry("Résumé.txt", path: "c/Résumé.txt"), entry("resume.txt", path: "a/resume.txt"), entry("RESUME.txt", path: "b/RESUME.txt")]
    for sort in EntrySort.allCases {
      let ascending = EntryQuery.apply(ties, showHidden: true, query: "", sort: sort, ascending: true)
      let reversedInput = EntryQuery.apply(Array(ties.reversed()), showHidden: true, query: "", sort: sort, ascending: true)
      let descending = EntryQuery.apply(ties, showHidden: true, query: "", sort: sort, ascending: false)
      try check(ascending.map(\.name) == ["resume.txt", "RESUME.txt", "Résumé.txt"], "Literal tie path order \(sort)")
      try check(ascending == reversedInput, "Tie input independence \(sort)")
      try check(descending == Array(ascending.reversed()), "Tie reversed order \(sort)")
    }
    let filtering = [entry("Résumé.txt"), entry("RESUME draft.txt", hidden: true), entry("other.txt", path: "resume/other.txt")]
    try check(EntryQuery.apply(filtering, showHidden: false, query: "resume", sort: .name, ascending: true).map(\.name) == ["Résumé.txt"], "Hidden and insensitive filter")
    try check(EntryQuery.apply(filtering, showHidden: true, query: "RÉSUMÉ", sort: .name, ascending: true).count == 2, "Show hidden and insensitive filter")
    try check(EntryQuery.apply(filtering, showHidden: false, query: "", sort: .name, ascending: true).count == 2, "Empty query")
    try check(EntryQuery.apply(filtering, showHidden: true, query: "missing", sort: .name, ascending: true).isEmpty, "No matches")
    let cancelled = Task.detached { () throws -> DirectorySnapshot in
      withUnsafeCurrentTask { $0?.cancel() }
      return try DirectoryReader.read(root)
    }
    var cancellation = false
    do { _ = try await cancelled.value } catch is CancellationError { cancellation = true }
    try check(cancellation, "Cancellation propagation")
    try check(try manager.subpathsOfDirectory(atPath: root.path).sorted() == beforePaths, "Fixture paths preserved")
    try check(try Data(contentsOf: file) == payload, "Fixture contents preserved")
    let afterAttributes = try manager.attributesOfItem(atPath: file.path)
    try check(afterAttributes[.modificationDate] as? Date == beforeAttributes[.modificationDate] as? Date, "Fixture date preserved")
    try check(afterAttributes[.posixPermissions] as? NSNumber == beforeAttributes[.posixPermissions] as? NSNumber, "Fixture permissions preserved")
    let afterLinks = try ["file-link", "folder-link", "package-link", "broken-link", "relative-link"].map {
      try manager.destinationOfSymbolicLink(atPath: root.appendingPathComponent($0).path)
    }
    try check(afterLinks == beforeLinks, "Fixture links preserved")
    print("PASS: \(count) standalone ExplorerCore assertions (not XCTest).")
  }
}
