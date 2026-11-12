import Foundation

public enum DirectoryReader {
  private static let resourceKeys: Set<URLResourceKey> = [
    .nameKey,
    .isDirectoryKey,
    .isSymbolicLinkKey,
    .isPackageKey,
    .fileSizeKey,
    .contentModificationDateKey,
    .creationDateKey,
    .addedToDirectoryDateKey,
    .isHiddenKey,
    .fileResourceIdentifierKey,
  ]

  /// Synchronous filesystem work; callers should run this away from the main thread.
  public static func read(_ directory: URL) throws -> DirectorySnapshot {
    try Task.checkCancellation()
    let started = ProcessInfo.processInfo.systemUptime
    let host = directory.host?.lowercased() ?? ""
    guard directory.isFileURL,
      directory.baseURL == nil,
      directory.path.hasPrefix("/"),
      !directory.path.contains("\0"),
      host.isEmpty || host == "localhost",
      directory.user == nil,
      directory.password == nil,
      directory.port == nil,
      directory.query == nil,
      directory.fragment == nil
    else {
      throw ReadError.invalidURL
    }

    let manager = FileManager.default
    // Foundation's directory enumerator does not itself follow a directory symlink.
    let resolvedDirectory = directory.resolvingSymlinksInPath()
    let directoryValues = try resolvedDirectory.resourceValues(forKeys: [.isDirectoryKey])
    guard directoryValues.isDirectory == true else { throw ReadError.notDirectory }
    try Task.checkCancellation()

    let urls = try manager.contentsOfDirectory(
      at: resolvedDirectory,
      includingPropertiesForKeys: Array(resourceKeys),
      options: []
    )
    var entries: [FileEntry] = []
    entries.reserveCapacity(urls.count)
    var skippedCount = 0

    for url in urls {
      try Task.checkCancellation()
      do {
        let values = try url.resourceValues(forKeys: resourceKeys)
        guard let isLink = values.isSymbolicLink,
          var isDirectory = values.isDirectory
        else {
          skippedCount += 1
          continue
        }
        var isPackage = values.isPackage ?? false
        if isLink {
          // Follow only to classify the target, never to enumerate its contents.
          // Link metadata remains usable even when the target does not exist.
          var targetIsDirectory: ObjCBool = false
          isDirectory = manager.fileExists(atPath: url.path, isDirectory: &targetIsDirectory)
            && targetIsDirectory.boolValue
          isPackage = false
          if isDirectory {
            isPackage = (try? url.resolvingSymlinksInPath().resourceValues(
              forKeys: [.isPackageKey]
            ).isPackage) ?? false
          }
        }
        entries.append(FileEntry(
          url: directory.appendingPathComponent(url.lastPathComponent, isDirectory: isDirectory),
          name: values.name ?? url.lastPathComponent,
          isDirectory: isDirectory,
          isSymbolicLink: isLink,
          isPackage: isDirectory && isPackage,
          size: isDirectory ? 0 : Int64(values.fileSize ?? 0),
          modified: values.contentModificationDate,
          isHidden: (values.isHidden ?? false) || url.lastPathComponent.hasPrefix("."),
          created: values.creationDate,
          resourceIdentifier: values.fileResourceIdentifier as? Data,
          added: values.addedToDirectoryDate
        ))
      } catch {
        skippedCount += 1
      }
    }
    try Task.checkCancellation()

    return DirectorySnapshot(
      directory: directory,
      entries: entries,
      skippedCount: skippedCount,
      elapsedMilliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1_000
    )
  }

  private enum ReadError: LocalizedError {
    case invalidURL
    case notDirectory

    var errorDescription: String? {
      switch self {
      case .invalidURL: return NL("文件夹地址无效")
      case .notDirectory: return NL("路径不是文件夹")
      }
    }
  }
}
