import Foundation
import Darwin

public enum FileActionKind: Sendable {
  case copy, move, create, trash
}

public struct FileActionChange: Sendable {
  public let source: URL?
  public let destination: URL
  public let kind: FileActionKind
  public let destinationIdentity: String?

  public init(source: URL?, destination: URL, kind: FileActionKind) {
    self.source = source
    self.destination = destination
    self.kind = kind
    self.destinationIdentity = try? FileActions.identity(destination)
  }
}

public struct FileActionResult: Sendable {
  /// Successful destinations, in operation order. A no-op move reports its source.
  public let succeeded: [URL]
  public let errors: [String]
  /// Only completed, reversible operations; pass these to undo in their original order.
  public let changes: [FileActionChange]
  public let transfers: [FileTransferItem]

  /// Failed moves keep their original source paths and remain available for retry.
  public var consumedMoveSources: [URL] {
    changes.filter { $0.kind == .move }.compactMap(\.source)
  }

  public init(succeeded: [URL], errors: [String], changes: [FileActionChange], transfers: [FileTransferItem] = []) {
    self.succeeded = succeeded
    self.errors = errors
    self.changes = changes
    self.transfers = transfers
  }
}

public enum BatchRenameCase: String, Sendable {
  case preserve, lowercase, uppercase, capitalized
}

public enum BatchRenameCollisionPolicy: Sendable {
  case fail, keepBoth
}

public struct BatchRenameConflict: Sendable {
  public let source: URL
  public let destination: URL
  public let sourceSize: Int64?
  public let destinationSize: Int64?

  public init(source: URL, destination: URL, sourceSize: Int64?, destinationSize: Int64?) {
    self.source = source
    self.destination = destination
    self.sourceSize = sourceSize
    self.destinationSize = destinationSize
  }
}

public struct BatchRenameSequence: Sendable {
  public var start: Int
  public var padding: Int
  public var separator: String

  public init(start: Int = 1, padding: Int = 2, separator: String = " ") {
    self.start = start
    self.padding = padding
    self.separator = separator
  }
}

/// Rules are deliberately name-only: the same operation safely applies to files
/// and folders. An extension override is ignored for folders.
public struct BatchRenameOptions: Sendable {
  public var prefix: String
  public var suffix: String
  public var find: String
  public var replacement: String
  public var casing: BatchRenameCase
  /// Literal fragments removed by editing a reference source name.
  public var removeTexts: [String]
  public var removeBracketedContent: Bool
  public var sequence: BatchRenameSequence?
  /// `nil` preserves a file extension; an empty value removes it.
  public var extensionOverride: String?

  public init(prefix: String = "", suffix: String = "", find: String = "", replacement: String = "", casing: BatchRenameCase = .preserve, removeTexts: [String] = [], removeBracketedContent: Bool = false, sequence: BatchRenameSequence? = nil, extensionOverride: String? = nil) {
    self.prefix = prefix
    self.suffix = suffix
    self.find = find
    self.replacement = replacement
    self.casing = casing
    self.removeTexts = removeTexts
    self.removeBracketedContent = removeBracketedContent
    self.sequence = sequence
    self.extensionOverride = extensionOverride
  }
}

public enum FileActions {
  public static func create(in parent: URL, name: String, directory: Bool, template: URL? = nil) throws -> FileActionChange {
    try validateName(name)
    let parent = try directoryURL(parent)
    let destination = parent.appendingPathComponent(name, isDirectory: directory)
    if let template {
      guard !directory else { throw failure(NL("不能从文档模板创建文件夹。")) }
      let source = try existingURL(template)
      let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      guard values.isRegularFile == true, values.isSymbolicLink != true else { throw failure(NL("文档模板必须是普通文件。")) }
      try requireAbsent(destination)
      try FileManager.default.copyItem(at: source, to: destination)
      return FileActionChange(source: nil, destination: destination, kind: .create)
    }
    // Foundation's createFile can truncate, and createDirectory accepts an existing directory.
    // The exclusive POSIX operations reject existing files, directories, and dangling symlinks.
    if directory {
      guard destination.path.withCString({ Darwin.mkdir($0, 0o777) }) == 0 else {
        throw posixError(destination)
      }
    } else {
      let descriptor = destination.path.withCString {
        Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL, 0o666)
      }
      guard descriptor >= 0 else { throw posixError(destination) }
      Darwin.close(descriptor)
    }
    return FileActionChange(source: nil, destination: destination, kind: .create)
  }

  public static func rename(_ source: URL, to name: String, expectedIdentity: String? = nil) throws -> FileActionChange {
    try validateName(name)
    let source = try existingURL(source)
    if let expectedIdentity, try identity(source) != expectedIdentity { throw failure(NL("项目已被其他文件替换，无法修改属性。")) }
    try validateModificationSource(source)
    let destination = source.deletingLastPathComponent().appendingPathComponent(name)
    if source.path == destination.path {
      return FileActionChange(source: source, destination: destination, kind: .move)
    }

    let caseOnly = source.lastPathComponent.compare(name, options: .caseInsensitive) == .orderedSame
    if let destinationInfo = try entryInfo(destination) {
      let sourceInfo = try requiredInfo(source)
      // Same inode alone is insufficient: two distinct hard links must still collide.
      let names = try FileManager.default.contentsOfDirectory(atPath: source.deletingLastPathComponent().path)
      guard caseOnly, sameIdentity(sourceInfo, destinationInfo), !names.contains(name) else {
        throw failure(NL("目标已存在：{0}", destination.path))
      }
    }

    if caseOnly {
      let temporary = source.deletingLastPathComponent()
        .appendingPathComponent(".explorer-rename-\(UUID().uuidString)")
      try moveExclusively(source, to: temporary)
      do {
        try moveExclusively(temporary, to: destination)
      } catch {
        let renameError = error
        do {
          try moveExclusively(temporary, to: source)
        } catch {
          throw failure(NL("重命名失败：{0}；还原失败：{1}。恢复位置：{2}", renameError.localizedDescription, error.localizedDescription, temporary.path))
        }
        throw renameError
      }
    } else {
      try moveExclusively(source, to: destination)
    }
    return FileActionChange(source: source, destination: destination, kind: .move)
  }

  /// Apply reusable Finder-style rules to files and folders in one directory.
  /// All targets are preflighted before the first move so accidental collisions
  /// do not turn a multi-item edit into a partial rename.
  /// Existing non-selected targets produced by these rules. This checks only
  /// proposed names, so it remains quick on a large SMB directory.
  public static func batchRenameConflicts(_ sources: [URL], options: BatchRenameOptions) throws -> [BatchRenameConflict] {
    guard sources.count >= 2 else { return [] }
    let parent = sources[0].deletingLastPathComponent()
    guard sources.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL == parent.standardizedFileURL }) else {
      throw failure(NL("批量重命名只能处理同一文件夹中的项目。"))
    }
    let selectedNames = Set(sources.map { normalizedName($0.lastPathComponent) })
    var proposed = Set<String>()
    var conflicts: [BatchRenameConflict] = []
    for (index, source) in sources.enumerated() {
      let source = try existingURL(source)
      let sourceInfo = try requiredInfo(source)
      let name = try batchRenameName(source, index: index, options: options)
      let key = normalizedName(name), sourceKey = normalizedName(source.lastPathComponent)
      let destination = parent.appendingPathComponent(name)
      let duplicatesProposedTarget = !proposed.insert(key).inserted
      let destinationInfo: stat?
      if key == sourceKey { destinationInfo = nil }
      else { destinationInfo = try entryInfo(destination) }
      let targetsExistingItem = destinationInfo != nil
      if key != sourceKey && (selectedNames.contains(key) || duplicatesProposedTarget || targetsExistingItem) {
        let sourceSize = sourceInfo.st_mode & S_IFMT == S_IFREG ? Int64(sourceInfo.st_size) : nil
        let destinationSize = destinationInfo.map { $0.st_mode & S_IFMT == S_IFREG ? Int64($0.st_size) : nil } ?? nil
        conflicts.append(BatchRenameConflict(source: source, destination: destination, sourceSize: sourceSize, destinationSize: destinationSize))
      }
    }
    return conflicts
  }

  public static func batchRename(_ sources: [URL], options: BatchRenameOptions, collisionPolicy: BatchRenameCollisionPolicy = .fail) -> FileActionResult {
    guard sources.count >= 2 else { return FileActionResult(succeeded: [], errors: [NL("请选择至少两个项目。")], changes: []) }
    do {
      let parent = sources[0].deletingLastPathComponent()
      guard sources.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL == parent.standardizedFileURL }) else {
        throw failure(NL("批量重命名只能处理同一文件夹中的项目。"))
      }
      if let extensionOverride = options.extensionOverride { _ = try normalizedExtension(extensionOverride) }
      // Do not enumerate the entire directory here. On an SMB/NAS share a large
      // media folder can make that one metadata request take longer than the
      // rename itself. Check only the handful of targets we are about to use.
      let selectedNames = Set(sources.map { normalizedName($0.lastPathComponent) })
      var proposed = Set<String>()
      var plan: [(URL, String, String)] = []
      guard Set(sources.map { $0.standardizedFileURL }).count == sources.count else { throw failure(NL("请选择不同的项目。")) }
      for (index, source) in sources.enumerated() {
        let source = try existingURL(source)
        try validateModificationSource(source)
        let isDirectory = (try source.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true
        var name = try batchRenameName(source, index: index, options: options)
        try validateName(name)
        var key = normalizedName(name)
        let sourceKey = normalizedName(source.lastPathComponent)
        var destination = parent.appendingPathComponent(name)
        var targetsAnotherSelectedItem = key != sourceKey && selectedNames.contains(key)
        let targetsExistingItem: Bool
        if key == sourceKey { targetsExistingItem = false }
        else { targetsExistingItem = try entryInfo(destination) != nil }
        let duplicatesProposedTarget = proposed.contains(key)
        if targetsAnotherSelectedItem || targetsExistingItem || duplicatesProposedTarget {
          switch collisionPolicy {
          case .fail:
            throw failure(NL("目标已存在：{0}", destination.path))
          case .keepBoth:
            let candidate = name
            var number = 1
            while true {
              name = try batchDuplicateName(candidate, directory: isDirectory, number: number)
              key = normalizedName(name)
              destination = parent.appendingPathComponent(name)
              number += 1
              targetsAnotherSelectedItem = selectedNames.contains(key)
              let targetExists = try entryInfo(destination) != nil
              let unavailable = targetsAnotherSelectedItem || proposed.contains(key) || targetExists
              if !unavailable { break }
            }
            guard proposed.insert(key).inserted else { throw failure(NL("目标已存在：{0}", destination.path)) }
          }
        } else {
          _ = proposed.insert(key)
        }
        plan.append((source, name, try identity(source)))
      }
      var changes: [FileActionChange] = []
      var succeeded: [URL] = []
      for (source, name, identity) in plan {
        if source.lastPathComponent == name { succeeded.append(source); continue }
        do { let change = try rename(source, to: name, expectedIdentity: identity); changes.append(change); succeeded.append(change.destination) }
        catch { return FileActionResult(succeeded: succeeded, errors: [error.localizedDescription], changes: changes) }
      }
      return FileActionResult(succeeded: succeeded, errors: [], changes: changes)
    } catch { return FileActionResult(succeeded: [], errors: [error.localizedDescription], changes: []) }
  }

  /// Preview uses the same transform as execution and deliberately does not
  /// touch the filesystem or reserve names.
  public static func batchRenamePreview(_ sources: [URL], options: BatchRenameOptions) throws -> [String] {
    if let extensionOverride = options.extensionOverride { _ = try normalizedExtension(extensionOverride) }
    return try sources.enumerated().map { index, source in
      let name = try batchRenameName(source, index: index, options: options)
      try validateName(name)
      return name
    }
  }

  /// Return literal chunks removed while changing a reference source name.
  /// `nil` means the edit also inserted or rearranged text, which is not safe
  /// to apply as a deletion rule to other selected entries.
  public static func batchRenameRemovedText(original: String, edited: String) -> [String]? {
    var originalIndex = original.startIndex
    var editedIndex = edited.startIndex
    var removed = ""
    var chunks: [String] = []
    while originalIndex < original.endIndex {
      let character = original[originalIndex]
      if editedIndex < edited.endIndex, character == edited[editedIndex] {
        if !removed.isEmpty { chunks.append(removed); removed = "" }
        edited.formIndex(after: &editedIndex)
      } else {
        removed.append(character)
      }
      original.formIndex(after: &originalIndex)
    }
    guard editedIndex == edited.endIndex else { return nil }
    if !removed.isEmpty { chunks.append(removed) }
    return chunks
  }

  private static func batchRenameName(_ source: URL, index: Int, options: BatchRenameOptions) throws -> String {
    let directory = (try source.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true
    let originalExtension = directory ? "" : source.pathExtension
    var stem = directory || originalExtension.isEmpty ? source.lastPathComponent : source.deletingPathExtension().lastPathComponent
    for text in options.removeTexts where !text.isEmpty { stem = stem.replacingOccurrences(of: text, with: "") }
    if !options.find.isEmpty { stem = stem.replacingOccurrences(of: options.find, with: options.replacement) }
    if options.removeBracketedContent { stem = removeBracketedContent(from: stem) }
    switch options.casing {
    case .preserve: break
    case .lowercase: stem = stem.localizedLowercase
    case .uppercase: stem = stem.localizedUppercase
    case .capitalized: stem = stem.localizedCapitalized
    }
    stem = options.prefix + stem + options.suffix
    if let sequence = options.sequence {
      guard sequence.start >= 0, (0...12).contains(sequence.padding) else { throw failure(NL("编号起始值或位数无效。")) }
      let (number, overflow) = sequence.start.addingReportingOverflow(index)
      guard !overflow, number >= 0 else { throw failure(NL("编号起始值或位数无效。")) }
      let text = sequence.padding == 0 ? String(number) : String(format: "%0*ld", sequence.padding, number)
      stem += sequence.separator + text
    }
    let ext: String
    if directory { ext = "" }
    else if let override = options.extensionOverride { ext = try normalizedExtension(override) }
    else { ext = originalExtension }
    return stem + (ext.isEmpty ? "" : ".\(ext)")
  }

  private static func batchDuplicateName(_ name: String, directory: Bool, number: Int) throws -> String {
    let ext = directory || URL(fileURLWithPath: name).pathExtension.isEmpty ? "" : ".\(URL(fileURLWithPath: name).pathExtension)"
    let stem = ext.isEmpty ? name : URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
    let suffix = " (\(number))"
    let maximumStemBytes = 255 - suffix.utf8.count - ext.utf8.count
    guard maximumStemBytes > 0 else { throw failure(NL("名称过长，无法添加编号。")) }
    var shortened = stem
    while shortened.utf8.count > maximumStemBytes { shortened.removeLast() }
    let result = shortened + suffix + ext
    try validateName(result)
    return result
  }

  private static func normalizedName(_ name: String) -> String {
    name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
  }

  private static func normalizedExtension(_ value: String) throws -> String {
    let ext = value.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "."))
    guard !ext.contains("/"), !ext.contains(":"), !ext.contains("\0") else { throw failure(NL("扩展名无效。")) }
    return ext
  }

  private static func removeBracketedContent(from value: String) -> String {
    let expression = "\\([^)]*\\)|\\[[^]]*\\]|\\{[^}]*\\}|（[^）]*）|【[^】]*】"
    guard let regex = try? NSRegularExpression(pattern: expression) else { return value }
    var result = value
    while let match = regex.firstMatch(in: result, range: NSRange(result.startIndex..., in: result)) {
      guard let range = Range(match.range, in: result) else { break }
      result.removeSubrange(range)
    }
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public static func transfer(_ sources: [URL], to directory: URL, move: Bool, control: FileTransferControl? = nil, testTrash: URL? = nil, trashStore: TrashStore? = nil) -> FileActionResult {
    var hooks = TransferHooks(); hooks.control = control
    return transfer(sources, to: directory, move: move, hooks: hooks, testTrash: testTrash, trashStore: trashStore)
  }

  static func transfer(_ sources: [URL], to directory: URL, move: Bool, hooks: TransferHooks, testTrash: URL? = nil, trashStore: TrashStore? = nil) -> FileActionResult {
    var succeeded: [URL] = []
    var errors: [String] = []
    var changes: [FileActionChange] = []
    var transfers: [FileTransferItem] = []
    var seen = Set<URL>()
    items: for input in sources where seen.insert(input).inserted {
      if hooks.control?.isCancelled == true { if errors.isEmpty { errors.append(NL("已取消")) }; break }
      var destinationName = input.lastPathComponent
      while true {
      do {
        let source = try existingURL(input)
        if move { try validateModificationSource(source) }
        let directory = try directoryURL(directory)
        try rejectDescendant(source, directory: directory)
        let sameFolder = try sameDirectory(source.deletingLastPathComponent(), directory)
        if move && sameFolder {
          transfers.append(FileTransferItem(source: input, destination: source, outcome: .moved, method: .noOp, contentVerified: false, datesVerified: false, recoveryLocations: [], message: nil))
          succeeded.append(source)
          continue items
        }
        let destination: URL
        if sameFolder {
          destination = try copyBeside(source, in: directory, hooks: hooks, transfers: &transfers)
          if let message = transfers.last?.message { errors.append(message) }
        } else {
          destination = directory.appendingPathComponent(destinationName)
          let item = try VerifiedTransfer.perform(source, to: destination, move: move, hooks: hooks)
          transfers.append(item)
          if let message = item.message { errors.append(message) }
        }
        succeeded.append(destination)
        changes.append(FileActionChange(source: source, destination: destination, kind: move ? .move : .copy))
        break
      } catch {
        let typed = error as? FileTransferFailure
        if typed?.retryRequested == true, hooks.control?.isCancelled != true { continue }
        let canRetry = typed == nil || typed?.item.outcome == .failed
        if canRetry, typed?.handled != true, hooks.control?.isCancelled != true, !(error is CancellationError) {
          let candidate = directory.appendingPathComponent(destinationName)
          let collision = (try? entryInfo(candidate)) != nil
          let replacement = !move && collision && isCollision(error) && hooks.control != nil
            ? try? CopyReplacement(source: input, destination: candidate) : nil
          let decision = hooks.control?.decide(FileTransferProblem(source: input, destination: candidate, message: error.localizedDescription, propertyLoss: false, collision: collision, canReplace: replacement != nil)) ?? .skip
          if decision == .replace, let replacement {
            do {
              let item = try replacement.copy(hooks: hooks, testTrash: testTrash, trashStore: trashStore, changes: &changes, errors: &errors)
              transfers.append(item)
              if let message = item.message { errors.append(message) }
              succeeded.append(candidate)
              changes.append(FileActionChange(source: replacement.source, destination: item.destination, kind: .copy))
            } catch {
              if let failure = error as? FileTransferFailure { transfers.append(failure.item) }
              errors.append("\(input.path): \(error.localizedDescription)")
            }
            break
          }
          if decision == .keepBoth, collision {
            for number in 2...10_000 {
              guard let name = try? numberedName(input, suffix: " (\(number))") else { break }
              if (try? requireAbsent(directory.appendingPathComponent(name))) != nil { destinationName = name; break }
            }
            if destinationName != candidate.lastPathComponent { continue }
          }
          if decision == .retry { continue }
          if decision == .cancel { hooks.control?.cancel() }
        }
        if let failure = error as? FileTransferFailure { transfers.append(failure.item) }
        else { transfers.append(FileTransferItem(source: input, destination: directory.appendingPathComponent(input.lastPathComponent), outcome: .failed, method: .systemCopy, contentVerified: false, datesVerified: false, recoveryLocations: [], message: error.localizedDescription)) }
        errors.append("\(input.path): \(error.localizedDescription)")
        break
      }
      }
    }
    return FileActionResult(succeeded: succeeded, errors: errors, changes: changes, transfers: transfers)
  }

  private struct CopyReplacement {
    let source: URL
    let destination: URL
    let incoming: TransferStamp
    let previous: TransferStamp
    let parent: TransferStamp
    let recycle: PreparedDeletion

    init(source: URL, destination: URL) throws {
      self.source = try existingURL(source)
      self.destination = try existingURL(destination)
      incoming = TransferStamp(try requiredInfo(self.source))
      previous = TransferStamp(try requiredInfo(self.destination))
      guard incoming.type == S_IFREG, previous.type == S_IFREG, !incoming.sameObject(previous) else {
        throw posixError(destination, code: EINVAL)
      }
      parent = TransferStamp(try directoryInfo(destination.deletingLastPathComponent()))
      recycle = try PreparedDeletion.prepare([self.destination])[0]
    }

    func copy(hooks: TransferHooks, testTrash: URL?, trashStore: TrashStore?, changes: inout [FileActionChange], errors: inout [String]) throws -> FileTransferItem {
      try hooks.control?.check()
      let original = try recycle.validateForRecycle()
      guard parent.sameObject(TransferStamp(try directoryInfo(original.deletingLastPathComponent()))) else {
        throw posixError(destination, code: ESTALE)
      }
      try incoming.requireUnchanged(TransferStamp(try requiredInfo(source)), control: hooks.control, stage: "replace.source.changed")
      try previous.requireUnchanged(TransferStamp(try requiredInfo(original)), control: hooks.control, stage: "replace.destination.changed")
      let recycled = trash([original], testTrash: testTrash)
      guard let backup = recycled.changes.first else {
        throw failure(recycled.errors.joined(separator: "\n"))
      }
      func rememberBackup() {
        if backup.destinationIdentity == previous.identity { changes.append(backup) }
        do { try trashStore?.remember(backup.destination, original: original) }
        catch { errors.append(NL("文件已移入回收站，但无法保存原位置。请使用“还原到…”恢复。")) }
      }
      do {
        guard previous.unchanged(TransferStamp(try requiredInfo(backup.destination)), ignoreChangeTime: true),
          parent.sameObject(TransferStamp(try directoryInfo(destination.deletingLastPathComponent()))) else {
          throw posixError(destination, code: ESTALE)
        }
        try incoming.requireUnchanged(TransferStamp(try requiredInfo(source)), control: hooks.control, stage: "replace.source.changed")
        let item = try VerifiedTransfer.perform(source, to: original, move: false, hooks: hooks)
        rememberBackup()
        return item
      } catch {
        let copyError = error
        do {
          guard let identity = backup.destinationIdentity, try FileActions.identity(backup.destination) == identity,
            parent.sameObject(TransferStamp(try directoryInfo(original.deletingLastPathComponent()))) else {
            throw posixError(destination, code: ESTALE)
          }
          // Restore exclusively, including when a new occupant appeared while copying.
          try moveExclusively(backup.destination, to: original)
        } catch {
          rememberBackup()
          errors.append(NL("恢复位置：{0}", backup.destination.path))
        }
        throw copyError
      }
    }
  }

  public static func trash(_ sources: [URL], testTrash: URL? = nil) -> FileActionResult {
    var succeeded: [URL] = []
    var errors: [String] = []
    var changes: [FileActionChange] = []
    for input in sources {
      do {
        let source = try existingURL(input)
        try validateModificationSource(source)
        let destination: URL
        if let testTrash {
          let directory = try testTrashDirectory(testTrash, source: source)
          try rejectDescendant(source, directory: directory)
          destination = try moveToTestTrash(source, directory: directory)
        } else {
          var resultingURL: NSURL?
          try FileManager.default.trashItem(at: source, resultingItemURL: &resultingURL)
          guard let resultingURL else {
            // The operation has happened even if the OS does not supply its undo location.
            succeeded.append(source)
            errors.append("\(source.path) was moved to Trash, but macOS did not return its location. Automatic undo is unavailable.")
            continue
          }
          destination = resultingURL as URL
        }
        succeeded.append(destination)
        changes.append(FileActionChange(source: source, destination: destination, kind: .trash))
      } catch {
        errors.append("\(input.path): \(error.localizedDescription)")
      }
    }
    return FileActionResult(succeeded: succeeded, errors: errors, changes: changes)
  }

  public static func undo(_ changes: [FileActionChange], testTrash: URL? = nil, control: FileTransferControl? = nil) -> FileActionResult {
    var succeeded: [URL] = []
    var errors: [String] = []
    var inverses: [FileActionChange] = []
    var transfers: [FileTransferItem] = []
    items: for change in changes.reversed() {
      if control?.isCancelled == true { if errors.isEmpty { errors.append(NL("已取消")) }; break }
      while true {
      do {
        guard let expected = change.destinationIdentity, try identity(change.destination) == expected else {
          throw failure(NL("项目已被其他文件替换，无法撤销。"))
        }
        switch change.kind {
        case .copy, .create:
          // Undo never deletes: even a subsequently modified copy is recoverable from Trash.
          let result = trash([change.destination], testTrash: testTrash)
          succeeded.append(contentsOf: result.succeeded)
          errors.append(contentsOf: result.errors)
          inverses.append(contentsOf: result.changes)
        case .move, .trash:
          guard let original = change.source else {
            throw failure(NL("撤销记录缺少原始位置。"))
          }
          let current = try existingURL(change.destination)
          try validateModificationSource(current)
          let originalURL = try validatedURL(original)
          if current.path == originalURL.path {
            succeeded.append(current)
            continue items
          }
          let parent = try directoryURL(originalURL.deletingLastPathComponent())
          try rejectDescendant(current, directory: parent)
          // Route through rename for case-only undo, including its exclusive temporary hop.
          if try sameDirectory(current.deletingLastPathComponent(), parent) {
            let inverse = try rename(current, to: originalURL.lastPathComponent)
            succeeded.append(inverse.destination)
            inverses.append(inverse)
          } else {
            var hooks = TransferHooks(); hooks.control = control
            let item = try VerifiedTransfer.perform(current, to: originalURL, move: true, hooks: hooks)
            transfers.append(item)
            if let message = item.message { errors.append(message) }
            succeeded.append(originalURL)
            inverses.append(FileActionChange(source: current, destination: originalURL, kind: .move))
          }
        }
        break
      } catch {
        let typed = error as? FileTransferFailure
        if typed?.handled != true, control?.isCancelled != true, !(error is CancellationError), typed == nil || typed?.item.outcome == .failed {
          let choice = control?.decide(FileTransferProblem(source: change.destination, destination: change.source ?? change.destination, message: error.localizedDescription, propertyLoss: false)) ?? .skip
          if choice == .retry { continue }
          if choice == .cancel { control?.cancel() }
        }
        if let failure = error as? FileTransferFailure { transfers.append(failure.item) }
        errors.append("\(change.destination.path): \(error.localizedDescription)")
        break
      }
      }
    }
    return FileActionResult(succeeded: succeeded, errors: errors, changes: inverses, transfers: transfers)
  }

  public static func identity(_ url: URL) throws -> String {
    let value = try requiredInfo(validatedURL(url))
    return "\(value.st_dev):\(value.st_ino):\(value.st_birthtimespec.tv_sec):\(value.st_birthtimespec.tv_nsec)"
  }

  public static func validateModificationSource(_ input: URL) throws {
    let source = try validatedURL(input)
    // Resolve parents only: a user-created symlink to a protected folder is still its own item.
    func path(_ url: URL) -> String { url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent).path }
    let protected = ["/System", "/Library", "/Applications", "/Users", FileManager.default.homeDirectoryForCurrentUser.path].map { URL(fileURLWithPath: $0) }
    guard !protected.contains(where: { $0.path == source.path || path($0) == path(source) }) else { throw failure(NL("不能修改这个系统位置。")) }
  }

  private struct ActionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  private static func failure(_ message: String) -> ActionError {
    ActionError(message: message)
  }

  private static func posixError(_ url: URL, code: Int32 = errno) -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: url.path])
  }

  private static func validateName(_ name: String) throws {
    guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      name != ".", name != "..", !name.contains("/"), !name.contains(":"),
      !name.contains("\0"), name.utf8.count <= 255 else {
      throw failure(NL("名称须为 1–255 字节，不能留空、使用“.”或“..”，或包含 /、: 和空字符。"))
    }
  }

  private static func validatedURL(_ url: URL) throws -> URL {
    guard url.isFileURL, url.baseURL == nil, url.user == nil, url.password == nil, url.port == nil, url.path.hasPrefix("/"), !url.path.contains("\0"),
      url.host == nil || url.host == "" || url.host == "localhost",
      url.query == nil, url.fragment == nil else {
      throw failure(NL("请选择有效的本地绝对路径。"))
    }
    let normalized = url.standardizedFileURL
    guard normalized.path != "/", !normalized.path.isEmpty else {
      throw failure(NL("不能操作文件系统根目录。"))
    }
    return normalized
  }

  // lstat is intentional: dangling symlinks are entries, not missing targets.
  private static func entryInfo(_ url: URL) throws -> stat? {
    var info = stat()
    let result = url.path.withCString { Darwin.lstat($0, &info) }
    if result == 0 { return info }
    let code = errno
    if code == ENOENT { return nil }
    throw posixError(url, code: code)
  }

  private static func requiredInfo(_ url: URL) throws -> stat {
    guard let info = try entryInfo(url) else {
      throw failure(NL("项目不存在：{0}", url.path))
    }
    return info
  }

  private static func existingURL(_ url: URL) throws -> URL {
    let url = try validatedURL(url)
    _ = try requiredInfo(url)
    return url
  }

  private static func directoryInfo(_ url: URL) throws -> stat {
    var info = stat()
    guard url.path.withCString({ Darwin.fstatat(AT_FDCWD, $0, &info, 0) }) == 0 else {
      throw posixError(url)
    }
    guard info.st_mode & S_IFMT == S_IFDIR else {
      throw failure(NL("不是文件夹：{0}", url.path))
    }
    return info
  }

  private static func directoryURL(_ url: URL) throws -> URL {
    let url = try validatedURL(url)
    guard url.resolvingSymlinksInPath().path != "/" else {
      throw failure(NL("不能操作文件系统根目录。"))
    }
    _ = try directoryInfo(url)
    return url
  }

  private static func sameIdentity(_ lhs: stat, _ rhs: stat) -> Bool {
    lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino
  }

  private static func sameDirectory(_ lhs: URL, _ rhs: URL) throws -> Bool {
    try sameIdentity(directoryInfo(lhs), directoryInfo(rhs))
  }

  private static func rejectDescendant(_ source: URL, directory: URL) throws {
    let sourceInfo = try requiredInfo(source)
    guard sourceInfo.st_mode & S_IFMT == S_IFDIR else { return }
    // Walking canonical ancestors by identity also catches case aliases on insensitive volumes.
    var ancestor = directory.resolvingSymlinksInPath().standardizedFileURL
    while true {
      if try sameIdentity(sourceInfo, directoryInfo(ancestor)) {
        throw failure(NL("不能将文件夹复制或移动到其自身或子文件夹。"))
      }
      if ancestor.path == "/" { break }
      ancestor.deleteLastPathComponent()
    }
  }

  private static func requireAbsent(_ destination: URL) throws {
    if try entryInfo(destination) != nil {
      throw posixError(destination, code: EEXIST)
    }
  }

  private static func moveExclusively(_ source: URL, to destination: URL) throws {
    _ = try VerifiedTransfer.perform(source, to: destination, move: true)
  }

  private static func isCollision(_ error: Error) -> Bool {
    let error = error as NSError
    return (error.domain == NSPOSIXErrorDomain && error.code == Int(EEXIST))
      || (error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError)
  }

  private static func numberedName(_ source: URL, suffix: String) throws -> String {
    let info = try requiredInfo(source)
    let isDirectory = info.st_mode & S_IFMT == S_IFDIR
    let ext = isDirectory || source.pathExtension.isEmpty ? "" : ".\(source.pathExtension)"
    var stem = ext.isEmpty ? source.lastPathComponent : source.deletingPathExtension().lastPathComponent
    let available = 255 - suffix.utf8.count - ext.utf8.count
    guard available > 0 else { throw failure(NL("扩展名过长，无法添加副本后缀。")) }
    while stem.utf8.count > available { stem.removeLast() }
    let name = stem + suffix + ext
    try validateName(name)
    return name
  }

  private static func copyBeside(_ source: URL, in directory: URL, hooks: TransferHooks, transfers: inout [FileTransferItem]) throws -> URL {
    for number in 1...10_000 {
      let suffix = " - " + NL("副本") + (number == 1 ? "" : " (\(number))")
      let destination = directory.appendingPathComponent(try numberedName(source, suffix: suffix))
      do {
        let item = try VerifiedTransfer.perform(source, to: destination, move: false, hooks: hooks)
        transfers.append(item)
        return destination
      } catch {
        if !isCollision(error) { throw error }
      }
    }
    throw failure(NL("无法生成未被占用的副本名称。"))
  }

  // Test trash is deliberately restricted to an existing directory in the same top-level
  // fixture subtree under FileManager.temporaryDirectory. Symlink parents are canonicalized;
  // a source symlink itself is not followed, so tests may safely trash dangling link objects.
  private static func testTrashDirectory(_ url: URL, source: URL) throws -> URL {
    let directory = try directoryURL(url)
    let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
    let trashPath = directory.resolvingSymlinksInPath().path
    let prefix = temporary.path.hasSuffix("/") ? temporary.path : temporary.path + "/"
    guard trashPath.hasPrefix(prefix) else {
      throw failure("Test trash must be inside a temporary fixture directory.")
    }
    let relative = String(trashPath.dropFirst(prefix.count)).split(separator: "/")
    guard relative.count >= 2 else {
      throw failure("Test trash must be below, not equal to, the temporary fixture root.")
    }
    let fixturePrefix = prefix + relative[0] + "/"
    let sourcePath = source.deletingLastPathComponent().resolvingSymlinksInPath()
      .appendingPathComponent(source.lastPathComponent).path
    guard sourcePath.hasPrefix(fixturePrefix) else {
      throw failure("Test trash may only receive items from its own temporary fixture subtree.")
    }
    return directory
  }

  private static func moveToTestTrash(_ source: URL, directory: URL) throws -> URL {
    for number in 1...10_000 {
      let name = number == 1 ? source.lastPathComponent : try numberedName(source, suffix: " (\(number))")
      let destination = directory.appendingPathComponent(name)
      do {
        try moveExclusively(source, to: destination)
        return destination
      } catch {
        if !isCollision(error) { throw error }
      }
    }
    throw failure("Could not find an unused test trash name after 10,000 attempts.")
  }
}
