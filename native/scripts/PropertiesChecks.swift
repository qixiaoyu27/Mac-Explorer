import Foundation
import Darwin

@main
struct PropertiesChecks {
  static func main() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("ExplorerPropertiesChecks-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    let folder = root.appendingPathComponent("folder"), outside = root.appendingPathComponent("outside")
    try fm.createDirectory(at: folder.appendingPathComponent("nested"), withIntermediateDirectories: true)
    try fm.createDirectory(at: outside, withIntermediateDirectories: true)
    try Data("abc".utf8).write(to: folder.appendingPathComponent("file.txt"))
    try Data("hidden".utf8).write(to: folder.appendingPathComponent(".hidden"))
    try Data(repeating: 7, count: 8192).write(to: outside.appendingPathComponent("not-counted.bin"))
    try fm.linkItem(at: folder.appendingPathComponent("file.txt"), to: folder.appendingPathComponent("hardlink.txt"))
    try fm.createSymbolicLink(atPath: folder.appendingPathComponent("directory-link").path, withDestinationPath: "../outside")
    try fm.createSymbolicLink(atPath: folder.appendingPathComponent("broken-link").path, withDestinationPath: "missing")
    var count = 0
    func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
      guard try condition() else { throw NSError(domain: "PropertiesChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
      count += 1
    }
    let result = try FilePropertiesReader.read([folder])
    try check(result.files == 5, "Includes hidden files, hard links, and symlinks")
    try check(result.folders == 1, "Excludes selected root and does not recurse through directory symlink")
    try check(result.symlinks == 2 && result.skipped == 0, "Broken and directory links count as objects")
    try check(result.size == 3 + 3 + 6 + Int64("../outside".utf8.count) + Int64("missing".utf8.count), "Logical bytes exclude external target")
    let duplicate = try FilePropertiesReader.read([folder, folder, folder.appendingPathComponent("file.txt")])
    try check(duplicate.size == result.size && duplicate.files == result.files, "Selected ancestors and duplicate paths are counted once")
    let one = try FilePropertiesReader.read([folder.appendingPathComponent("file.txt")])
    let hardlinks = try FilePropertiesReader.read([folder.appendingPathComponent("file.txt"), folder.appendingPathComponent("hardlink.txt")])
    try check(hardlinks.size == one.size * 2, "Logical bytes count each selected hard link")
    try check(hardlinks.allocated == one.allocated, "Allocated bytes deduplicate hard-linked data")
    try check(one.files == 1 && one.folders == 0 && one.readOnly == false, "Single-file metadata")
    try check(hardlinks.readOnly == nil, "Multiple roots have no single read-only state")
    let onlyLink = try FilePropertiesReader.read([folder.appendingPathComponent("directory-link")])
    try check(onlyLink.files == 1 && onlyLink.folders == 0 && onlyLink.symlinks == 1, "Selected directory link is not traversed")
    for urls in [[], [URL(string: "https://invalid.example")!], [root.appendingPathComponent("missing")]] {
      var rejected = false
      do { _ = try FilePropertiesReader.read(urls) } catch { rejected = true }
      try check(rejected, "Invalid or missing roots are rejected")
    }
    let task = Task.detached { () throws -> FileProperties in
      withUnsafeCurrentTask { $0?.cancel() }
      return try FilePropertiesReader.read([folder])
    }
    var cancelled = false
    do { _ = try await task.value } catch is CancellationError { cancelled = true }
    try check(cancelled, "Properties traversal cooperates with cancellation")
    try check(try Data(contentsOf: folder.appendingPathComponent("file.txt")) == Data("abc".utf8), "Source payload preserved")
    try check(try Data(contentsOf: outside.appendingPathComponent("not-counted.bin")).count == 8192, "External target preserved")
    try check(one.metadata?.owner == getuid() && one.metadata?.permissions == "644", "Extended properties report filesystem owner and permission bits")
    try check(onlyLink.metadata?.linkTarget == "../outside", "Extended properties read link text without following its target")
    let editable = folder.appendingPathComponent("editable.txt")
    try Data("edit payload".utf8).write(to: editable)
    let expected = try FilePropertiesReader.read([editable]).metadata!.identity
    try check(expected == FileActions.identity(editable), "Property editing identity agrees with file action history")
    let renamed = try FileActions.rename(editable, to: "renamed.txt", expectedIdentity: expected)
    let occupied = folder.appendingPathComponent("occupied.txt"); try Data("occupant".utf8).write(to: occupied)
    do { _ = try FileActions.rename(renamed.destination, to: "occupied.txt", expectedIdentity: expected); fatalError("Property rename overwrote collision") } catch { count += 1 }
    try check(try String(contentsOf: occupied) == "occupant", "Property rename preserves a collision occupant")
    try fm.moveItem(at: renamed.destination, to: folder.appendingPathComponent("retained-name"))
    try Data("replacement".utf8).write(to: renamed.destination)
    do { _ = try FileActions.rename(renamed.destination, to: "changed.txt", expectedIdentity: expected); fatalError("Property rename accepted replacement") } catch { count += 1 }
    try check(try String(contentsOf: renamed.destination) == "replacement", "A stale property window cannot rename a replacement file")
    let propertyFile = folder.appendingPathComponent("file.txt")
    let birth = Date(timeIntervalSince1970: 1_600_000_000), modified = Date(timeIntervalSince1970: 1_600_000_100)
    try fm.setAttributes([.creationDate: birth, .modificationDate: modified], ofItemAtPath: propertyFile.path)
    let dates = try FilePropertiesReader.read([propertyFile])
    try check(dates.created == birth && dates.modified == modified, "Properties re-read current filesystem dates")
    try fm.setAttributes([.modificationDate: modified.addingTimeInterval(100)], ofItemAtPath: propertyFile.path)
    try check(try FilePropertiesReader.read([propertyFile]).modified == modified.addingTimeInterval(100), "Properties do not retain a previous date snapshot")
    try check(try FilePropertiesReader.read([propertyFile, folder.appendingPathComponent("hardlink.txt")]).created == nil, "Multiple selections have no single creation date")
    for epoch in [-86_400.0, 0.0] {
      let birth = Date(timeIntervalSince1970: epoch)
      // Foundation's setter does not establish negative creation times on this host.
      // Prepare the raw filesystem value directly before testing the reader.
      let descriptor = open(propertyFile.path, O_RDONLY)
      guard descriptor >= 0 else { throw VerifiedTransfer.posix() }
      var attributes = attrlist(); attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
      attributes.commonattr = attrgroup_t(ATTR_CMN_CRTIME | ATTR_CMN_MODTIME)
      var times = [timespec(tv_sec: Int(epoch), tv_nsec: 0), timespec(tv_sec: 100, tv_nsec: 0)]
      let result = times.withUnsafeMutableBytes { fsetattrlist(descriptor, &attributes, $0.baseAddress, $0.count, 0) }
      close(descriptor)
      guard result == 0 else { throw VerifiedTransfer.posix() }
      try check(try FilePropertiesReader.read([propertyFile]).created == birth, "Valid pre-1970 and Unix-epoch creation dates remain visible")
    }
    print("PropertiesChecks: \(count) assertions passed.")
  }
}
