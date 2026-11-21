import Foundation
import Darwin

public enum FileTransferDecision: Sendable { case retry, skip, cancel, keepBoth, replace, continueWithoutProperties }
public struct FileTransferProblem: Sendable {
  public let source: URL
  public let destination: URL
  public let message: String
  public let propertyLoss: Bool
  public var moving: Bool = false
  public var collision: Bool = false
  public let canReplace: Bool
  public init(source: URL, destination: URL, message: String, propertyLoss: Bool, moving: Bool = false, collision: Bool = false, canReplace: Bool = false) {
    self.source = source; self.destination = destination; self.message = message; self.propertyLoss = propertyLoss; self.moving = moving; self.collision = collision
    self.canReplace = canReplace
  }
}
public enum FileTransferMode: Sendable { case system, serverSide }
public struct FileTransferProgress: Sendable {
  public let source: URL
  public let completedBytes: Int64
  public let totalBytes: Int64
  public let mode: FileTransferMode
  public let bytesPerSecond: Double?
  public let observedAt: TimeInterval
  public init(source: URL, completedBytes: Int64, totalBytes: Int64, mode: FileTransferMode = .system, bytesPerSecond: Double? = nil, observedAt: TimeInterval = ProcessInfo.processInfo.systemUptime) { self.source = source; self.completedBytes = completedBytes; self.totalBytes = totalBytes; self.mode = mode; self.bytesPerSecond = bytesPerSecond; self.observedAt = observedAt }
}

/// One user operation, shared by its background worker and window. Never process-global.
public final class FileTransferControl: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  private var lastProgress = Date.distantPast
  private var lastSource: URL?
  private var lastMode: FileTransferMode?
  private var serverSideSources = Set<URL>()
  private var rate = TransferRateEstimator()
  private var currentPhase: FileTransferPhase?
  private var timingDepth = 0
  public let serverSideCopy: (any ServerSideCopyProvider)?
  private let onProblem: ((FileTransferProblem) -> FileTransferDecision)?
  private let onProgress: ((FileTransferProgress) -> Void)?
  private let onPhase: ((FileTransferPhase) -> Void)?
  private let onTiming: ((FileTransferTiming) -> Void)?
  public init(onProblem: ((FileTransferProblem) -> FileTransferDecision)? = nil, onProgress: ((FileTransferProgress) -> Void)? = nil, serverSideCopy: (any ServerSideCopyProvider)? = nil, onPhase: ((FileTransferPhase) -> Void)? = nil, onTiming: ((FileTransferTiming) -> Void)? = nil) {
    self.onProblem = onProblem; self.onProgress = onProgress; self.serverSideCopy = serverSideCopy; self.onPhase = onPhase; self.onTiming = onTiming
  }
  public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
  public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
  func check() throws { if isCancelled { throw CancellationError() } }
  func decide(_ problem: FileTransferProblem) -> FileTransferDecision {
    if isCancelled { return .cancel }
    let started = ProcessInfo.processInfo.systemUptime
    let decision = onProblem?(problem) ?? .skip
    recordTiming("interaction.problem", seconds: ProcessInfo.processInfo.systemUptime - started)
    if decision == .cancel { cancel() }
    return decision
  }
  public func setPhase(_ phase: FileTransferPhase) {
    lock.lock()
    let changed = !cancelled && phase != currentPhase
    if changed { currentPhase = phase }
    lock.unlock()
    if changed { onPhase?(phase) }
  }
  public func recordTiming(_ stage: String, seconds: TimeInterval, succeeded: Bool = true, metrics: [String: Double] = [:]) {
    lock.lock(); let depth = timingDepth; lock.unlock()
    onTiming?(FileTransferTiming(stage: stage, seconds: max(0, seconds), depth: depth, succeeded: succeeded, metrics: metrics))
  }
  public static func measure<T>(_ control: FileTransferControl?, _ stage: String, phase: FileTransferPhase, _ body: () throws -> T) rethrows -> T {
    guard let control else { return try body() }
    control.setPhase(phase)
    control.lock.lock(); let depth = control.timingDepth; control.timingDepth += 1; control.lock.unlock()
    let start = ProcessInfo.processInfo.systemUptime
    var succeeded = false
    defer {
      control.lock.lock(); control.timingDepth -= 1; control.lock.unlock()
      control.onTiming?(FileTransferTiming(stage: stage, seconds: max(0, ProcessInfo.processInfo.systemUptime - start), depth: depth, succeeded: succeeded, metrics: [:]))
    }
    let value = try body(); succeeded = true; return value
  }
  public func reportServerSideProgress(_ source: URL, completed: Int64, total: Int64) {
    setPhase(.copying)
    if completed > 0 { recordServerSideCopy(source) }
    report(source, completed: max(0, min(completed, total)), total: max(0, total), mode: .serverSide)
  }
  func recordServerSideCopy(_ source: URL) { lock.lock(); serverSideSources.insert(source); lock.unlock() }
  func usedServerSideCopy(under source: URL) -> Bool {
    lock.lock(); defer { lock.unlock() }; return serverSideSources.contains { $0.path == source.path || $0.path.hasPrefix(source.path + "/") }
  }
  func report(_ source: URL, completed: Int64, total: Int64, mode: FileTransferMode = .system) {
    let now = Date(), observed = ProcessInfo.processInfo.systemUptime
    lock.lock()
    let speed = rate.sample(source: source, mode: mode, completed: completed, at: observed)
    let deliver = source != lastSource || mode != lastMode || now.timeIntervalSince(lastProgress) >= 0.1 || completed >= total
    if deliver { lastProgress = now; lastSource = source; lastMode = mode }
    lock.unlock()
    if deliver { onProgress?(FileTransferProgress(source: source, completedBytes: completed, totalBytes: total, mode: mode, bytesPerSecond: speed, observedAt: observed)) }
  }
}

/// System copy preserves native streams/metadata and supplies progress without a second data pass.
/// Copy explicit ACLs while letting the system retain inherited destination entries.
enum NativeTransferCopy {
  struct Retry: Error {}
  /// Per-operation syscall injection for isolated regression checks, never a global switch.
  struct Hooks {
    var synchronizedMetadata = false
    var descriptorCopy: ((Int32, Int32, copyfile_state_t, copyfile_flags_t) -> Int32)?
    var synchronize: ((Int32) -> Int32)?
  }
  struct Failure: LocalizedError {
    let underlying: NSError
    let handled: Bool
    var errorDescription: String? { underlying.localizedDescription }
  }
  private final class State {
    let control: FileTransferControl?
    let source: URL
    let total: Int64
    var files: [String: Int64] = [:]
    var propertiesLost = false
    var completed: Int64 = 0
    var failureCode: Int32 = 0
    var failureHandled = false
    var retryRequested = false
    let destination: URL
    let moving: Bool
    init(_ control: FileTransferControl?, _ source: URL, _ destination: URL, _ total: Int64, _ moving: Bool) { self.control = control; self.source = source; self.destination = destination; self.total = total; self.moving = moving }
  }
  private static let callback: copyfile_callback_t = { what, stage, state, source, _, context in
    guard let context else { return COPYFILE_QUIT }
    let value = Unmanaged<State>.fromOpaque(context).takeUnretainedValue()
    if value.control?.isCancelled == true { return COPYFILE_QUIT }
    if what == COPYFILE_COPY_XATTR { value.control?.setPhase(.properties) }
    if stage == COPYFILE_ERR {
      value.failureCode = errno
      if what == COPYFILE_COPY_XATTR {
        var attribute: UnsafePointer<CChar>?
        if let state { _ = copyfile_state_get(state, UInt32(COPYFILE_STATE_XATTRNAME), &attribute) }
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: Int(value.failureCode))
        let message = attribute.map { NL("系统或目标卷拒绝写入扩展属性“{0}”（错误码 {1}）。", String(cString: $0), String(value.failureCode)) } ?? underlying.localizedDescription
        let error = NSError(domain: NSPOSIXErrorDomain, code: underlying.code, userInfo: [NSLocalizedDescriptionKey: message])
        let choice = value.control?.decide(FileTransferProblem(source: value.source, destination: value.destination, message: error.localizedDescription, propertyLoss: true, moving: value.moving)) ?? .skip
        value.failureHandled = value.control != nil && (choice == .skip || choice == .cancel)
        // The system xattr error callback treats CONTINUE as accepting the failure,
        // not retrying fsetxattr. Stop this attempt and rerun metadata explicitly.
        if choice == .retry { value.retryRequested = true; return COPYFILE_QUIT }
        if choice == .continueWithoutProperties { value.propertiesLost = true; return COPYFILE_CONTINUE }
      }
      return COPYFILE_QUIT
    }
    if what == COPYFILE_COPY_DATA, let state {
      var copied: off_t = 0
      if copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied) == 0 {
        let path = source.map { String(cString: $0) } ?? value.source.path
        value.completed += max(0, copied - (value.files[path] ?? 0)); value.files[path] = copied
        value.control?.setPhase(.copying)
        value.control?.report(value.source, completed: min(value.completed, value.total), total: value.total)
        if value.total > 0 && value.completed >= value.total { value.control?.setPhase(.properties) }
      }
    }
    return COPYFILE_CONTINUE
  }
  static func copy(_ source: URL, to destination: URL, total: Int64, control: FileTransferControl?, moving: Bool) throws -> Bool {
    try run(source, to: destination, total: total, control: control, moving: moving, descriptors: nil, hooks: Hooks())
  }
  /// The caller exclusively creates and holds the destination; fcopyfile cannot replace a path.
  static func copyDescriptors(_ source: Int32, to destination: Int32, sourceURL: URL, destinationURL: URL, total: Int64, control: FileTransferControl?, moving: Bool, link: Bool, hooks: Hooks = Hooks()) throws -> Bool {
    try run(sourceURL, to: destinationURL, total: total, control: control, moving: moving, descriptors: (source, destination, link), hooks: hooks)
  }
  static func explicitACL(_ descriptor: Int32) throws -> String? {
    guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
      if errno == ENOTSUP || errno == ENOENT { return nil }
      throw VerifiedTransfer.posix()
    }
    defer { acl_free(UnsafeMutableRawPointer(acl)) }
    var explicit = acl_init(0)
    guard explicit != nil else { throw VerifiedTransfer.posix() }
    defer { if let explicit { acl_free(UnsafeMutableRawPointer(explicit)) } }
    var entry: acl_entry_t?, count = 0
    var next = Int32(ACL_FIRST_ENTRY.rawValue)
    while acl_get_entry(acl, next, &entry) == 0 {
      next = Int32(ACL_NEXT_ENTRY.rawValue)
      var flags: acl_flagset_t?
      guard acl_get_flagset_np(entry.map { UnsafeMutableRawPointer($0) }, &flags) == 0 else { throw VerifiedTransfer.posix() }
      if acl_get_flag_np(flags, ACL_ENTRY_INHERITED) == 1 { continue }
      var copy: acl_entry_t?
      guard acl_create_entry(&explicit, &copy) == 0, acl_copy_entry(copy, entry) == 0 else { throw VerifiedTransfer.posix() }
      count += 1
    }
    guard count > 0 else { return nil }
    guard let text = acl_to_text(explicit, nil) else { throw VerifiedTransfer.posix() }
    defer { acl_free(text) }
    return String(cString: text)
  }
  private static func run(_ source: URL, to destination: URL, total: Int64, control: FileTransferControl?, moving: Bool, descriptors: (Int32, Int32, Bool)?, hooks: Hooks) throws -> Bool {
    try control?.check()
    var serverSide = false
    if let (from, to, link) = descriptors, !link, total > 0, let control, let provider = control.serverSideCopy,
       provider.isCandidate(source: source, destination: destination) {
      serverSide = try FileTransferControl.measure(control, "smb.transfer", phase: .connecting) {
        try provider.copy(sourceDescriptor: from, destinationDescriptor: to, source: source, destination: destination, control: control)
      }
      if serverSide { control.recordServerSideCopy(source) }
      try control.check()
    }
    guard let state = copyfile_state_alloc() else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOMEM)) }
    defer { copyfile_state_free(state) }
    let value = State(control, source, destination, total, moving)
    let context = Unmanaged.passUnretained(value).toOpaque()
    let pointer = unsafeBitCast(callback, to: UnsafeRawPointer.self)
    guard copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), pointer) == 0,
          copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), context) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    // No COPYFILE_MOVE: the transfer owns the separate, guarded source-cleanup step.
    let flags = copyfile_flags_t(COPYFILE_DATA | COPYFILE_STAT | COPYFILE_XATTR | COPYFILE_ACL | COPYFILE_RECURSIVE | COPYFILE_EXCL | COPYFILE_NOFOLLOW | COPYFILE_CLONE)
    if !serverSide { control?.setPhase(.copying); control?.report(source, completed: 0, total: total) }
    func invoke(_ flags: copyfile_flags_t) -> Int32 {
      withExtendedLifetime(value) {
        if let (from, to, _) = descriptors { return hooks.descriptorCopy?(from, to, state, flags) ?? fcopyfile(from, to, state, flags) }
        return copyfile(source.path, destination.path, state, flags)
      }
    }
    func checkedCopy(_ flags: copyfile_flags_t, stage: String, phase: FileTransferPhase) throws {
      value.failureCode = 0; value.failureHandled = false; value.retryRequested = false
      try FileTransferControl.measure(control, stage, phase: phase) {
        let result = invoke(flags)
        let failureCode = value.failureCode == 0 ? errno : value.failureCode
        try control?.check()
        if value.retryRequested { throw Retry() }
        guard result == 0 else { throw Failure(underlying: NSError(domain: NSPOSIXErrorDomain, code: Int(failureCode)), handled: value.failureHandled) }
      }
    }
    if let (from, to, link) = descriptors, !link,
       try (hooks.synchronizedMetadata || AppleDoubleCompanion.usesSidecars(to)) {
      var info = stat()
      guard fstat(from, &info) == 0 else { throw VerifiedTransfer.posix() }
      let original = TransferStamp(info, precision: try AppleDoubleCompanion.usesSidecars(from) ? 100 : 1)
      if original.type == S_IFREG && !serverSide {
        // SMB write-behind can otherwise overwrite setattr times when the data handle
        // flushes/closes. Synchronize DATA before STAT/XATTR, not after those writes.
        try checkedCopy(copyfile_flags_t(COPYFILE_DATA), stage: "copy.system", phase: .copying)
        try FileTransferControl.measure(control, "copy.flush", phase: .properties) {
          guard (hooks.synchronize?(to) ?? fsync(to)) == 0 else { throw VerifiedTransfer.posix() }
        }
      }
      while true {
        do {
          try checkedCopy(copyfile_flags_t(COPYFILE_STAT | COPYFILE_XATTR | COPYFILE_ACL), stage: "copy.metadata", phase: .properties)
          break
        } catch is Retry {
          try control?.check()
          guard fstat(from, &info) == 0, original.unchanged(TransferStamp(info, precision: original.precision)) else {
            throw VerifiedTransfer.failure("项目在传输期间发生变化，已停止操作。")
          }
          // Held descriptors preserve binding; caller still verifies both paths and
          // the complete tree. Explicit retry repeats metadata, never the DATA pass.
          continue
        }
      }
    } else {
      let descriptorFlags = descriptors.map { _, _, link in
        copyfile_flags_t((link ? COPYFILE_XATTR | COPYFILE_NOFOLLOW : (serverSide ? 0 : COPYFILE_DATA) | COPYFILE_STAT | COPYFILE_XATTR) | COPYFILE_ACL)
      } ?? flags
      try checkedCopy(descriptorFlags, stage: serverSide ? "copy.metadata" : "copy.system", phase: serverSide ? .properties : .copying)
    }
    control?.report(source, completed: total, total: total, mode: serverSide ? .serverSide : .system)
    return value.propertiesLost
  }
}
