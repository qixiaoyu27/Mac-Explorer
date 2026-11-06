import Foundation
import Darwin

public struct NativeCommandResult: Sendable {
  public let output: Data
  public let error: Data
  public let status: Int32
  public var text: String { String(decoding: output, as: UTF8.self) }
  public var errorText: String { String(decoding: error, as: UTF8.self) }
}
public struct NativeCommandError: LocalizedError, Sendable {
  public let result: NativeCommandResult
  public var errorDescription: String? { result.errorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? NL("操作失败（{0}）", result.status) : result.errorText.trimmingCharacters(in: .whitespacesAndNewlines) }
}
private struct CommandCapture {
  let handle: FileHandle
  private var bytes = [UInt8](repeating: 0, count: 65536)
  private(set) var value = Data()
  private(set) var exceeded = false
  private(set) var finished = false

  init(_ pipe: Pipe) throws {
    handle = pipe.fileHandleForReading
    let flags = fcntl(handle.fileDescriptor, F_GETFL)
    guard flags >= 0, fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
  }
  mutating func read(limit: Int) throws -> Bool {
    guard !finished else { return false }
    let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
    if count < 0 {
      if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { return false }
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    if count == 0 { finished = true; return false }
    if count > limit - value.count { exceeded = true }
    else if !exceeded { value.append(contentsOf: bytes.prefix(count)) }
    return true
  }
}
public enum NativeCommand {
  public static func run(executable: String, arguments: [String], directory: URL? = nil, environment: [String: String] = [:], timeout: TimeInterval = 30, limit: Int = 8 * 1024 * 1024, onStart: ((Process) -> Void)? = nil) throws -> NativeCommandResult {
    guard executable.hasPrefix("/"), !executable.contains("\0"), arguments.allSatisfy({ !$0.contains("\0") }), limit > 0, timeout > 0 else { throw CocoaError(.fileReadInvalidFileName) }
    try Task.checkCancellation()
    let process = Process(), output = Pipe(), errors = Pipe()
    defer {
      if process.isRunning { kill(process.processIdentifier, SIGKILL); process.waitUntilExit() }
      for pipe in [output, errors] { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
    }
    var out = try CommandCapture(output), err = try CommandCapture(errors)
    process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments; process.currentDirectoryURL = directory
    process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, next in next }
    process.standardOutput = output; process.standardError = errors; process.standardInput = FileHandle.nullDevice
    try process.run()
    try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close()
    onStart?(process)
    let deadline = Date().addingTimeInterval(timeout)
    var terminated: Date?, drainDeadline: Date?, cancelled = false, timedOut = false
    while true {
      let readOutput = try out.read(limit: limit), readError = try err.read(limit: limit)
      cancelled = cancelled || Task.isCancelled
      if !process.isRunning {
        if out.finished && err.finished { break }
        // Descendants may retain the pipes after the command itself exits.
        if drainDeadline == nil { drainDeadline = Date().addingTimeInterval(2) }
        if Date() >= drainDeadline! { throw CocoaError(.fileReadUnknown) }
      } else if cancelled || Date() >= deadline || out.exceeded || err.exceeded {
        timedOut = timedOut || Date() >= deadline
        if terminated == nil { process.terminate(); terminated = Date() }
        else if Date().timeIntervalSince(terminated!) > 1 { kill(process.processIdentifier, SIGKILL) }
      }
      if !readOutput && !readError { Thread.sleep(forTimeInterval: 0.01) }
    }
    process.waitUntilExit()
    if cancelled { throw CancellationError() }
    if timedOut { throw NSError(domain: "NativeCommand", code: 1, userInfo: [NSLocalizedDescriptionKey: NL("操作超时。")] ) }
    if out.exceeded || err.exceeded { throw NSError(domain: "NativeCommand", code: 2, userInfo: [NSLocalizedDescriptionKey: NL("操作返回的数据超过限制。")] ) }
    let result = NativeCommandResult(output: out.value, error: err.value, status: process.terminationStatus)
    if result.status != 0 { throw NativeCommandError(result: result) }
    return result
  }
}
