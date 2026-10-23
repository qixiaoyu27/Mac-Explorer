import Foundation
import Darwin

/// A single confirmed network item, bound to its open parent and original identity.
/// Preparation reads metadata only. No file content, staging copy, or backup is made.
public final class NetworkDeletion: @unchecked Sendable {
  public let source: URL
  private let requestedParent: URL
  private let parent: URL
  private let descriptor: Int32
  private let original: TransferStamp
  private let parentIdentity: TransferStamp
  private let fileSystem: fsid_t
  private let network: @Sendable (Int32) throws -> Bool

  /// The descriptor classifier is injected only by disposable-fixture checks.
  public init(_ input: URL, network: @escaping @Sendable (Int32) throws -> Bool = { try NetworkDeletion.isNetwork($0) }) throws {
    guard input.isFileURL, input.baseURL == nil, input.user == nil, input.password == nil, input.port == nil,
      input.host == nil || input.host == "" || input.host == "localhost", input.query == nil, input.fragment == nil,
      input.path.hasPrefix("/"), !input.path.contains("\0"), input.standardizedFileURL.path != "/" else { throw Self.failure(input, EINVAL) }
    try FileActions.validateModificationSource(input)
    requestedParent = input.standardizedFileURL.deletingLastPathComponent()
    parent = requestedParent.resolvingSymlinksInPath()
    source = parent.appendingPathComponent(input.standardizedFileURL.lastPathComponent)
    let fd = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw Self.failure(source) }
    do {
      var info = stat(), mount = statfs()
      guard fstat(fd, &info) == 0, fstatfs(fd, &mount) == 0 else { throw Self.failure(source) }
      let entry = try Self.stamp(fd, source.lastPathComponent, at: source)
      // A mounted root is not an item belonging to its containing directory.
      guard entry.device == info.st_dev, try network(fd) else { throw Self.failure(source, EPERM) }
      descriptor = fd; original = entry; parentIdentity = TransferStamp(info); fileSystem = mount.f_fsid; self.network = network
    } catch { Darwin.close(fd); throw error }
  }
  deinit { Darwin.close(descriptor) }

  public static func isNetwork(_ descriptor: Int32) throws -> Bool {
    var mount = statfs()
    guard fstatfs(descriptor, &mount) == 0 else { throw failure(URL(fileURLWithPath: "/")) }
    return mount.f_flags & UInt32(MNT_LOCAL) == 0
  }

  public func remove() throws {
    var info = stat()
    guard requestedParent.resolvingSymlinksInPath().path == parent.path, lstat(parent.path, &info) == 0, parentIdentity.sameObject(TransferStamp(info)),
      try network(descriptor), try sameFileSystem(descriptor), original.sameObject(try Self.stamp(descriptor, source.lastPathComponent, at: source)) else { throw Self.failure(source, ESTALE) }
    try walk(descriptor, source.lastPathComponent, source, expected: original, depth: 0)
  }

  private func sameFileSystem(_ fd: Int32) throws -> Bool {
    var mount = statfs()
    guard fstatfs(fd, &mount) == 0 else { throw Self.failure(source) }
    return mount.f_fsid.val.0 == fileSystem.val.0 && mount.f_fsid.val.1 == fileSystem.val.1
  }
  private func walk(_ parentFD: Int32, _ name: String, _ path: URL, expected: TransferStamp? = nil, depth: Int) throws {
    try Task.checkCancellation()
    guard depth < 512 else { throw Self.failure(path, ELOOP) }
    let before = try Self.stamp(parentFD, name, at: path)
    guard before.device == original.device, expected == nil || expected!.sameObject(before) else { throw Self.failure(path, ESTALE) }
    if before.type == S_IFDIR {
      let fd = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      guard fd >= 0 else { throw Self.failure(path) }; defer { Darwin.close(fd) }
      var opened = stat()
      guard fstat(fd, &opened) == 0, before.sameObject(TransferStamp(opened)), try sameFileSystem(fd) else { throw Self.failure(path, ESTALE) }
      let duplicate = dup(fd)
      guard duplicate >= 0 else { throw Self.failure(path) }
      guard let stream = fdopendir(duplicate) else { Darwin.close(duplicate); throw Self.failure(path) }
      var names: [String] = []
      do {
        defer { closedir(stream) }; errno = 0
        while let entry = readdir(stream) {
          let value = withUnsafePointer(to: &entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(validatingUTF8: $0) } }
          guard let value else { throw Self.failure(path, EILSEQ) }
          if value != ".", value != ".." { names.append(value) }; errno = 0
        }
        guard errno == 0 else { throw Self.failure(path) }
      }
      for child in names { try walk(fd, child, path.appendingPathComponent(child), depth: depth + 1) }
    }
    // Never follow a symlink, cross a nested volume, chmod, or retry a denied unlink.
    guard before.sameObject(try Self.stamp(parentFD, name, at: path)) else { throw Self.failure(path, ESTALE) }
    guard unlinkat(parentFD, name, before.type == S_IFDIR ? AT_REMOVEDIR : 0) == 0 else { throw Self.failure(path) }
  }
  private static func stamp(_ fd: Int32, _ name: String, at path: URL) throws -> TransferStamp {
    var info = stat()
    guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw failure(path) }
    return TransferStamp(info)
  }
  private static func failure(_ url: URL, _ code: Int32 = errno) -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: url.path])
  }
}
