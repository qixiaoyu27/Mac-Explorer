import Foundation

@main struct TransferTelemetryChecks {
  static func main() throws {
    var count = 0
    func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
      guard try condition() else { throw NSError(domain: "TransferTelemetryChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
      count += 1
    }
    let a = URL(fileURLWithPath: "/private/tmp/private-name.txt"), b = a.appendingPathExtension("next")
    var estimator = TransferRateEstimator()
    func sample(_ bytes: Int64, _ time: Double, _ source: URL? = nil, _ mode: FileTransferMode = .system) -> Double? {
      estimator.sample(source: source ?? a, mode: mode, completed: bytes, at: time)
    }
    try expect(sample(0, 10) == nil, "No rate before data acknowledgment")
    try expect(sample(0, 100) == nil && sample(1000, 101) == 1000, "Repeated zero-byte preparation does not dilute data speed")
    try expect(sample(2000, 102) == 1000, "Monotonic bytes produce bytes per second")
    try expect(sample(2000, 103) == 1000, "Metadata-only final callbacks do not overwrite the last measured speed")
    try expect(sample(0, 104) == nil && sample(500, 105) == 500, "Retries reset the byte baseline")
    try expect(sample(100, 106, b) == nil, "Changing the current file resets speed")
    try expect(sample(200, 107, b) == 100, "A new file measures independently")
    try expect(sample(300, 108, b, .serverSide) == nil, "Changing transport resets speed")
    try expect(sample(400, 108, b, .serverSide) == nil, "Equal timestamps never produce an infinite rate")
    try expect(sample(500, 107, b, .serverSide) == nil, "Clock regression resets the sampling window")
    estimator = TransferRateEstimator()
    for i in 0...300 { _ = sample(Int64(i * 100), Double(i) / 100) }
    try expect(abs((sample(30100, 3.01) ?? 0) - 10000) < 0.001, "Bounded rolling samples retain a stable measured rate")

    var phases: [FileTransferPhase] = [], timings: [FileTransferTiming] = []
    let control = FileTransferControl(onPhase: { phases.append($0) }, onTiming: { timings.append($0) })
    control.setPhase(.preparing); control.setPhase(.preparing)
    try expect(phases == [.preparing], "Repeated phases are delivered once")
    enum FixtureError: Error { case failure }
    do {
      try FileTransferControl.measure(control, "outer", phase: .copying) {
        try FileTransferControl.measure(control, "inner", phase: .properties) { throw FixtureError.failure }
      }
    } catch FixtureError.failure {}
    try expect(timings.map(\.depth) == [1, 0] && timings.allSatisfy { !$0.succeeded && $0.seconds >= 0 }, "Nested failures preserve stage depth and elapsed time")
    FileTransferControl.measure(control, "next", phase: .verifying) {}
    try expect(timings.last?.depth == 0 && timings.last?.succeeded == true, "Throwing a timed stage restores nesting depth")
    control.cancel(); let oldCount = phases.count; control.setPhase(.finishing)
    try expect(phases.count == oldCount, "Cancellation cannot replace its visible status")

    let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("explorer-telemetry-" + UUID().uuidString)
    try fm.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: root) }
    let unrelated = root.appendingPathComponent("keep.json"); try Data("keep".utf8).write(to: unrelated)
    // Prove pruning affects only this collector's generated report names.
    for _ in 0..<21 { try Data().write(to: root.appendingPathComponent("transfer-" + UUID().uuidString + ".json")) }
    let log = TransferDiagnostics()
    for timing in timings { log.record(timing) }
    log.record(FileTransferTiming(stage: "smb.protocol", seconds: 1, depth: 1, succeeded: true, metrics: ["requests": 12, "result": 0, "error": 0]))
    log.record(FileTransferTiming(stage: a.path, seconds: 1, depth: 0, succeeded: false, metrics: [:]))
    log.progress(FileTransferProgress(source: a, completedBytes: 100, totalBytes: 200))
    log.progress(FileTransferProgress(source: a, completedBytes: 100, totalBytes: 200))
    log.progress(FileTransferProgress(source: a, completedBytes: 200, totalBytes: 200))
    log.progress(FileTransferProgress(source: b, completedBytes: 500, totalBytes: 500, mode: .serverSide))
    let file = try log.finish(FileActionResult(succeeded: [], errors: [], changes: []), directory: root)
    let data = try Data(contentsOf: file), text = String(decoding: data, as: UTF8.self)
    let report = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    try expect(report["systemAcknowledgedBytes"] as? Int == 200 && report["serverAcknowledgedBytes"] as? Int == 500, "Diagnostics count acknowledged byte deltas without duplicate final callbacks")
    try expect(!text.contains(a.path) && !text.contains(a.lastPathComponent) && !text.contains(b.lastPathComponent), "Persistent timing reports contain no source names or paths")
    let stages = report["stages"] as! [[String: Any]]
    try expect(stages.contains { $0["stage"] as? String == "smb.protocol" && ($0["metrics"] as? [String: Double])?["requests"] == 12 }, "Protocol timings and request counts survive serialization")
    try expect(try fm.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("transfer-") }.count == 20 && fm.fileExists(atPath: unrelated.path), "Report retention is bounded and preserves unrelated cache entries")
    let source = root.appendingPathComponent("source"), target = root.appendingPathComponent("target")
    try fm.createDirectory(at: source, withIntermediateDirectories: false)
    try fm.createDirectory(at: target, withIntermediateDirectories: false)
    let input = source.appendingPathComponent("actual-copy")
    try Data(repeating: 7, count: 1_048_576).write(to: input)
    let actual = TransferDiagnostics(); var actualProgress: [FileTransferProgress] = [], actualPhases: [FileTransferPhase] = []
    let actualControl = FileTransferControl(onProgress: { actualProgress.append($0); actual.progress($0) },
      onPhase: { actualPhases.append($0) }, onTiming: { actual.record($0) })
    let result = FileActions.transfer([input], to: target, move: false, control: actualControl)
    try expect(result.errors.isEmpty && actualProgress.last?.completedBytes == 1_048_576, "Actual local copy sends confirmed bytes through the shared telemetry path")
    try expect(actualProgress.contains { ($0.bytesPerSecond ?? 0) > 0 && $0.bytesPerSecond!.isFinite }, "Actual local copy calculates a finite speed without reading the payload again")
    try expect(actualPhases.contains(.copying) && actualPhases.contains(.properties) && actualPhases.contains(.verifying), "Actual local copy distinguishes data, properties and verification")
    let actualFile = try actual.finish(result, directory: root)
    let actualReport = try JSONSerialization.jsonObject(with: Data(contentsOf: actualFile)) as! [String: Any]
    try expect((actualReport["methods"] as? [String: Int])?["systemCopy"] == 1 && actualReport["systemAcknowledgedBytes"] as? Int == 1_048_576, "Completed local operation writes its method, stages and byte counts to the bounded report")
    for changeSource in [false, true] {
      let destination = root.appendingPathComponent(changeSource ? "source-change" : "target-change")
      try fm.createDirectory(at: destination, withIntermediateDirectories: false)
      let diagnostics = TransferDiagnostics()
      var payload: URL?, mutated = false
      var hooks = TransferHooks(); hooks.forceCopyMove = true
      hooks.checkpoint = { stage, _, target in if stage == .afterCopy { payload = target } }
      hooks.control = FileTransferControl(onProblem: { _ in .skip }, onPhase: { phase in
        guard phase == .properties, let payload, !mutated else { return }
        mutated = true
        let path = changeSource ? input.path : payload.path
        precondition(setxattr(path, "local.macexplorer.fixture", "x", 1, 0, 0) == 0)
      }, onTiming: { diagnostics.record($0) })
      let failed = FileActions.transfer([input], to: destination, move: true, hooks: hooks)
      try expect(mutated && !failed.errors.isEmpty && failed.consumedMoveSources.isEmpty && fm.fileExists(atPath: input.path), "Metadata change at restore retains the source")
      let reportFile = try diagnostics.finish(failed, directory: root)
      let bytes = try Data(contentsOf: reportFile)
      let report = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
      let stage = "properties." + (changeSource ? "source_changed" : "target_changed")
      let entries = report["stages"] as! [[String: Any]]
      let detail = entries.first { $0["stage"] as? String == stage }
      try expect(detail?["failures"] as? Int == 1 && (detail?["metrics"] as? [String: Double])?["ctime"] == 1, "Restore diagnostics identify the changed side and ctime field")
      try expect((detail?["metrics"] as? [String: Double])?.filter { $0.key != "ctime" }.values.allSatisfy { $0 == 0 } == true, "Ctime-only fixture does not report changes to identity, contents or other dates")
      let serialized = String(decoding: bytes, as: UTF8.self)
      try expect(!serialized.contains(input.path) && !serialized.contains(input.lastPathComponent) && !serialized.contains(payload!.path), "Mismatch diagnostics contain field counters without file names or paths")
      try expect(try fm.contentsOfDirectory(atPath: destination.path).isEmpty, "Rejected metadata change removes only the private incomplete copy")
    }
    print("TransferTelemetryChecks: \(count) passed")
  }
}
