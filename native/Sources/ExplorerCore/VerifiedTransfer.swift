import Foundation
import Darwin

public enum FileTransferOutcome: String, Sendable { case copied, moved, failed, sourceRetained, cleanupIncomplete, cancelled }
public enum FileTransferMethod: String, Sendable { case rename, systemCopy, serverSideCopy, noOp }

/// contentVerified is false for system copies: no application-level checksum is implied.
public struct FileTransferItem: Sendable {
  public let source: URL
  public let destination: URL
  public let outcome: FileTransferOutcome
  public let method: FileTransferMethod
  public let contentVerified: Bool
  public let datesVerified: Bool
  public let recoveryLocations: [URL]
  public let message: String?
  var diagnostic: String? = nil
}

struct FileTransferFailure: LocalizedError {
  let item: FileTransferItem
  var handled = false
  var retryRequested = false
  var errorDescription: String? { item.message }
}

enum TransferCheckpoint { case beforeCopy, afterCopy, afterDates, beforePublish, afterPublish, beforeCleanup, beforeRemove }

/// Per-operation injection, never a process-wide switch or a production environment variable.
struct TransferHooks {
  var forceCopyMove = false
  var checkpoint: ((TransferCheckpoint, URL, URL) throws -> Void)?
  var restoreDates: ((Int32, TransferStamp) throws -> Void)?
  var control: FileTransferControl?
  var copy: ((URL, URL) throws -> Void)?
  var exclusiveRename: ((URL, URL) throws -> Void)?
  var descriptorCopy = false
  var nativeCopy = NativeTransferCopy.Hooks()
}

struct TransferMoment: Equatable {
  let seconds: Int
  let nanos: Int
  init(_ time: timespec) { seconds = time.tv_sec; nanos = time.tv_nsec }
  var timespecValue: timespec { timespec(tv_sec: seconds, tv_nsec: nanos) }
  func matches(_ other: Self, precision: Int) -> Bool {
    guard abs(seconds - other.seconds) <= 1 else { return false }
    return abs((seconds - other.seconds) * 1_000_000_000 + nanos - other.nanos) < precision
  }
}

struct TransferStamp: Equatable {
  let device: Int32
  let inode: UInt64
  let type: mode_t
  let mode: mode_t
  let size: Int64
  let birth: TransferMoment
  let modified: TransferMoment
  let changed: TransferMoment
  let precision: Int
  init(_ value: stat, precision: Int = 1) {
    self.precision = precision
    device = value.st_dev; inode = value.st_ino; type = value.st_mode & S_IFMT; mode = value.st_mode
    size = value.st_size; birth = TransferMoment(value.st_birthtimespec)
    modified = TransferMoment(value.st_mtimespec); changed = TransferMoment(value.st_ctimespec)
  }
  var identity: String { "\(device):\(inode):\(birth.seconds):\(birth.nanos)" }
  func sameObject(_ other: Self) -> Bool { device == other.device && inode == other.inode && type == other.type && birth.matches(other.birth, precision: max(precision, other.precision)) }
  func unchanged(_ other: Self, ignoreChangeTime: Bool = false) -> Bool {
    // SMB servers may expose ChangeTime as LastWriteTime after an attribute refresh,
    // while the client's recent setattr cache reports "now". It is not a stable
    // change token. Identity, mode, size, mtime, and tree membership still apply.
    // SMB may first report a symlink's text length, then its on-disk reparse
    // record length after reopening. Link text is compared by sameLayout; only
    // regular-file size is a stable content guard across these attribute refreshes.
    sameObject(other) && mode == other.mode && (type != S_IFREG || size == other.size) && modified.matches(other.modified, precision: max(precision, other.precision)) && (ignoreChangeTime || precision == 100 && other.precision == 100 || changed.matches(other.changed, precision: max(precision, other.precision)))
  }
  func requireUnchanged(_ other: Self, control: FileTransferControl?, stage: String) throws {
    guard !unchanged(other) else { return }
    let unit = max(precision, other.precision)
    // Record differing fields, never file identities, timestamps, names or paths.
    control?.recordTiming(stage, seconds: 0, succeeded: false, metrics: [
      "device": device == other.device ? 0 : 1, "inode": inode == other.inode ? 0 : 1,
      "type": type == other.type ? 0 : 1, "mode": mode == other.mode ? 0 : 1,
      "size": type != S_IFREG || size == other.size ? 0 : 1,
      "birth": birth.matches(other.birth, precision: unit) ? 0 : 1,
      "mtime": modified.matches(other.modified, precision: unit) ? 0 : 1,
      "ctime": changed.matches(other.changed, precision: unit) ? 0 : 1,
    ])
    throw VerifiedTransfer.failure("项目在传输期间发生变化，已停止操作。")
  }
}

private final class TransferFD {
  let raw: Int32
  init(_ raw: Int32) throws { guard raw >= 0 else { throw VerifiedTransfer.posix() }; self.raw = raw }
  deinit { Darwin.close(raw) }
  var stamp: TransferStamp { get throws { var value = stat(); guard fstat(raw, &value) == 0 else { throw VerifiedTransfer.posix() }; return TransferStamp(value, precision: try AppleDoubleCompanion.usesSidecars(raw) ? 100 : 1) } }
}

private final class TransferAnchor {
  let url: URL
  let fd: TransferFD
  let original: TransferStamp
  init(_ url: URL) throws {
    self.url = url.resolvingSymlinksInPath().standardizedFileURL
    fd = try TransferFD(open(self.url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC))
    original = try fd.stamp
  }
  var recoveryURL: URL {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    return buffer.withUnsafeMutableBufferPointer { pointer in
      fcntl(fd.raw, F_GETPATH, pointer.baseAddress!) == 0 ? URL(fileURLWithPath: String(cString: pointer.baseAddress!)) : url
    }
  }
  func validate() throws {
    var info = stat()
    guard lstat(url.path, &info) == 0, original.sameObject(TransferStamp(info, precision: original.precision)), try original.sameObject(fd.stamp) else { throw VerifiedTransfer.failure("文件夹已发生变化，已停止操作。") }
  }
  func entry(_ name: String) throws -> TransferStamp {
    var info = stat()
    guard fstatat(fd.raw, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw VerifiedTransfer.posix() }
    return TransferStamp(info, precision: original.precision)
  }
  func requireAbsent(_ name: String) throws {
    var info = stat()
    if fstatat(fd.raw, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { throw VerifiedTransfer.posix(EEXIST) }
    guard errno == ENOENT else { throw VerifiedTransfer.posix() }
  }
}

private struct TransferNode {
  let relative: String
  let stamp: TransferStamp
  let link: String?
  var companion: TransferStamp? = nil
}

/// Reads and cleanup walk open directory descriptors and never follow a tree's symlinks.
private struct TransferTree {
  let parent: TransferAnchor
  let name: String
  var url: URL { parent.url.appendingPathComponent(name) }

  static func names(_ directory: Int32) throws -> [String] {
    let duplicate = dup(directory)
    guard duplicate >= 0 else { throw VerifiedTransfer.posix() }
    guard let stream = fdopendir(duplicate) else { Darwin.close(duplicate); throw VerifiedTransfer.posix() }
    defer { closedir(stream) }
    rewinddir(stream)
    var names: [String] = []
    errno = 0
    while let entry = readdir(stream) {
      let value = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(validatingUTF8: $0) }
      }
      guard let value else { throw VerifiedTransfer.failure("文件名无法读取，已停止操作。") }
      if value != "." && value != ".." { names.append(value) }
      errno = 0
    }
    guard errno == 0 else { throw VerifiedTransfer.posix() }
    return names.sorted()
  }

  static func stamp(_ parent: Int32, _ name: String) throws -> TransferStamp {
    var value = stat()
    guard fstatat(parent, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else { throw VerifiedTransfer.posix() }
    return TransferStamp(value, precision: try AppleDoubleCompanion.usesSidecars(parent) ? 100 : 1)
  }

  func capture(control: FileTransferControl? = nil) throws -> [TransferNode] {
    try parent.validate()
    var nodes: [TransferNode] = []
    let rootDevice = try parent.entry(name).device
    func walk(_ directory: Int32, _ name: String, _ relative: String, _ depth: Int) throws {
      try control?.check()
      guard depth < 512 else { throw VerifiedTransfer.failure("文件夹层级过深，已停止操作。") }
      var before = try Self.stamp(directory, name)
      guard before.device == rootDevice else { throw VerifiedTransfer.failure("文件夹包含其他磁盘，已停止操作。") }
      guard [S_IFREG, S_IFDIR, S_IFLNK].contains(before.type) else { throw VerifiedTransfer.failure("不支持安全传输此文件类型。") }
      let index = nodes.count
      if before.type == S_IFLNK {
        var buffer = [CChar](repeating: 0, count: 1_048_576)
        let count = buffer.withUnsafeMutableBufferPointer { readlinkat(directory, name, $0.baseAddress!, $0.count) }
        guard count >= 0, count < buffer.count else { throw VerifiedTransfer.posix() }
        let bytes = buffer.prefix(count).map { UInt8(bitPattern: $0) }
        guard let link = String(bytes: bytes, encoding: .utf8) else { throw VerifiedTransfer.failure("文件名无法读取，已停止操作。") }
        let file = try TransferFD(openat(directory, name, O_RDONLY | O_SYMLINK | O_CLOEXEC))
        let opened = try file.stamp
        guard before.device == opened.device, before.inode == opened.inode, before.type == opened.type else { throw VerifiedTransfer.failure("项目在传输期间发生变化，已停止操作。") }
        before = opened
        nodes.append(TransferNode(relative: relative, stamp: before, link: link, companion: try AppleDoubleCompanion.stamp(in: directory, primary: name)))
      } else {
        let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (before.type == S_IFDIR ? O_DIRECTORY : 0)
        let file = try TransferFD(openat(directory, name, flags))
        // Opening an SMB entry refreshes attributes which lstat may still have cached
        // from before the writer closed. Establish the snapshot from the held object.
        let opened = try file.stamp
        guard before.device == opened.device, before.inode == opened.inode, before.type == opened.type else { throw VerifiedTransfer.failure("项目在传输期间发生变化，已停止操作。") }
        before = opened
        nodes.append(TransferNode(relative: relative, stamp: before, link: nil, companion: try AppleDoubleCompanion.stamp(in: directory, primary: name)))
        if before.type == S_IFDIR {
          for child in try Self.names(file.raw) where try !AppleDoubleCompanion.isMetadata(child, in: file.raw) { try walk(file.raw, child, relative.isEmpty ? child : relative + "/" + child, depth + 1) }
        }
        guard try before.unchanged(file.stamp) else { throw VerifiedTransfer.failure("项目在传输期间发生变化，已停止操作。") }
      }
      guard try nodes[index].stamp.unchanged(Self.stamp(directory, name)) else { throw VerifiedTransfer.failure("项目在传输期间发生变化，已停止操作。") }
    }
    try walk(parent.fd.raw, name, "", 0)
    try parent.validate()
    return nodes
  }

  func withParent<T>(_ relative: String, expected: [String: TransferNode], _ body: (Int32, String) throws -> T) throws -> T {
    try parent.validate()
    let components = relative.isEmpty ? [name] : [name] + relative.split(separator: "/").map(String.init)
    var directory = parent.fd.raw
    var held: [TransferFD] = []
    for (index, component) in components.dropLast().enumerated() {
      let key = index == 0 ? "" : components[1...index].joined(separator: "/")
      guard let node = expected[key], try node.stamp.sameObject(Self.stamp(directory, component)) else { throw VerifiedTransfer.failure("文件夹已发生变化，已停止操作。") }
      let next = try TransferFD(openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC))
      guard try node.stamp.sameObject(next.stamp) else { throw VerifiedTransfer.failure("文件夹已发生变化，已停止操作。") }
      held.append(next); directory = next.raw
    }
    return try withExtendedLifetime(held) { try body(directory, components.last!) }
  }

  func restore(_ source: [TransferNode], from tree: TransferTree, target: [TransferNode], hooks: TransferHooks, updated: ((TransferNode) -> Void)? = nil) throws {
    let index = Dictionary(uniqueKeysWithValues: target.map { ($0.relative, $0) })
    let sourceIndex = Dictionary(uniqueKeysWithValues: source.map { ($0.relative, $0) })
    for node in source.reversed() {
      try hooks.control?.check()
      guard let original = index[node.relative] else { throw VerifiedTransfer.failure("文件内容校验失败，来源已保留。") }
      try withParent(node.relative, expected: index) { parent, name in
        let flags = O_RDONLY | O_CLOEXEC | O_NONBLOCK | (node.stamp.type == S_IFLNK ? O_SYMLINK : O_NOFOLLOW)
        let file = try TransferFD(openat(parent, name, flags))
        try original.stamp.requireUnchanged(file.stamp, control: hooks.control, stage: "properties.target_changed")
        defer { if let stamp = try? file.stamp { updated?(TransferNode(relative: node.relative, stamp: stamp, link: original.link, companion: try? AppleDoubleCompanion.stamp(in: parent, primary: name))) } }
        if let restore = hooks.restoreDates { try restore(file.raw, node.stamp) }
        else { try VerifiedTransfer.restoreDates(file.raw, node.stamp) }
        try tree.withParent(node.relative, expected: sourceIndex) { directory, name in
          let from = try TransferFD(openat(directory, name, flags))
          try node.stamp.requireUnchanged(from.stamp, control: hooks.control, stage: "properties.source_changed")
          if node.stamp.type != S_IFLNK, node.stamp.mode & 0o222 == 0, try file.stamp.mode & 0o222 != 0 {
            throw VerifiedTransfer.failure("无法保留只读权限，来源已保留。")
          }
          if let expected = try NativeTransferCopy.explicitACL(from.raw), try NativeTransferCopy.explicitACL(file.raw) != expected {
            throw VerifiedTransfer.failure("目标校验失败，来源已保留。")
          }
        }
      }
    }
  }

  /// Compatibility path: reserve each entry atomically, then copy through held descriptors.
  /// No check-then-rename overwrite window and no second pass over file contents.
  func copyReserved(_ source: TransferTree, nodes: [TransferNode], hooks: TransferHooks, moving: Bool, owned: inout [String: TransferNode]) throws -> Bool {
    let sourceIndex = Dictionary(uniqueKeysWithValues: nodes.map { ($0.relative, $0) })
    var lost = false
    for node in nodes {
      try hooks.control?.check()
      try withParent(node.relative, expected: owned) { directory, name in
        if try AppleDoubleCompanion.usesSidecars(directory) {
          var companionInfo = stat()
          guard fstatat(directory, "._" + name, &companionInfo, AT_SYMLINK_NOFOLLOW) != 0 else { throw VerifiedTransfer.posix(EEXIST) }
          guard errno == ENOENT else { throw VerifiedTransfer.posix() }
        }
        let file: TransferFD
        if node.stamp.type == S_IFDIR {
          guard mkdirat(directory, name, 0o700) == 0 else { throw VerifiedTransfer.posix() }
          file = try TransferFD(openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC))
        } else if node.stamp.type == S_IFLNK {
          guard let link = node.link, symlinkat(link, directory, name) == 0 else { throw VerifiedTransfer.posix() }
          file = try TransferFD(openat(directory, name, O_RDWR | O_SYMLINK | O_CLOEXEC))
        } else {
          file = try TransferFD(openat(directory, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600))
        }
        owned[node.relative] = TransferNode(relative: node.relative, stamp: try file.stamp, link: node.link, companion: try AppleDoubleCompanion.stamp(in: directory, primary: name))
      }
    }
    // Directory permissions and metadata are applied after their children are written.
    for node in nodes.reversed() {
      try hooks.control?.check()
      try source.withParent(node.relative, expected: sourceIndex) { directory, name in
        let from = try TransferFD(openat(directory, name, O_RDONLY | O_CLOEXEC | O_NONBLOCK | (node.stamp.type == S_IFLNK ? O_SYMLINK : O_NOFOLLOW)))
        try node.stamp.requireUnchanged(from.stamp, control: hooks.control, stage: "copy.source_changed")
        try withParent(node.relative, expected: owned) { directory, name in
          let to = try TransferFD(openat(directory, name, O_CLOEXEC | O_NONBLOCK | (node.stamp.type == S_IFDIR ? O_RDONLY | O_DIRECTORY | O_NOFOLLOW : node.stamp.type == S_IFLNK ? O_RDWR | O_SYMLINK : O_RDWR | O_NOFOLLOW)))
          guard let expected = owned[node.relative], try expected.stamp.sameObject(to.stamp) else { throw VerifiedTransfer.posix(ESTALE) }
          defer { if let stamp = try? to.stamp { owned[node.relative] = TransferNode(relative: node.relative, stamp: stamp, link: node.link, companion: try? AppleDoubleCompanion.stamp(in: directory, primary: name)) } }
          let fromURL = node.relative.isEmpty ? source.url : source.url.appendingPathComponent(node.relative)
          let toURL = node.relative.isEmpty ? url : url.appendingPathComponent(node.relative)
          if try NativeTransferCopy.copyDescriptors(from.raw, to: to.raw, sourceURL: fromURL, destinationURL: toURL, total: node.stamp.type == S_IFREG ? node.stamp.size : 0, control: hooks.control, moving: moving, link: node.stamp.type == S_IFLNK, hooks: hooks.nativeCopy) { lost = true }
        }
      }
    }
    return lost
  }

  /// Remove only individually reserved entries. Unknown or changed children stop cleanup.
  func discardReserved(_ owned: [String: TransferNode]) throws {
    for node in owned.values.sorted(by: { $0.relative.split(separator: "/").count > $1.relative.split(separator: "/").count }) {
      try withParent(node.relative, expected: owned) { directory, name in
        let current = try Self.stamp(directory, name)
        guard node.stamp.sameObject(current), node.stamp.type == S_IFDIR || node.stamp.unchanged(current) else { throw VerifiedTransfer.posix(ESTALE) }
        guard unlinkat(directory, name, node.stamp.type == S_IFDIR ? AT_REMOVEDIR : 0) == 0 else { throw VerifiedTransfer.posix() }
        try AppleDoubleCompanion.remove(in: directory, primary: name, expected: node.companion)
        if try AppleDoubleCompanion.usesSidecars(directory) {
          var leftover = stat()
          if fstatat(directory, "._" + name, &leftover, AT_SYMLINK_NOFOLLOW) == 0 { throw VerifiedTransfer.posix(ESTALE) }
          guard errno == ENOENT else { throw VerifiedTransfer.posix() }
        }
      }
    }
  }

  func removeVerified(_ expected: [TransferNode], hooks: TransferHooks, destination: TransferTree, target: [TransferNode], removed: inout Int) throws {
    let index = Dictionary(uniqueKeysWithValues: expected.map { ($0.relative, $0) })
    let targetIndex = Dictionary(uniqueKeysWithValues: target.map { ($0.relative, $0) })
    var removedIdentities = Set<String>()
    for node in expected.reversed() {
      var entryRemoved = false
      while true {
        do {
          try hooks.control?.check()
          try hooks.checkpoint?(.beforeRemove, node.relative.isEmpty ? url : url.appendingPathComponent(node.relative), destination.url)
          try destination.withParent(node.relative, expected: targetIndex) { directory, name in
            guard let verified = targetIndex[node.relative], try verified.stamp.unchanged(Self.stamp(directory, name)) else { throw VerifiedTransfer.failure("目标校验失败，来源已保留。") }
          }
          try withParent(node.relative, expected: index) { directory, name in
            if !entryRemoved {
              let current = try Self.stamp(directory, name)
              guard node.stamp.sameObject(current), node.stamp.type == S_IFDIR || node.stamp.unchanged(current, ignoreChangeTime: removedIdentities.contains(node.stamp.identity)) else { throw VerifiedTransfer.failure("项目在传输期间发生变化，已停止操作。") }
              guard unlinkat(directory, name, node.stamp.type == S_IFDIR ? AT_REMOVEDIR : 0) == 0 else { throw VerifiedTransfer.posix() }
              entryRemoved = true; removed += 1; removedIdentities.insert(node.stamp.identity)
            } else {
              var occupant = stat()
              guard fstatat(directory, name, &occupant, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else { throw VerifiedTransfer.posix(ESTALE) }
            }
            try AppleDoubleCompanion.remove(in: directory, primary: name, expected: node.companion)
          }
          break
        } catch {
          if error is CancellationError { throw error }
          let problem = FileTransferProblem(source: url, destination: destination.url, message: error.localizedDescription, propertyLoss: false)
          switch hooks.control?.decide(problem) ?? .skip {
          case .retry: continue
          case .cancel: throw CancellationError()
          default: throw error
          }
        }
      }
    }
  }

  /// Only used inside this operation's owned private stage. Never follow symlinks.
  func discard() throws {
    try parent.validate()
    func walk(_ directory: Int32, _ name: String) throws {
      let before = try Self.stamp(directory, name)
      if before.type == S_IFDIR {
        let file = try TransferFD(openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC))
        guard try before.sameObject(file.stamp), fchmod(file.raw, before.mode | 0o700) == 0 else { throw VerifiedTransfer.posix(ESTALE) }
        for child in try Self.names(file.raw) { try walk(file.raw, child) }
      }
      let companion = try AppleDoubleCompanion.stamp(in: directory, primary: name)
      guard try before.sameObject(Self.stamp(directory, name)), unlinkat(directory, name, before.type == S_IFDIR ? AT_REMOVEDIR : 0) == 0 else { throw VerifiedTransfer.posix() }
      try AppleDoubleCompanion.remove(in: directory, primary: name, expected: companion)
    }
    try walk(parent.fd.raw, name)
  }

}

enum VerifiedTransfer {
  static func posix(_ code: Int32 = errno, function: String = #function, line: Int = #line) -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSDebugDescriptionErrorKey: "\(function):\(line)"])
  }
  static func failure(_ key: String) -> NSError { NSError(domain: "MacExplorer.Transfer", code: 1, userInfo: [NSLocalizedDescriptionKey: NL(key)]) }

  static func restoreDates(_ descriptor: Int32, _ stamp: TransferStamp) throws {
    var attributes = attrlist()
    attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
    attributes.commonattr = attrgroup_t(ATTR_CMN_CRTIME | ATTR_CMN_MODTIME)
    var times = [stamp.birth.timespecValue, stamp.modified.timespecValue]
    let result = times.withUnsafeMutableBytes { fsetattrlist(descriptor, &attributes, $0.baseAddress!, $0.count, 0) }
    guard result == 0 else { throw failure("无法恢复文件日期，来源已保留。") }
  }

  private static func sameLayout(_ before: [TransferNode], _ after: [TransferNode]) -> Bool {
    before.count == after.count && zip(before, after).allSatisfy { a, b in
      a.relative == b.relative && a.stamp.type == b.stamp.type && a.link == b.link
        && (a.stamp.type != S_IFREG || a.stamp.size == b.stamp.size)
    }
  }
  private static func sourceUnchanged(_ before: [TransferNode], _ after: [TransferNode]) -> Bool {
    sameLayout(before, after) && zip(before, after).allSatisfy { a, b in
      guard a.stamp.unchanged(b.stamp) else { return false }
      // On APFS, literal ._ files are verified as ordinary tree entries, not SMB metadata.
      if a.stamp.precision != 100 { return true }
      switch (a.companion, b.companion) {
      case (nil, nil): return true
      case let (.some(a), .some(b)): return a.unchanged(b)
      default: return false
      }
    }
  }
  private static func datesMatch(_ source: [TransferNode], _ target: [TransferNode], filesystem: String) -> Bool {
    let birthUnit: Int64 = filesystem == "msdos" ? 10_000_000 : ["smbfs", "ntfs"].contains(filesystem) ? 100 : 1
    let modifiedUnit: Int64 = filesystem == "msdos" ? 2_000_000_000 : birthUnit == 100 ? 100 : 1
    func equal(_ a: TransferMoment, _ b: TransferMoment, unit: Int64) -> Bool {
      if unit > 1_000_000_000 { return Int(floor(Double(a.seconds) / 2)) == Int(floor(Double(b.seconds) / 2)) }
      return a.seconds == b.seconds && Int64(a.nanos) / unit == Int64(b.nanos) / unit
    }
    return sameLayout(source, target) && zip(source, target).allSatisfy {
      equal($0.stamp.birth, $1.stamp.birth, unit: birthUnit) && equal($0.stamp.modified, $1.stamp.modified, unit: modifiedUnit)
    }
  }
  private static func rename(_ source: TransferTree, _ destination: TransferTree, hooks: TransferHooks) throws {
    try source.parent.validate(); try destination.parent.validate(); try destination.parent.requireAbsent(destination.name)
    if let rename = hooks.exclusiveRename { try rename(source.url, destination.url); return }
    guard renameatx_np(source.parent.fd.raw, source.name, destination.parent.fd.raw, destination.name, UInt32(RENAME_EXCL)) == 0 else { throw posix() }
  }

  /// Test the actual primitive with an empty owned directory before copying any data.
  /// SMB can leave the volume-capability valid bit unset; unknown is not "supported".
  private static func canPublish(in stage: TransferAnchor, hooks: TransferHooks) throws -> Bool {
    guard mkdirat(stage.fd.raw, "rename-probe", 0o700) == 0 else { throw posix() }
    let from = TransferTree(parent: stage, name: "rename-probe")
    let to = TransferTree(parent: stage, name: "rename-probe-moved")
    do { try rename(from, to, hooks: hooks); try to.discard(); return true }
    catch {
      let code = error as NSError
      guard code.domain == NSPOSIXErrorDomain && [ENOTSUP, ENOSYS].contains(Int32(code.code)) else { throw error }
      try from.discard(); return false
    }
  }

  static func perform(_ input: URL, to output: URL, move: Bool, hooks: TransferHooks = TransferHooks()) throws -> FileTransferItem {
    try hooks.control?.check()
    hooks.control?.setPhase(.preparing)
    let source = TransferTree(parent: try TransferAnchor(input.deletingLastPathComponent()), name: input.lastPathComponent)
    let destination = TransferTree(parent: try TransferAnchor(output.deletingLastPathComponent()), name: output.lastPathComponent)
    try destination.parent.requireAbsent(destination.name)
    if try AppleDoubleCompanion.usesSidecars(destination.parent.fd.raw) { try destination.parent.requireAbsent("._" + destination.name) }
    if move && !hooks.forceCopyMove {
      do {
        try FileTransferControl.measure(hooks.control, "publish.rename", phase: .publishing) { try rename(source, destination, hooks: hooks) }
        return FileTransferItem(source: input, destination: output, outcome: .moved, method: .rename, contentVerified: false, datesVerified: false, recoveryLocations: [], message: nil)
      } catch {
        let error = error as NSError
        guard error.domain == NSPOSIXErrorDomain && [EXDEV, ENOTSUP, ENOSYS].contains(Int32(error.code)) else { throw error }
      }
    }
    var stage: TransferAnchor?
    var published = false, datesVerified = false, removed = 0
    var handled = false
    var warning: String?
    var direct = false
    var owned: [String: TransferNode] = [:]
    func item(_ outcome: FileTransferOutcome, _ message: String? = nil, _ recovery: [URL] = []) -> FileTransferItem {
      FileTransferItem(source: input, destination: output, outcome: outcome, method: hooks.control?.usedServerSideCopy(under: input) == true ? .serverSideCopy : .systemCopy, contentVerified: false, datesVerified: datesVerified, recoveryLocations: recovery, message: message)
    }
    func cleanupStage(removePayload: Bool = true) throws {
      guard let stage else { return }
      try stage.validate()
      if removePayload {
        var info = stat()
        if fstatat(stage.fd.raw, "payload", &info, AT_SYMLINK_NOFOLLOW) == 0 { try TransferTree(parent: stage, name: "payload").discard() }
        else if errno != ENOENT { throw posix() }
      }
      try destination.parent.validate()
      let companion = try AppleDoubleCompanion.stamp(in: destination.parent.fd.raw, primary: stage.url.lastPathComponent)
      guard try stage.original.sameObject(destination.parent.entry(stage.url.lastPathComponent)) else { throw failure("文件夹已发生变化，已停止操作。") }
      guard unlinkat(destination.parent.fd.raw, stage.url.lastPathComponent, AT_REMOVEDIR) == 0 else { throw posix() }
      try AppleDoubleCompanion.remove(in: destination.parent.fd.raw, primary: stage.url.lastPathComponent, expected: companion)
    }
    do {
      let before = try FileTransferControl.measure(hooks.control, "capture.source.initial", phase: .preparing) { try source.capture(control: hooks.control) }
      let stageName = ".mac-explorer-transfer-" + UUID().uuidString
      try destination.parent.validate()
      guard mkdirat(destination.parent.fd.raw, stageName, 0o700) == 0 else { throw posix() }
      stage = try TransferAnchor(destination.parent.url.appendingPathComponent(stageName))
      guard let stage else { throw posix(EIO) }
      // SMB can derive inode numbers from paths, so a successful rename can change
      // identity. Reserve final names and flush data before restoring metadata.
      direct = try hooks.nativeCopy.synchronizedMetadata || AppleDoubleCompanion.usesSidecars(destination.parent.fd.raw)
        || !FileTransferControl.measure(hooks.control, "publish.probe", phase: .preparing) { try canPublish(in: stage, hooks: hooks) }
      let payload = direct ? destination : TransferTree(parent: stage, name: "payload")
      try hooks.checkpoint?(.beforeCopy, source.url, payload.url)
      try source.parent.validate(); try stage.validate()
      // A recursive path copy would also copy SMB's raw AppleDouble entries onto
      // APFS as extra files. Copy the captured logical entries through descriptors.
      try FileTransferControl.measure(hooks.control, "copy.entries", phase: .copying) {
        let sourceUsesSidecars = try AppleDoubleCompanion.usesSidecars(source.parent.fd.raw)
        if direct || hooks.descriptorCopy || sourceUsesSidecars || hooks.control?.serverSideCopy?.isCandidate(source: source.url, destination: payload.url) == true {
          if try payload.copyReserved(source, nodes: before, hooks: hooks, moving: move, owned: &owned) { warning = NL("部分文件属性无法保留：{0}", output.path) }
        } else if let copy = hooks.copy { try copy(source.url, payload.url) }
        else if try NativeTransferCopy.copy(source.url, to: payload.url, total: before.filter { $0.stamp.type == S_IFREG }.reduce(0) { $0 + $1.stamp.size }, control: hooks.control, moving: move) { warning = NL("部分文件属性无法保留：{0}", output.path) }
      }
      try hooks.checkpoint?(.afterCopy, source.url, payload.url)
      let copied = try FileTransferControl.measure(hooks.control, "capture.target.copied", phase: .verifying) { try payload.capture(control: hooks.control) }
      guard sameLayout(before, copied) else { throw failure("文件内容校验失败，来源已保留。") }
      guard owned.isEmpty || sourceUnchanged(before.compactMap { owned[$0.relative] }, copied) else { throw failure("目标校验失败，来源已保留。") }
      // Only our metadata writes may update this baseline; rereading the path would trust a replacement.
      var expectedTarget = Dictionary(uniqueKeysWithValues: copied.map { ($0.relative, $0) })
      var filesystem = statfs()
      guard fstatfs(stage.fd.raw, &filesystem) == 0 else { throw posix() }
      let fsName = withUnsafePointer(to: &filesystem.f_fstypename) { $0.withMemoryRebound(to: CChar.self, capacity: 16) { String(cString: $0) } }
      while true {
        do {
          try FileTransferControl.measure(hooks.control, "properties.restore", phase: .properties) {
            try payload.restore(before, from: source, target: before.compactMap { expectedTarget[$0.relative] }, hooks: hooks, updated: {
              expectedTarget[$0.relative] = $0
              if direct { owned[$0.relative] = $0 }
            })
          }
          try hooks.checkpoint?(.afterDates, source.url, payload.url)
          datesVerified = datesMatch(before, try FileTransferControl.measure(hooks.control, "capture.target.dates", phase: .verifying) { try payload.capture(control: hooks.control) }, filesystem: fsName)
          guard datesVerified else { throw failure("文件日期校验失败，来源已保留。") }
          break
        } catch {
          if error is CancellationError { throw error }
          let problem = FileTransferProblem(source: input, destination: output, message: error.localizedDescription, propertyLoss: true, moving: move)
          handled = hooks.control != nil
          switch hooks.control?.decide(problem) ?? .skip {
          case .retry: continue
          case .continueWithoutProperties: warning = NL("部分文件属性无法保留：{0}", output.path)
          case .cancel: throw CancellationError()
          case .skip, .keepBoth: throw error
          }
          break
        }
      }
      // One final source snapshot after the checkpoint covers the same changes as the
      // former back-to-back snapshots, without another complete metadata walk on SMB.
      try hooks.checkpoint?(.beforePublish, source.url, payload.url)
      try hooks.control?.check()
      guard try sourceUnchanged(before, FileTransferControl.measure(hooks.control, "capture.source.before_publish", phase: .verifying) { try source.capture(control: hooks.control) }) else { throw failure("项目在传输期间发生变化，已停止操作。") }
      let staged = try FileTransferControl.measure(hooks.control, "capture.target.before_publish", phase: .verifying) { try payload.capture(control: hooks.control) }
      guard sameLayout(before, staged), sourceUnchanged(before.compactMap { expectedTarget[$0.relative] }, staged), !datesVerified || datesMatch(before, staged, filesystem: fsName) else { throw failure("文件内容校验失败，来源已保留。") }
      try FileTransferControl.measure(hooks.control, "publish", phase: .publishing) { if !direct { try rename(payload, destination, hooks: hooks) } }
      published = true
      try hooks.checkpoint?(.afterPublish, source.url, destination.url)
      let final = try FileTransferControl.measure(hooks.control, "capture.target.final", phase: .verifying) { try destination.capture(control: hooks.control) }
      guard sameLayout(staged, final), zip(staged, final).allSatisfy({ $0.stamp.unchanged($1.stamp, ignoreChangeTime: !direct && $0.relative.isEmpty) }), !datesVerified || datesMatch(before, final, filesystem: fsName) else { throw failure("目标校验失败，来源已保留。") }
      if move {
        while true {
          do {
            try hooks.control?.check()
            try hooks.checkpoint?(.beforeCleanup, source.url, destination.url)
            try FileTransferControl.measure(hooks.control, "capture.before_remove", phase: .verifying) {
              guard try sourceUnchanged(before, source.capture(control: hooks.control)), try sourceUnchanged(final, destination.capture(control: hooks.control)) else { throw failure("项目在传输期间发生变化，已停止操作。") }
            }
            break
          } catch {
            if error is CancellationError { throw error }
            handled = hooks.control != nil
            switch hooks.control?.decide(FileTransferProblem(source: input, destination: output, message: error.localizedDescription, propertyLoss: false)) ?? .skip {
            case .retry: continue
            case .cancel: throw CancellationError()
            default: throw error
            }
          }
        }
        try FileTransferControl.measure(hooks.control, "source.remove", phase: .removingSource) { try source.removeVerified(before, hooks: hooks, destination: destination, target: final, removed: &removed) }
      }
      do { try FileTransferControl.measure(hooks.control, "stage.cleanup", phase: .finishing) { try cleanupStage() } }
      catch { return item(move ? .moved : .copied, NL("操作已完成，但暂存记录无法清理：{0}", stage.recoveryURL.path) + " " + error.localizedDescription, [stage.recoveryURL]) }
      return item(move ? .moved : .copied, warning)
    } catch {
      var recovery = [URL]()
      if published { recovery.append(output); datesVerified = false }
      let uncertain = (error as? ServerSideCopyError)?.isUncertain == true
      if uncertain { recovery.append(direct ? output : stage?.recoveryURL ?? output) }
      if !uncertain && direct && !published && !owned.isEmpty {
        do { try destination.discardReserved(owned) }
        catch { recovery.append(destination.parent.recoveryURL.appendingPathComponent(destination.name)) }
      }
      // In the direct path the server can only write output, never this unused
      // stage. Remove its empty directory only; unknown children must be retained
      // and reported rather than traversed during uncertain-status cleanup.
      if !uncertain || direct { do { try cleanupStage(removePayload: !uncertain) } catch { if let stage { recovery.append(stage.recoveryURL) } } }
      let outcome: FileTransferOutcome = uncertain ? .cleanupIncomplete : error is CancellationError ? .cancelled : removed > 0 ? .cleanupIncomplete : published && move ? .sourceRetained : .failed
      let detail = error is CancellationError ? NL("已取消") : error.localizedDescription
      let recoveryText = recovery.isEmpty ? "" : NL("恢复位置：{0}", recovery.map(\.path).joined(separator: "；"))
      var failed = item(outcome, NL("操作未完成，请检查来源和目标。") + " " + detail + (recoveryText.isEmpty ? "" : " " + recoveryText), recovery)
      failed.diagnostic = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String
      throw FileTransferFailure(item: failed, handled: handled || (error as? NativeTransferCopy.Failure)?.handled == true, retryRequested: error is NativeTransferCopy.Retry && recovery.isEmpty && !published && removed == 0)
    }
  }
}
