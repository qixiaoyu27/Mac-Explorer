import Foundation
import Darwin

public struct FileProperties: Sendable {
  public let size: Int64
  public let allocated: Int64
  public let files: Int
  public let folders: Int
  public let skipped: Int
  public let symlinks: Int
  public let readOnly: Bool?
  public let created: Date?
  public let modified: Date?
  public let metadata: FilePropertyMetadata?
}

public struct FilePropertyMetadata: Sendable {
  public let identity: String
  public let owner: UInt32
  public let group: UInt32
  public let permissions: String
  public let hardLinks: UInt16
  public let accessed: Date
  public let linkTarget: String?
}

public enum FilePropertiesReader {
  public static func read(_ inputs: [URL]) throws -> FileProperties {
    try Task.checkCancellation()
    let paths = Array(Set(inputs.map { $0.standardizedFileURL.path }))
    guard !inputs.isEmpty, inputs.allSatisfy({ $0.isFileURL && ($0.host == nil || $0.host == "" || $0.host == "localhost") && $0.path.hasPrefix("/") && !$0.path.contains("\0") }) else { throw CocoaError(.fileReadInvalidFileName) }
    func info(_ path: String) throws -> stat {
      var value = stat()
      guard path.withCString({ Darwin.lstat($0, &value) }) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: path]) }
      return value
    }
    var directories = Set<String>()
    for path in paths { if try info(path).st_mode & S_IFMT == S_IFDIR { directories.insert(path) } }
    let roots = paths.filter { path in
      var ancestor = (path as NSString).deletingLastPathComponent
      while ancestor != path && !ancestor.isEmpty {
        if directories.contains(ancestor) { return false }
        if ancestor == "/" { break }
        ancestor = (ancestor as NSString).deletingLastPathComponent
      }
      return true
    }
    let rootSet = Set(roots)
    var queue = roots, seen = Set<String>(), size: Int64 = 0, allocated: Int64 = 0
    var files = 0, folders = 0, skipped = 0, symlinks = 0
    while let current = queue.popLast() {
      try Task.checkCancellation()
      let value: stat
      do { value = try info(current) } catch { if rootSet.contains(current) { throw error }; skipped += 1; continue }
      if value.st_mode & S_IFMT == S_IFDIR {
        if !rootSet.contains(current) { folders += 1 }
        do { queue += try FileManager.default.contentsOfDirectory(atPath: current).map { URL(fileURLWithPath: current).appendingPathComponent($0).path } }
        catch { skipped += 1 }
      } else {
        files += 1; size += value.st_size
        if value.st_mode & S_IFMT == S_IFLNK { symlinks += 1 }
        if seen.insert("\(value.st_dev):\(value.st_ino)").inserted { allocated += value.st_blocks * 512 }
      }
    }
    try Task.checkCancellation()
    let readOnly: Bool? = paths.count == 1 ? paths[0].withCString { Darwin.access($0, W_OK) != 0 } : nil
    // Read dates after the scan, rather than reusing the directory listing snapshot.
    let latest = paths.count == 1 ? try info(paths[0]) : nil
    func date(_ value: timespec) -> Date { Date(timeIntervalSince1970: Double(value.tv_sec) + Double(value.tv_nsec) / 1_000_000_000) }
    let created: Date?
    if let latest {
      let birth = latest.st_birthtimespec
      // Negative Unix timestamps are valid. For an all-zero stat value, ask the
      // filesystem's optional creation-date API instead of inventing an unavailable date.
      if birth.tv_sec == 0 && birth.tv_nsec == 0 {
        created = (try? URL(fileURLWithPath: paths[0]).resourceValues(forKeys: [.creationDateKey]))?.creationDate
      } else { created = date(birth) }
    } else { created = nil }
    let modified = latest.map { date($0.st_mtimespec) }
    let metadata = latest.map { value in
      FilePropertyMetadata(identity: "\(value.st_dev):\(value.st_ino):\(value.st_birthtimespec.tv_sec):\(value.st_birthtimespec.tv_nsec)",
        owner: value.st_uid, group: value.st_gid, permissions: String(value.st_mode & 0o7777, radix: 8), hardLinks: value.st_nlink,
        accessed: date(value.st_atimespec), linkTarget: value.st_mode & S_IFMT == S_IFLNK ? try? FileManager.default.destinationOfSymbolicLink(atPath: paths[0]) : nil)
    }
    return FileProperties(size: size, allocated: allocated, files: files, folders: folders, skipped: skipped, symlinks: symlinks, readOnly: readOnly, created: created, modified: modified, metadata: metadata)
  }
}
