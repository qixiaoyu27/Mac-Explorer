import Foundation

@main
enum ArchiveChecks {
  static func main() throws {
    let fm = FileManager.default
    let root = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
    func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
      guard try condition() else { throw NSError(domain: "ArchiveChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    func rejects(_ label: String, _ operation: () throws -> Void) throws {
      do { try operation() } catch { return }
      throw NSError(domain: "ArchiveChecks", code: 2, userInfo: [NSLocalizedDescriptionKey: "Expected rejection: \(label)"])
    }
    func folder(_ name: String) throws -> URL {
      let url = root.appendingPathComponent(name); try fm.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    let sources = try folder("sources")
    let nested = sources.appendingPathComponent("资料 目录", isDirectory: true)
    try fm.createDirectory(at: nested, withIntermediateDirectories: true)
    let document = nested.appendingPathComponent("报价 ' $ (一).txt")
    let content = Data("archive source preserved ✓".utf8)
    try content.write(to: document)
    try Data("hidden".utf8).write(to: nested.appendingPathComponent(".hidden"))
    let empty = nested.appendingPathComponent("empty", isDirectory: true)
    try fm.createDirectory(at: empty, withIntermediateDirectories: false)
    let archive = try NativeArchives.compress([nested, document, nested])
    try check(archive.lastPathComponent == "资料 目录.zip", "compression name")
    let again = try NativeArchives.compress([nested])
    try check(again.lastPathComponent == "资料 目录 (2).zip", "compression collisions are exclusive")
    try check(try Data(contentsOf: document) == content, "source preservation")
    let preview = try NativeArchives.preview(archive)
    let member = "资料 目录/" + document.lastPathComponent
    try check(preview.entries.contains(where: { $0.path == member && !$0.directory }), "unicode member listing")
    let destination = try folder("extracted")
    let encodedArchive = root.appendingPathComponent("encodings.zip"), encodedTarget = try folder("encodings")
    let encodedEntries = try NativeArchives.preview(encodedArchive).entries.map(\.path)
    try check(Set(encodedEntries) == ["资料/标记.txt", "资料/未标记.txt", "UTF8/élève.txt", "UTF8/naïve.txt", "données/café.txt"], "UTF-8 flagged, unflagged and CP437 members retain their names in the same ZIP")
    let encodedResult = try NativeArchives.extract(encodedArchive, to: encodedTarget)
    try check(encodedResult.errors.isEmpty, "mixed ZIP filename encodings extract")
    for (name, contents) in [("资料/标记.txt", "flagged UTF-8"), ("资料/未标记.txt", "unflagged UTF-8"), ("UTF8/élève.txt", "accented UTF-8"), ("UTF8/naïve.txt", "unflagged accented UTF-8"), ("données/café.txt", "CP437")] {
      try check(try Data(contentsOf: encodedTarget.appendingPathComponent(name)) == Data(contents.utf8), "decoded filename retains its exact data")
    }
    let encodedSelection = try folder("encoded-selection")
    try check(try NativeArchives.extract(encodedArchive, to: encodedSelection, selected: ["données/café.txt", "UTF8/élève.txt", "UTF8/naïve.txt"]).errors.isEmpty, "accented UTF-8 and decoded CP437 members can be selected for extraction")
    try check(!fm.fileExists(atPath: encodedSelection.appendingPathComponent("资料").path), "decoded selection excludes other encodings")
    for (member, contents) in [("données/café.txt", "CP437"), ("UTF8/élève.txt", "accented UTF-8"), ("UTF8/naïve.txt", "unflagged accented UTF-8")] {
      try check(try Data(contentsOf: encodedSelection.appendingPathComponent(member)) == Data(contents.utf8), "selected accented member has the expected bytes")
      let prepared = try NativeArchives.prepareFile(encodedArchive, member: member)
      defer { try? fm.removeItem(at: prepared.directory) }
      try check(try Data(contentsOf: prepared.file) == Data(contents.utf8), "accented member can be opened temporarily")
    }
    let extraction = try NativeArchives.extract(archive, to: destination)
    try check(extraction.errors.isEmpty && extraction.succeeded.count == 1 && extraction.changes.count == 1, "extraction creates undo records")
    try check(try Data(contentsOf: destination.appendingPathComponent(member)) == content, "extraction contents")
    let collision = try NativeArchives.extract(archive, to: destination)
    try check(collision.succeeded.isEmpty && collision.errors.count == 1, "existing folder is not merged or overwritten")
    try check(try Data(contentsOf: destination.appendingPathComponent(member)) == content, "collision preserves destination")
    let selectionTarget = try folder("selection")
    let selection = try NativeArchives.extract(archive, to: selectionTarget, selected: [member])
    try check(selection.errors.isEmpty, "selected extraction succeeds")
    try check(!fm.fileExists(atPath: selectionTarget.appendingPathComponent("资料 目录/.hidden").path), "unselected file absent")
    let partialTarget = try folder("partial")
    try content.write(to: partialTarget.appendingPathComponent("keep.txt"))
    let partial = try NativeArchives.extract(root.appendingPathComponent("partial.zip"), to: partialTarget)
    try check(partial.errors.count == 1 && partial.succeeded.count == 1 && partial.changes.count == 1, "partial collisions report successes and failures")
    try check(try Data(contentsOf: partialTarget.appendingPathComponent("keep.txt")) == content, "partial collision preserves prior bytes")
    try check(try Data(contentsOf: partialTarget.appendingPathComponent("new.txt")) == Data("new".utf8), "nonconflicting root publishes")
    let namedTarget = try folder("named")
    let named = try NativeArchives.extract(archive, to: namedTarget, selected: [member], namedFolder: true)
    try check(named.succeeded.first?.lastPathComponent == "资料 目录", "named folder")
    let againNamed = try NativeArchives.extract(archive, to: namedTarget, namedFolder: true)
    try check(againNamed.succeeded.isEmpty && againNamed.errors.count == 1, "named collision")
    let prepared = try NativeArchives.prepareFile(archive, member: member)
    defer { try? fm.removeItem(at: prepared.directory) }
    try check(try Data(contentsOf: prepared.file) == content, "temporary opening bytes")
    _ = try NativeCommand.run(executable: "/usr/bin/xattr", arguments: ["-w", "com.apple.quarantine", "0081;00000000;ArchiveChecks;", archive.path])
    let quarantined = try NativeArchives.prepareFile(archive, member: member)
    defer { try? fm.removeItem(at: quarantined.directory) }
    let attribute = try NativeCommand.run(executable: "/usr/bin/xattr", arguments: ["-p", "com.apple.quarantine", quarantined.file.path])
    try check(attribute.text.contains("ArchiveChecks"), "quarantine preserved")
    try rejects("empty selection") { _ = try NativeArchives.extract(archive, to: destination, selected: []) }
    try rejects("empty compression") { _ = try NativeArchives.compress([]) }
    try rejects("root compression") { _ = try NativeArchives.compress([URL(fileURLWithPath: "/")]) }
    try rejects("non-file URL") { _ = try NativeArchives.preview(URL(string: "https://example.com/archive.zip")!) }
    try rejects("invalid selection") { _ = try NativeArchives.extract(archive, to: destination, selected: ["../escape"]) }
    try rejects("non-member opening") { _ = try NativeArchives.prepareFile(archive, member: "../escape") }
    try rejects("directory opening") { _ = try NativeArchives.prepareFile(archive, member: "资料 目录") }
    for name in ["traversal.zip", "absolute.zip", "backslash.zip", "colon.zip", "symlink.zip", "corrupt.zip", "too-many.zip", "too-large.tar", "legacy-traversal.zip", "legacy-absolute.zip", "legacy-backslash.zip", "legacy-colon.zip", "invalid-utf8.zip", "encrypted.zip"] {
      let bad = root.appendingPathComponent(name)
      try rejects(name) { _ = try NativeArchives.extract(bad, to: destination) }
    }
    try rejects("duplicate extraction") { _ = try NativeArchives.extract(root.appendingPathComponent("duplicate.zip"), to: destination) }
    try check(!fm.fileExists(atPath: destination.appendingPathComponent("duplicate.txt").path), "failed decode publishes no partial output")
    for name in ["legacy-duplicate.zip", "unicode-duplicate.zip"] {
      try rejects("duplicate after filename decoding") { _ = try NativeArchives.extract(root.appendingPathComponent(name), to: destination) }
    }
    try check(!fm.fileExists(atPath: destination.appendingPathComponent("café.txt").path), "decoded filename collision publishes no partial output")
    try check(!fm.fileExists(atPath: root.appendingPathComponent("escape").path), "path traversal rejected")
    let dangling = destination.appendingPathComponent("资料 目录", isDirectory: true)
    try fm.removeItem(at: dangling)
    try fm.createSymbolicLink(at: dangling, withDestinationURL: root.appendingPathComponent("does-not-exist"))
    let linkCollision = try NativeArchives.extract(archive, to: destination)
    try check(linkCollision.succeeded.isEmpty && linkCollision.errors.count == 1, "dangling symlink collision")
    try check(try fm.destinationOfSymbolicLink(atPath: dangling.path) == root.appendingPathComponent("does-not-exist").path, "symlink preserved")
    let sourceLink = sources.appendingPathComponent("link")
    try fm.createSymbolicLink(at: sourceLink, withDestinationURL: document)
    try rejects("symlink compression") { _ = try NativeArchives.compress([sourceLink]) }
    try fm.createSymbolicLink(at: nested.appendingPathComponent("nested-link"), withDestinationURL: document)
    try rejects("nested symlink compression") { _ = try NativeArchives.compress([nested]) }
    try check(!fm.fileExists(atPath: sources.appendingPathComponent("资料 目录 (3).zip").path), "unsupported links do not publish archives")
    for target in [sources, destination, selectionTarget, namedTarget, partialTarget, encodedTarget, encodedSelection] {
      try check(try fm.contentsOfDirectory(atPath: target.path).allSatisfy { !$0.hasPrefix(".explorer-") }, "staging cleanup")
    }
    try check(try Data(contentsOf: document) == content, "all operations preserve source")
    try check(NativeArchives.folderName(URL(fileURLWithPath: "/test/test.tar.gz")) == "test", "compound extension")
    try check(NativeArchives.isArchive(URL(fileURLWithPath: "/test/test.ZIP")), "case insensitive extension")
    print("Archive checks passed: compression, browsing, UTF-8/CP437 names, selection, quarantine, collisions, unsafe paths, links, corruption, encryption rejection, limits, source preservation.")
  }
}
