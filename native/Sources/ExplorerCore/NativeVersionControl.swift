import Foundation
import CryptoKit
import Darwin

public enum NativeVCSKind: String, Sendable { case git, svn }
public enum NativeVCSAction: String, Sendable {
  case add, commit, update, revert, diff
  public var title: String {
    switch self {
    case .add: return NL("加入版本控制")
    case .commit: return NL("提交更改")
    case .update: return NL("更新仓库")
    case .revert: return NL("丢弃本地修改")
    case .diff: return NL("查看差异")
    }
  }
}
public enum NativeVCSState: String, Sendable {
  case ignored, clean, untracked, deleted, added, modified, conflict
  public var mark: String {
    switch self { case .clean: return "✓"; case .modified: return "M"; case .added: return "+"; case .deleted: return "D"; case .untracked: return "?"; case .conflict: return "!"; case .ignored: return "−" }
  }
  public var title: String {
    switch self { case .clean: return NL("无本地修改"); case .modified: return NL("已修改"); case .added: return NL("已添加"); case .deleted: return NL("已删除"); case .untracked: return NL("未跟踪"); case .conflict: return NL("存在冲突"); case .ignored: return NL("已忽略") }
  }
  fileprivate var rank: Int {
    switch self { case .ignored: return 0; case .clean: return 1; case .untracked: return 2; case .deleted: return 3; case .added: return 4; case .modified: return 5; case .conflict: return 6 }
  }
}
public struct NativeVCSChange: Sendable {
  public let path: String
  public let state: NativeVCSState
  public let staged: Bool
  public let unstaged: Bool
}
public struct NativeVCSStatus: Equatable, Sendable {
  public let root: URL
  public let kind: NativeVCSKind
  public let branch: String
  public let statesByPath: [String: NativeVCSState]
  public let error: String?
}
public struct NativeVCSPlan: Sendable {
  public let id: UUID
  public let root: URL
  public let kind: NativeVCSKind
  public let action: NativeVCSAction
  public let changes: [NativeVCSChange]
}
public struct NativeVCSDiff: Sendable { public let kind: NativeVCSKind; public let working: String; public let staged: String }
public struct NativeVCSResult: Sendable { public let output: String; public let backup: URL? }
private struct VCSError: LocalizedError { let message: String; var errorDescription: String? { message } }
private func vcsFailure(_ message: String) -> VCSError { VCSError(message: message) }
private func vcsInside(_ root: String, _ path: String) -> Bool { path == root || path.hasPrefix(root == "/" ? "/" : root + "/") }
private func vcsDigest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
private struct VCSRepository { let root: URL; let kind: NativeVCSKind }
private struct VCSSnapshot { let repository: VCSRepository; let branch: String; let changes: [NativeVCSChange]; let tracked: [String]; let signature: String }

/// Synchronous operations belong on a background queue. Disabling also interrupts active read processes.
public final class NativeVersionControl: @unchecked Sendable {
  private let lock = NSCondition()
  private var enabled = true
  private var generation = 0
  private var reads: [UUID: Process] = [:]
  private var cache: [String: (Date, VCSSnapshot)] = [:]
  private var scanning: Set<String> = []
  private var busy: Set<String> = []
  private var plans: [UUID: (NativeVCSPlan, String, Date)] = [:]
  private let backupDirectory: URL
  public init(backupDirectory: URL) { self.backupDirectory = backupDirectory }
  public func setEnabled(_ value: Bool) {
    lock.lock()
    guard enabled != value else { lock.unlock(); return }
    enabled = value; generation += 1; cache.removeAll(); plans.removeAll()
    let processes = Array(reads.values); reads.removeAll(); lock.broadcast(); lock.unlock()
    for process in processes where process.isRunning { process.terminate() }
  }
  public var isEnabled: Bool { lock.lock(); defer { lock.unlock() }; return enabled }
  private func requireEnabled() throws { if !isEnabled { throw vcsFailure(NL("版本控制集成已关闭。")) } }
  private func tool(_ kind: NativeVCSKind) throws -> String {
    let paths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
    for directory in paths {
      let path = URL(fileURLWithPath: directory).appendingPathComponent(kind.rawValue).path
      if FileManager.default.isExecutableFile(atPath: path) { return path }
    }
    throw vcsFailure(NL("未找到 {0} 命令行工具，请先安装后刷新。", kind == .git ? "Git" : "SVN"))
  }
  private func command(_ repo: VCSRepository, _ arguments: [String], writing: Bool = false) throws -> String {
    try requireEnabled()
    let executable = try tool(repo.kind)
    let id = UUID()
    lock.lock(); let startedGeneration = generation; lock.unlock()
    // env removes inherited Git overrides before setting a bounded, noninteractive environment.
    let removed = ProcessInfo.processInfo.environment.keys.filter { $0.hasPrefix("GIT_") }.sorted().flatMap { ["-u", $0] }
    let arguments = repo.kind == .git ? ["-c", "core.fsmonitor=false"] + arguments : ["--non-interactive"] + arguments
    defer { lock.lock(); reads.removeValue(forKey: id); lock.unlock() }
    let environment = ["LC_ALL=en_US.UTF-8", "GIT_TERMINAL_PROMPT=0", "GIT_LITERAL_PATHSPECS=1", "GIT_PAGER=cat", "GIT_OPTIONAL_LOCKS=0", "GCM_INTERACTIVE=never", "GIT_SSH_COMMAND=/usr/bin/ssh -oBatchMode=yes -oConnectTimeout=10"]
    let result = try NativeCommand.run(executable: "/usr/bin/env", arguments: removed + environment + [executable] + arguments, directory: repo.root, timeout: writing ? 120 : 8, limit: 4 * 1024 * 1024, onStart: { process in
      self.lock.lock()
      let cancel = !self.enabled || self.generation != startedGeneration
      if !writing && !cancel { self.reads[id] = process }
      self.lock.unlock()
      if cancel && process.isRunning { process.terminate() }
    })
    try requireEnabled()
    lock.lock(); let changed = generation != startedGeneration; lock.unlock()
    if changed { throw vcsFailure(NL("版本控制状态已失效，请重试。")) }
    return result.text
  }
  private func localURL(_ input: URL) throws -> URL {
    guard input.isFileURL, input.path.hasPrefix("/"), !input.path.contains("\0"), input.query == nil, input.fragment == nil, input.host == nil || input.host == "" || input.host == "localhost" else { throw vcsFailure(NL("需要有效的仓库文件夹。")) }
    return input.standardizedFileURL
  }
  private func info(_ url: URL) throws -> stat? {
    var result = stat()
    if url.path.withCString({ lstat($0, &result) }) == 0 { return result }
    if errno == ENOENT || errno == ENOTDIR { return nil }
    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSFilePathErrorKey: url.path])
  }
  private func repository(_ input: URL) throws -> VCSRepository? {
    try requireEnabled()
    var directory = try localURL(input).resolvingSymlinksInPath()
    if directory.pathComponents.contains(".git") || directory.pathComponents.contains(".svn") { return nil }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw vcsFailure(NL("需要有效的仓库文件夹。")) }
    while true {
      for kind in [NativeVCSKind.git, .svn] {
        if try info(directory.appendingPathComponent(kind == .git ? ".git" : ".svn")) != nil { return VCSRepository(root: directory, kind: kind) }
      }
      if directory.path == "/" { return nil }
      directory.deleteLastPathComponent()
    }
  }
  public static func parseGitStatus(_ output: String) throws -> (branch: String, changes: [NativeVCSChange]) {
    let fields = output.components(separatedBy: "\0")
    var branch = "", changes: [NativeVCSChange] = [], index = 0
    while index < fields.count {
      let field = fields[index]; index += 1
      if field.isEmpty { continue }
      if field.hasPrefix("## ") {
        branch = String(field.dropFirst(3))
        for prefix in ["No commits yet on ", "Initial commit on "] where branch.hasPrefix(prefix) { branch = String(branch.dropFirst(prefix.count)) }
        branch = branch.components(separatedBy: "...")[0]; continue
      }
      let bytes = Array(field.utf8)
      guard bytes.count >= 4, bytes[2] == 32 else { throw vcsFailure(NL("无法解析版本控制状态。")) }
      let xy = String(decoding: bytes.prefix(2), as: UTF8.self)
      var file = String(decoding: bytes.dropFirst(3), as: UTF8.self)
      if file.hasSuffix("/") { file.removeLast() }
      try validateRelative(file)
      let state: NativeVCSState = ["DD", "AU", "UD", "UA", "DU", "AA", "UU"].contains(xy) ? .conflict : xy == "??" ? .untracked : xy == "!!" ? .ignored : xy.contains("D") ? .deleted : xy.contains("A") ? .added : .modified
      changes.append(NativeVCSChange(path: file, state: state, staged: bytes[0] != 32 && bytes[0] != 63 && bytes[0] != 33, unstaged: bytes[1] != 32 && xy != "!!"))
      if xy.contains("R") || xy.contains("C") {
        guard index < fields.count, !fields[index].isEmpty else { throw vcsFailure(NL("无法解析版本控制状态。")) }
        let old = fields[index]; index += 1; try validateRelative(old)
        if xy.contains("R") { changes.append(NativeVCSChange(path: old, state: .deleted, staged: bytes[0] == 82, unstaged: bytes[1] == 82)) }
      }
    }
    return (branch, changes)
  }
  public static func parseSvnStatus(_ xml: String) throws -> (changes: [NativeVCSChange], tracked: [String]) {
    let document = try vcsXML(xml)
    guard document.rootElement()?.name == "status" else { throw vcsFailure(NL("无法解析版本控制状态。")) }
    var changes: [NativeVCSChange] = [], tracked: [String] = []
    for node in try document.nodes(forXPath: "/status/target/entry") {
      guard let entry = node as? XMLElement, let name = entry.attribute(forName: "path")?.stringValue, let status = entry.elements(forName: "wc-status").first, let item = status.attribute(forName: "item")?.stringValue else { throw vcsFailure(NL("无法解析版本控制状态。")) }
      try validateRelative(name)
      let props = status.attribute(forName: "props")?.stringValue ?? ""
      guard ["normal", "none", "conflicted", "unversioned", "ignored", "external", "added", "deleted", "missing", "modified", "replaced", "obstructed", "incomplete"].contains(item) else { throw vcsFailure(NL("无法解析版本控制状态。")) }
      if item == "external" { continue }
      let state: NativeVCSState = item == "conflicted" || props == "conflicted" || status.attribute(forName: "tree-conflicted")?.stringValue == "true" ? .conflict : ["unversioned", "none"].contains(item) ? .untracked : item == "ignored" ? .ignored : item == "added" ? .added : ["deleted", "missing"].contains(item) ? .deleted : ["modified", "replaced", "obstructed", "incomplete"].contains(item) || props == "modified" ? .modified : .clean
      if state != .untracked && state != .ignored { tracked.append(name) }
      if state != .clean { changes.append(NativeVCSChange(path: name, state: state, staged: false, unstaged: true)) }
    }
    return (changes, tracked)
  }
  private static func validateRelative(_ value: String) throws {
    guard !value.isEmpty, !value.hasPrefix("/"), !value.contains("\0"), !value.split(separator: "/").contains("..") else { throw vcsFailure(NL("文件必须位于同一仓库内。")) }
  }
  private func snapshot(_ repo: VCSRepository, force: Bool = false) throws -> VCSSnapshot {
    let key = repo.root.path
    lock.lock()
    while scanning.contains(key) && enabled { lock.wait() }
    guard enabled else { lock.unlock(); throw vcsFailure(NL("版本控制集成已关闭。")) }
    if !force, let cached = cache[key], cached.0 > Date() { lock.unlock(); return cached.1 }
    scanning.insert(key); let startedGeneration = generation; lock.unlock()
    defer { lock.lock(); scanning.remove(key); lock.broadcast(); lock.unlock() }
    let result: VCSSnapshot
    if repo.kind == .git {
      let raw = try command(repo, ["status", "--porcelain=v1", "-z", "--branch", "--untracked-files=all", "--ignored=matching", "--ignore-submodules=none"])
      let parsed = try Self.parseGitStatus(raw)
      let tracked = try command(repo, ["ls-files", "--cached", "-z"]).components(separatedBy: "\0").filter { !$0.isEmpty }
      for path in tracked { try Self.validateRelative(path) }
      result = VCSSnapshot(repository: repo, branch: parsed.branch, changes: parsed.changes, tracked: tracked, signature: vcsDigest(Data(raw.utf8)))
    } else {
      let raw = try command(repo, ["status", "--xml", "--verbose", "--no-ignore", "--ignore-externals", "."])
      let parsed = try Self.parseSvnStatus(raw)
      result = VCSSnapshot(repository: repo, branch: "", changes: parsed.changes, tracked: parsed.tracked, signature: try canonicalDigest(raw))
    }
    guard result.changes.count <= 5000, result.tracked.count <= 100_000 else { throw vcsFailure(NL("版本控制查询超时或结果过大，请在终端处理此仓库。")) }
    lock.lock()
    if enabled && generation == startedGeneration {
      if cache.count >= 4 { cache.removeValue(forKey: cache.min(by: { $0.value.0 < $1.value.0 })!.key) }
      cache[key] = (Date().addingTimeInterval(2), result)
    }
    lock.unlock()
    return result
  }
  public func status(directory input: URL, force: Bool = false) throws -> NativeVCSStatus? {
    if !isEnabled { return nil }
    let requested = try localURL(input), directory = requested.resolvingSymlinksInPath()
    guard let repo = try repository(directory) else { return nil }
    do {
      let snapshot = try snapshot(repo, force: force)
      var states: [String: NativeVCSState] = [:]
      func apply(_ file: String, _ state: NativeVCSState) {
        let full = repo.root.appendingPathComponent(file).path
        guard vcsInside(directory.path, full), full != directory.path else { return }
        let child = String(full.dropFirst(directory.path.count + 1)).components(separatedBy: "/")[0]
        let visible = requested.appendingPathComponent(child).path
        if states[visible] == nil || states[visible]!.rank < state.rank { states[visible] = state }
      }
      snapshot.tracked.forEach { apply($0, .clean) }
      snapshot.changes.forEach { apply($0.path, $0.state) }
      if snapshot.changes.contains(where: { $0.state == .ignored && vcsInside(repo.root.appendingPathComponent($0.path).path, directory.path) }) {
        for name in try FileManager.default.contentsOfDirectory(atPath: directory.path) where name != ".git" && name != ".svn" {
          let path = requested.appendingPathComponent(name).path
          if states[path] == nil { states[path] = .ignored }
        }
      }
      return NativeVCSStatus(root: repo.root, kind: repo.kind, branch: snapshot.branch, statesByPath: states, error: nil)
    } catch {
      if !isEnabled { return nil }
      if repo.kind == .git, let failure = error as? NativeCommandError,
        failure.result.status == 128, failure.result.errorText.hasPrefix("fatal: not a git repository") { return nil }
      return NativeVCSStatus(root: repo.root, kind: repo.kind, branch: "", statesByPath: [:], error: error.localizedDescription)
    }
  }
  private func targets(_ repo: VCSRepository, _ inputs: [URL]) throws -> [String] {
    guard !inputs.isEmpty, inputs.count <= 5000 else { throw vcsFailure(NL("无效的版本控制文件选择。")) }
    var result: [String] = []
    for input in inputs {
      let requested = try localURL(input)
      var parent = requested.deletingLastPathComponent()
      while try info(parent) == nil, parent.path != "/" { parent.deleteLastPathComponent() }
      let real = parent.resolvingSymlinksInPath()
      var file = real.appendingPathComponent(String(requested.path.dropFirst(parent.path == "/" ? 1 : parent.path.count + 1))).standardizedFileURL
      if !vcsInside(repo.root.path, file.path), requested.resolvingSymlinksInPath().path == repo.root.path { file = repo.root }
      guard vcsInside(repo.root.path, file.path) else { throw vcsFailure(NL("文件必须位于同一仓库内。")) }
      let relative = file.path == repo.root.path ? "." : String(file.path.dropFirst(repo.root.path.count + 1))
      guard !relative.split(separator: "/").contains(where: { $0 == ".git" || $0 == ".svn" }) else { throw vcsFailure(NL("文件必须位于同一仓库内。")) }
      if file.path != repo.root.path {
        guard vcsInside(repo.root.path, real.path), let owner = try repository(real), owner.root.path == repo.root.path, owner.kind == repo.kind else { throw vcsFailure(NL("文件必须位于同一仓库内。")) }
        if let stat = try info(file), stat.st_mode & S_IFMT == S_IFDIR, let child = try repository(file), child.root.path != repo.root.path { throw vcsFailure(NL("请进入子仓库后操作。")) }
      }
      if !result.contains(relative) { result.append(relative) }
    }
    return result
  }
  private func selected(_ change: NativeVCSChange, _ files: [String]) -> Bool { files.contains { $0 == "." || change.path == $0 || change.path.hasPrefix($0 + "/") } }
  private func svnPaths(_ paths: [String]) -> [String] { paths.map { $0 + "@" } }
  public func diff(directory: URL, paths: [URL]) throws -> NativeVCSDiff {
    guard let repo = try repository(directory) else { throw vcsFailure(NL("此位置不属于版本控制仓库。")) }
    let files = try targets(repo, paths)
    if repo.kind == .svn { return NativeVCSDiff(kind: .svn, working: try command(repo, ["diff", "--internal-diff", "--"] + files), staged: "") }
    return NativeVCSDiff(kind: .git, working: try command(repo, ["diff", "--no-ext-diff", "--no-textconv", "--"] + files), staged: try command(repo, ["diff", "--cached", "--no-ext-diff", "--no-textconv", "--"] + files))
  }
  private func conflictFiles(_ repo: VCSRepository, _ changes: [NativeVCSChange]) throws -> [String] {
    let conflicts = changes.filter { $0.state == .conflict }
    if repo.kind != .svn || conflicts.isEmpty { return [] }
    let document = try vcsXML(command(repo, ["info", "--xml", "--"] + svnPaths(conflicts.map(\.path))))
    var files: [String] = []
    for tag in ["prev-base-file", "prev-wc-file", "cur-base-file", "prop-file"] {
      for node in try document.nodes(forXPath: "//" + tag) {
        guard let path = node.stringValue, path.hasPrefix("/") else { throw vcsFailure(NL("文件必须位于同一仓库内。")) }
        files += try targets(repo, [URL(fileURLWithPath: path)])
      }
    }
    return Array(Set(files)).sorted()
  }
  private func checkAddedDirectory(_ repo: VCSRepository, _ file: String) throws {
    var pending = [repo.root.appendingPathComponent(file)], count = 0
    while let directory = pending.popLast() {
      guard let stat = try info(directory), stat.st_mode & S_IFMT == S_IFDIR else { continue }
      for child in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
        if child.lastPathComponent == ".git" || child.lastPathComponent == ".svn" { throw vcsFailure(NL("请进入子仓库后操作。")) }
        count += 1
        if count > 5000 { throw vcsFailure(NL("版本控制查询超时或结果过大，请在终端处理此仓库。")) }
        if let stat = try info(child), stat.st_mode & S_IFMT == S_IFDIR { pending.append(child) }
      }
    }
  }
  private func canonicalDigest(_ xml: String) throws -> String { vcsDigest(Data(try vcsXML(xml).canonicalXMLStringPreservingComments(false).utf8)) }
  private func signature(_ repo: VCSRepository, _ changes: [NativeVCSChange], _ action: NativeVCSAction, _ snapshot: VCSSnapshot) throws -> String {
    var hash = SHA256()
    func append(_ value: String) { hash.update(data: Data(value.utf8)); hash.update(data: Data([0])) }
    append(snapshot.signature)
    if repo.kind == .git {
      append(try command(repo, ["ls-files", "--stage", "-z"]))
      append((try? command(repo, ["rev-parse", "--verify", "--quiet", "HEAD"])) ?? "unborn")
    }
    if repo.kind == .svn && (action == .commit || action == .revert) {
      append(try canonicalDigest(command(repo, ["proplist", "--xml", "--verbose", "--"] + svnPaths(changes.map(\.path)))))
    }
    if action == .add || action == .revert || repo.kind == .svn && action == .commit {
      let paths = changes.map(\.path) + (action == .revert ? try conflictFiles(repo, changes) : [])
      for relative in paths {
        try requireEnabled()
        let file = repo.root.appendingPathComponent(relative)
        _ = try targets(repo, [file])
        let stat = try info(file)
        append(relative); append(String(stat?.st_mode ?? 0))
        if let stat, stat.st_mode & S_IFMT == S_IFLNK { append(try FileManager.default.destinationOfSymbolicLink(atPath: file.path)) }
        else if let stat, stat.st_mode & S_IFMT == S_IFREG {
          let descriptor = file.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW) }
          guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
          let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
          defer { try? handle.close() }
          var content = SHA256()
          while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { try requireEnabled(); content.update(data: data) }
          hash.update(data: Data(content.finalize()))
        } else { append(stat == nil ? "missing" : "directory") }
      }
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
  }
  public func prepare(directory: URL, action: NativeVCSAction, paths: [URL]) throws -> NativeVCSPlan {
    guard action != .diff else { throw vcsFailure(NL("无效的版本控制操作。")) }
    guard let repo = try repository(directory) else { throw vcsFailure(NL("此位置不属于版本控制仓库。")) }
    let files = try targets(repo, paths), snapshot = try snapshot(repo, force: true)
    var changes = snapshot.changes.filter { selected($0, files) }
    if action == .commit && repo.kind == .git { changes = snapshot.changes.filter(\.staged) }
    if action == .revert { changes = changes.filter { $0.unstaged && $0.state != .untracked && $0.state != .ignored } }
    if action == .add { changes = changes.filter { $0.state != .ignored && (repo.kind == .git ? $0.unstaged : $0.state == .untracked) } }
    if action == .commit && repo.kind == .svn { changes = changes.filter { $0.state != .untracked && $0.state != .ignored } }
    if action != .update && changes.isEmpty { throw vcsFailure(NL("没有可执行此操作的更改。")) }
    if action != .revert && snapshot.changes.contains(where: { $0.state == .conflict }) { throw vcsFailure(NL("仓库存在冲突，请先在终端或版本控制工具中解决。")) }
    if action == .update {
      guard !snapshot.changes.contains(where: { $0.state != .ignored }) else { throw vcsFailure(NL("请先提交或保存本地更改，再更新仓库。")) }
      changes = []
    }
    for change in changes { _ = try targets(repo, [repo.root.appendingPathComponent(change.path)]) }
    if repo.kind == .svn && action == .add { for change in changes { try checkAddedDirectory(repo, change.path) } }
    let plan = NativeVCSPlan(id: UUID(), root: repo.root, kind: repo.kind, action: action, changes: changes)
    let signature = try signature(repo, changes, action, snapshot)
    lock.lock(); defer { lock.unlock() }
    plans = plans.filter { $0.value.2 > Date() }
    if plans.count >= 20 { plans.removeValue(forKey: plans.min(by: { $0.value.2 < $1.value.2 })!.key) }
    guard enabled else { throw vcsFailure(NL("版本控制集成已关闭。")) }
    plans[plan.id] = (plan, signature, Date().addingTimeInterval(300))
    return plan
  }
  private func backup(_ plan: NativeVCSPlan) throws -> URL {
    let repo = VCSRepository(root: plan.root, kind: plan.kind)
    let base = try localURL(backupDirectory)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let directory = base.appendingPathComponent(plan.id.uuidString, isDirectory: true)
    guard directory.path.withCString({ Darwin.mkdir($0, 0o700) }) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    let paths = Array(Set(plan.changes.map(\.path) + (try conflictFiles(repo, plan.changes)))).sorted()
    var files: [[String: Any]] = []
    for path in paths {
      let source = plan.root.appendingPathComponent(path)
      _ = try targets(repo, [source]); let stat = try info(source)
      files.append(["path": path, "exists": stat != nil])
      guard let stat else { continue }
      let destination = directory.appendingPathComponent("files").appendingPathComponent(path)
      if stat.st_mode & S_IFMT == S_IFDIR {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
      } else {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // copyItem rejects collisions and copies symlink objects without following them.
        try FileManager.default.copyItem(at: source, to: destination)
      }
    }
    if plan.kind == .svn {
      let properties = try command(repo, ["proplist", "--xml", "--verbose", "--"] + svnPaths(plan.changes.map(\.path)))
      let patch = try command(repo, ["diff", "--internal-diff", "--"] + plan.changes.map(\.path))
      try Data(properties.utf8).write(to: directory.appendingPathComponent("properties.xml"), options: .withoutOverwriting)
      try Data(patch.utf8).write(to: directory.appendingPathComponent("changes.patch"), options: .withoutOverwriting)
    }
    let manifest: [String: Any] = ["root": plan.root.path, "kind": plan.kind.rawValue, "created": ISO8601DateFormatter().string(from: Date()), "files": files]
    try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("manifest.json"), options: .withoutOverwriting)
    return directory
  }
  public func execute(id: UUID, message: String = "") throws -> NativeVCSResult {
    try requireEnabled()
    lock.lock()
    guard let saved = plans[id], saved.2 > Date() else { lock.unlock(); throw vcsFailure(NL("操作预览已失效，请重新打开。")) }
    let plan = saved.0
    guard message.count <= 10_000, !message.contains("\0"), plan.action != .commit || !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { lock.unlock(); throw vcsFailure(NL("请填写有效的提交信息。")) }
    guard !busy.contains(plan.root.path) else { lock.unlock(); throw vcsFailure(NL("此仓库正在执行其他操作，请稍后重试。")) }
    plans.removeValue(forKey: id); busy.insert(plan.root.path); lock.unlock()
    defer { lock.lock(); busy.remove(plan.root.path); cache.removeValue(forKey: plan.root.path); lock.unlock() }
    var backup: URL?
    do {
      guard let repo = try repository(plan.root), repo.root.path == plan.root.path, repo.kind == plan.kind else { throw vcsFailure(NL("操作预览已失效，请重新打开。")) }
      for change in plan.changes { _ = try targets(repo, [plan.root.appendingPathComponent(change.path)]) }
      guard try signature(repo, plan.changes, plan.action, snapshot(repo, force: true)) == saved.1 else { throw vcsFailure(NL("仓库已发生变化，请重新预览后再操作。")) }
      let files = plan.changes.map(\.path)
      if plan.kind == .svn && plan.action == .add { for file in files { try checkAddedDirectory(repo, file) } }
      if plan.action == .revert {
        backup = try self.backup(plan)
        guard try signature(repo, plan.changes, plan.action, snapshot(repo, force: true)) == saved.1 else { throw vcsFailure(NL("仓库已发生变化，请重新预览后再操作。")) }
      }
      if plan.kind == .git && plan.action == .update {
        // pull has no --no-overwrite-ignore; split fetch/merge so ignored collisions are refused.
        let upstream = try command(repo, ["rev-parse", "--symbolic-full-name", "@{upstream}"]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard upstream.hasPrefix("refs/"), !upstream.contains("\n") else { throw vcsFailure(NL("没有可更新的上游分支。")) }
        let head = try command(repo, ["rev-parse", "HEAD"]), branch = try command(repo, ["symbolic-ref", "HEAD"]), index = try command(repo, ["ls-files", "--stage", "-z"])
        let fetched = try command(repo, ["fetch", "--no-recurse-submodules"], writing: true)
        let refreshed = try snapshot(repo, force: true)
        guard !refreshed.changes.contains(where: { $0.state != .ignored }), try command(repo, ["rev-parse", "HEAD"]) == head, try command(repo, ["symbolic-ref", "HEAD"]) == branch, try command(repo, ["ls-files", "--stage", "-z"]) == index else { throw vcsFailure(NL("仓库已发生变化，请重新预览后再操作。")) }
        return NativeVCSResult(output: fetched + (try command(repo, ["merge", "--ff-only", "--no-autostash", "--no-overwrite-ignore", "--", upstream], writing: true)), backup: nil)
      }
      let arguments: [String]
      if plan.kind == .git {
        switch plan.action {
        case .commit: arguments = ["commit", "-m", message]
        case .update: arguments = ["pull", "--ff-only", "--no-rebase"]
        case .add: arguments = ["add", "--"] + files
        case .revert: arguments = ["restore", "--worktree", "--"] + files
        case .diff: throw vcsFailure(NL("无效的版本控制操作。"))
        }
      } else {
        switch plan.action {
        case .commit: arguments = ["commit", "-m", message, "--"] + svnPaths(files)
        case .update: arguments = ["update", "--accept", "postpone", "--ignore-externals", "--", ".@"]
        case .add: arguments = ["add", "--parents", "--"] + svnPaths(files)
        case .revert: arguments = ["revert", "--depth", "empty", "--"] + svnPaths(files.sorted { $0.split(separator: "/").count > $1.split(separator: "/").count })
        case .diff: throw vcsFailure(NL("无效的版本控制操作。"))
        }
      }
      return NativeVCSResult(output: try command(repo, arguments, writing: true), backup: backup)
    } catch {
      throw vcsFailure(error.localizedDescription + (backup.map { "\n" + NL("修改前的文件备份保存在：{0}", $0.path) } ?? ""))
    }
  }
}

private func vcsXML(_ xml: String) throws -> XMLDocument {
  // Repository output is untrusted: neither DTDs nor entity expansion belong in status data.
  guard !xml.contains("<!DOCTYPE"), !xml.contains("<!ENTITY") else { throw vcsFailure(NL("无法解析版本控制状态。")) }
  return try XMLDocument(xmlString: xml, options: [.nodeLoadExternalEntitiesNever])
}
