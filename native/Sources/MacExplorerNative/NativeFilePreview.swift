import Foundation
import ExplorerCore
import Darwin

struct NativeFilePreview: Sendable {
  var text: String?
  var truncated = false

  static func supports(_ entry: FileEntry) -> Bool {
    let ext = entry.url.pathExtension.lowercased()
    return !entry.isDirectory && ["txt", "md", "json", "js", "jsx", "ts", "tsx", "css", "html", "xml", "yaml", "yml", "toml", "csv", "log", "swift", "py", "go", "rs", "sh", "sql", "gitignore", ""].contains(ext)
  }
  static func read(_ entry: FileEntry) throws -> NativeFilePreview {
    try Task.checkCancellation()
    guard supports(entry) else { return NativeFilePreview() }
    // Nonblocking open and descriptor validation also exclude FIFOs reached through symlinks.
    let descriptor = open(entry.url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true); defer { try? handle.close() }
    var info = stat()
    guard fstat(descriptor, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    guard info.st_mode & S_IFMT == S_IFREG else { return NativeFilePreview() }
    try Task.checkCancellation()
    let data = try handle.read(upToCount: 16_384) ?? Data()
    try Task.checkCancellation()
    guard !data.contains(0) else { return NativeFilePreview() }
    return NativeFilePreview(text: String(decoding: data, as: UTF8.self), truncated: info.st_size > data.count)
  }
}
