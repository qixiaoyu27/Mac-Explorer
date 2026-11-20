import Foundation
import Darwin

private func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
  if try !condition() { throw NSError(domain: "VCSChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
private func rejects(_ fragment: String, _ body: () throws -> Void) throws {
  do { try body() } catch {
    try check(error.localizedDescription.contains(fragment), "Unexpected error: \(error)"); return
  }
  throw NSError(domain: "VCSChecks", code: 2, userInfo: [NSLocalizedDescriptionKey: "Expected rejection: \(fragment)"])
}
private func command(_ executable: String, _ args: [String], _ directory: URL) throws -> String {
  do { return try NativeCommand.run(executable: executable, arguments: args, directory: directory, environment: ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0"], timeout: 30).text }
  catch { fputs("Command \(args): \(error.localizedDescription)\n", stderr); throw error }
}
private func git(_ root: URL, _ args: String...) throws -> String { try command("/usr/bin/git", ["-c", "commit.gpgSign=false"] + args, root) }
private func svn(_ root: URL, _ args: String...) throws -> String { try command("/opt/homebrew/bin/svn", ["--non-interactive"] + args, root) }
private func write(_ url: URL, _ value: String) throws { try Data(value.utf8).write(to: url) }
private func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
private func setupGit(_ root: URL) throws {
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  _ = try git(root, "init", "-b", "main")
  _ = try git(root, "config", "user.name", "Fixture")
  _ = try git(root, "config", "user.email", "fixture@example.invalid")
  _ = try git(root, "config", "commit.gpgSign", "false")
  _ = try git(root, "config", "core.hooksPath", "/dev/null")
}

@main
struct VCSChecks {
  static func main() {
    do { try run() } catch { fputs("FAIL: \(error.localizedDescription)\n", stderr); exit(1) }
  }
  static func run() throws {
    let fm = FileManager.default
    let temporary = fm.temporaryDirectory.appendingPathComponent("explorer-vcs-check-" + UUID().uuidString).resolvingSymlinksInPath()
    try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: temporary) }
    let root = temporary.appendingPathComponent("git"), backup = temporary.appendingPathComponent("backups")
    try setupGit(root)
    let service = NativeVersionControl(backupDirectory: backup)
    defer { service.setEnabled(false) }
    let plain = temporary.appendingPathComponent("plain"), plainChild = plain.appendingPathComponent("child")
    try fm.createDirectory(at: plainChild, withIntermediateDirectories: true)
    let plainFile = plain.appendingPathComponent("precious.txt"), marker = plain.appendingPathComponent(".git")
    try write(plainFile, "preserved")
    try check(try service.status(directory: plain) == nil, "Ordinary folders have no VCS status")
    try fm.createDirectory(at: marker, withIntermediateDirectories: false)
    try check(try service.status(directory: plain, force: true) == nil, "An empty .git directory does not produce a repository warning")
    try check(try service.status(directory: plainChild, force: true) == nil, "Children of a non-repository marker have no VCS status")
    try fm.removeItem(at: marker)
    try fm.createSymbolicLink(at: marker, withDestinationURL: temporary.appendingPathComponent("missing.git"))
    try check(try service.status(directory: plain, force: true) == nil, "A dangling .git link does not produce a repository warning")
    try fm.removeItem(at: marker)
    try write(marker, "gitdir: ../missing.git\n")
    try check(try service.status(directory: plain, force: true) == nil, "A removed worktree repository has no VCS status")
    try check(try read(plainFile) == "preserved" && read(marker) == "gitdir: ../missing.git\n", "Repository detection preserves ordinary files and marker contents")
    let corrupt = temporary.appendingPathComponent("corrupt")
    try setupGit(corrupt)
    try write(corrupt.appendingPathComponent(".git/index"), "broken index")
    let corruptStatus = try service.status(directory: corrupt, force: true)
    try check(corruptStatus?.root.path == corrupt.path && corruptStatus?.error?.isEmpty == false, "A genuine repository index error remains visible: \(String(describing: corruptStatus?.error))")
    let src = root.appendingPathComponent("src"), file = src.appendingPathComponent("文件 name.txt")
    try fm.createDirectory(at: src, withIntermediateDirectories: true)
    try write(file, "original\n"); try write(root.appendingPathComponent(".gitignore"), "ignored/\nsrc/cache/\n")
    _ = try git(root, "add", "."); _ = try git(root, "commit", "-m", "fixture")
    let parsed = try NativeVersionControl.parseGitStatus("## main...origin/main\0MM 中文\nname.txt\0R  new.txt\0old.txt\0?? -file\0!! ignored\0UU conflict\0")
    try check(parsed.branch == "main" && parsed.changes[0].staged && parsed.changes[0].unstaged, "Git porcelain columns")
    try check(parsed.changes.first(where: { $0.path == "old.txt" })?.state == .deleted, "Rename source")
    try rejects("解析") { _ = try NativeVersionControl.parseGitStatus("R  new\0") }
    try rejects("同一仓库") { _ = try NativeVersionControl.parseGitStatus("?? ../escape\0") }
    let xml = "<status><target path=\".\"><entry path=\"a&amp;&quot;&apos;&#10;中\"><wc-status item=\"normal\" props=\"modified\"/></entry><entry path=\"tree\"><wc-status item=\"normal\" tree-conflicted=\"true\"/></entry></target></status>"
    let svnParsed = try NativeVersionControl.parseSvnStatus(xml)
    try check(svnParsed.changes[0].path == "a&\"'\n中" && svnParsed.changes[1].state == .conflict, "SVN XML decoding and conflicts")
    try rejects("解析") { _ = try NativeVersionControl.parseSvnStatus("<!DOCTYPE status [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><status/>") }
    try write(file, "changed\n")
    let ignored = root.appendingPathComponent("ignored"), cache = src.appendingPathComponent("cache")
    for directory in [ignored, cache] { try fm.createDirectory(at: directory, withIntermediateDirectories: true); try write(directory.appendingPathComponent("a"), "ignored") }
    let new = root.appendingPathComponent("new\n中文.txt"); try write(new, "new")
    let status = try service.status(directory: root)
    try check(status?.error == nil && status?.branch == "main", "Git status reads branch")
    try check(status?.statesByPath[src.path] == .modified && status?.statesByPath[ignored.path] == .ignored && status?.statesByPath[new.path] == .untracked, "Folder aggregation and ignored")
    try check(try service.status(directory: ignored)?.statesByPath[ignored.appendingPathComponent("a").path] == .ignored, "Ignored descendants")
    try check(try service.status(directory: root.appendingPathComponent(".git")) == nil, "Metadata excluded")
    let alias = temporary.appendingPathComponent("alias"); try fm.createSymbolicLink(at: alias, withDestinationURL: root)
    try check(try service.status(directory: alias)?.statesByPath[alias.appendingPathComponent("src").path] == .modified, "Aliases retain display paths")
    try check(try service.diff(directory: alias, paths: [alias.appendingPathComponent("src/文件 name.txt")]).working.contains("changed"), "Alias operations canonicalize")
    let outside = temporary.appendingPathComponent("outside"); try fm.createDirectory(at: outside, withIntermediateDirectories: true); try write(outside.appendingPathComponent("precious"), "keep")
    let escape = root.appendingPathComponent("link"); try fm.createSymbolicLink(at: escape, withDestinationURL: outside)
    try rejects("同一仓库") { _ = try service.diff(directory: root, paths: [escape.appendingPathComponent("precious")]) }
    try rejects("同一仓库") { _ = try service.diff(directory: root, paths: [root.appendingPathComponent(".git/config")]) }
    let nested = root.appendingPathComponent("nested"); try setupGit(nested)
    try rejects("子仓库") { _ = try service.prepare(directory: root, action: .add, paths: [nested]) }
    try fm.removeItem(at: nested); try fm.removeItem(at: escape)
    for name in ["-option.txt", "[a].txt", "中文\n name.txt"] {
      let path = root.appendingPathComponent(name); try write(path, name)
      let plan = try service.prepare(directory: root, action: .add, paths: [path]); _ = try service.execute(id: plan.id)
    }
    try check(try service.prepare(directory: root, action: .commit, paths: [root]).changes.count == 3, "Literal pathspec names stage")
    try write(file, "staged\n"); _ = try git(root, "add", "--", file.path); try write(file, "precious unstaged\n")
    let diff = try service.diff(directory: root, paths: [file]); try check(diff.staged.contains("staged") && diff.working.contains("precious"), "Staged and working diffs")
    let commit = try service.prepare(directory: root, action: .commit, paths: [file])
    service.setEnabled(true)
    _ = try service.execute(id: commit.id, message: "commit staged only")
    try check(try git(root, "show", "HEAD:src/文件 name.txt") == "staged\n", "Commit staged snapshot")
    try check(try read(file) == "precious unstaged\n", "Commit preserves working data")
    try rejects("失效") { _ = try service.execute(id: commit.id, message: "again") }
    let revert = try service.prepare(directory: root, action: .revert, paths: [root]); let result = try service.execute(id: revert.id)
    guard let saved = result.backup else { fatalError("Missing revert backup") }
    try check(try read(saved.appendingPathComponent("files/src/文件 name.txt")) == "precious unstaged\n", "Backup exact worktree content")
    try check(try read(file) == "staged\n" && read(new) == "new", "Revert preserves staged and untracked")
    try write(file, "one"); let stale = try service.prepare(directory: root, action: .revert, paths: [file]); try write(file, "two")
    try rejects("发生变化") { _ = try service.execute(id: stale.id) }
    try check(try read(file) == "two", "Stale revert leaves files unchanged")
    _ = try git(root, "add", "--", file.path)
    let staleCommit = try service.prepare(directory: root, action: .commit, paths: [root]); try write(file, "three"); _ = try git(root, "add", "--", file.path)
    try rejects("发生变化") { _ = try service.execute(id: staleCommit.id, message: "no") }
    try rejects("本地更改") { _ = try service.prepare(directory: root, action: .update, paths: [root]) }
    // Each operation above only touched this disposable fixture tree.
    let link = root.appendingPathComponent("tracked-link"); try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "src/文件 name.txt")
    _ = try git(root, "add", "."); _ = try git(root, "commit", "-m", "clean")
    try fm.removeItem(at: link); try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "../outside/precious")
    let linkPlan = try service.prepare(directory: root, action: .revert, paths: [link]); let linkResult = try service.execute(id: linkPlan.id)
    try check(try fm.destinationOfSymbolicLink(atPath: linkResult.backup!.appendingPathComponent("files/tracked-link").path) == "../outside/precious", "Backup copies link object")
    try check(try read(outside.appendingPathComponent("precious")) == "keep", "External link target preserved")
    let remote = temporary.appendingPathComponent("remote.git"), second = temporary.appendingPathComponent("second")
    _ = try git(root, "clone", "--bare", root.path, remote.path); _ = try git(root, "remote", "add", "origin", remote.path); _ = try git(root, "fetch", "origin"); _ = try git(root, "branch", "--set-upstream-to=origin/main")
    _ = try git(root, "clone", remote.path, second.path); _ = try git(second, "config", "user.name", "Fixture"); _ = try git(second, "config", "user.email", "fixture@example.invalid"); _ = try git(second, "config", "core.hooksPath", "/dev/null")
    try write(second.appendingPathComponent("remote.txt"), "remote"); _ = try git(second, "add", "."); _ = try git(second, "commit", "-m", "remote"); _ = try git(second, "push")
    let update = try service.prepare(directory: root, action: .update, paths: [root]); _ = try service.execute(id: update.id)
    try check(try read(root.appendingPathComponent("remote.txt")) == "remote", "Fast forward")
    try write(root.appendingPathComponent("local.txt"), "local"); _ = try git(root, "add", "."); _ = try git(root, "commit", "-m", "local")
    try write(second.appendingPathComponent("other.txt"), "other"); _ = try git(second, "add", "."); _ = try git(second, "commit", "-m", "other"); _ = try git(second, "push")
    let head = try git(root, "rev-parse", "HEAD"), divergent = try service.prepare(directory: root, action: .update, paths: [root])
    do { _ = try service.execute(id: divergent.id); fatalError("Divergent pull accepted") } catch { try check(try git(root, "rev-parse", "HEAD") == head, "Divergent pull preserves HEAD") }
    let collisionRoot = temporary.appendingPathComponent("collision")
    _ = try git(root, "clone", remote.path, collisionRoot.path)
    let collisionService = NativeVersionControl(backupDirectory: temporary.appendingPathComponent("collision-backups"))
    let preciousIgnored = collisionRoot.appendingPathComponent("ignored/precious")
    try fm.createDirectory(at: preciousIgnored.deletingLastPathComponent(), withIntermediateDirectories: true); try write(preciousIgnored, "local precious")
    let remoteIgnored = second.appendingPathComponent("ignored/precious")
    try fm.createDirectory(at: remoteIgnored.deletingLastPathComponent(), withIntermediateDirectories: true); try write(remoteIgnored, "remote value")
    _ = try git(second, "add", "-f", "--", "ignored/precious"); _ = try git(second, "commit", "-m", "collision"); _ = try git(second, "push")
    let collisionPlan = try collisionService.prepare(directory: collisionRoot, action: .update, paths: [collisionRoot])
    do { _ = try collisionService.execute(id: collisionPlan.id); fatalError("Ignored collision overwritten") } catch { try check(try read(preciousIgnored) == "local precious", "Update preserves ignored collision") }
    collisionService.setEnabled(false)
    let worktree = temporary.appendingPathComponent("worktree"); _ = try git(root, "worktree", "add", "-b", "other", worktree.path)
    try check(try service.status(directory: worktree)?.branch == "other", "Git worktree marker file")
    service.setEnabled(false)
    try check(try service.status(directory: root) == nil, "Disabled status returns nil")
    try rejects("关闭") { _ = try service.prepare(directory: root, action: .add, paths: [root]) }
    service.setEnabled(true)
    let blockedRoot = temporary.appendingPathComponent("blocked")
    try setupGit(blockedRoot)
    let fifo = blockedRoot.appendingPathComponent(".git/index")
    guard fifo.path.withCString({ mkfifo($0, 0o600) }) == 0 else { fatalError("Could not create fixture FIFO") }
    let blocked = NativeVersionControl(backupDirectory: temporary.appendingPathComponent("blocked-backups"))
    let finished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async { _ = try? blocked.status(directory: blockedRoot); finished.signal() }
    try check(finished.wait(timeout: .now() + 0.2) == .timedOut, "Fixture status is actually blocked")
    blocked.setEnabled(true)
    try check(finished.wait(timeout: .now() + 0.2) == .timedOut, "Reapplying the enabled preference leaves a pending status process running")
    blocked.setEnabled(false)
    try check(finished.wait(timeout: .now() + 2) == .success, "Disable terminates a pending status process")
    try check(try blocked.status(directory: blockedRoot) == nil, "Disabled cache remains empty")
    print("PASS: Git parsing, aggregation, aliases, boundaries, staging, commit, backup, stale plans, symlinks, fast-forward, worktrees, enabled preference reapplication, disable")
    if fm.isExecutableFile(atPath: "/opt/homebrew/bin/svn"), fm.isExecutableFile(atPath: "/opt/homebrew/bin/svnadmin") {
      try checkSVN(temporary)
    } else { print("SKIP: SVN tools not installed") }
  }

  static func checkSVN(_ temporary: URL) throws {
    let fm = FileManager.default, repository = temporary.appendingPathComponent("svn-repository"), root = temporary.appendingPathComponent("svn-wc"), second = temporary.appendingPathComponent("svn-second")
    _ = try command("/opt/homebrew/bin/svnadmin", ["create", repository.path], temporary)
    _ = try svn(temporary, "checkout", repository.absoluteString, root.path)
    let service = NativeVersionControl(backupDirectory: temporary.appendingPathComponent("svn-backups")); defer { service.setEnabled(false) }
    let file = root.appendingPathComponent("中文 & name@.txt"); try write(file, "original\n")
    _ = try svn(root, "add", "--", "中文 & name@.txt@"); _ = try svn(root, "commit", "-m", "fixture")
    try check(try service.status(directory: root)?.statesByPath[file.path] == .clean, "SVN clean")
    _ = try svn(root, "propset", "custom:test", "precious property", "--", "中文 & name@.txt@")
    try check(try service.status(directory: root, force: true)?.statesByPath[file.path] == .modified, "SVN property modification")
    try check(try service.diff(directory: root, paths: [file]).working.contains("precious property"), "SVN property diff")
    let stale = try service.prepare(directory: root, action: .commit, paths: [file]); _ = try svn(root, "propset", "custom:test", "changed property", "--", "中文 & name@.txt@")
    try rejects("发生变化") { _ = try service.execute(id: stale.id, message: "stale") }
    let revert = try service.prepare(directory: root, action: .revert, paths: [file]); let saved = try service.execute(id: revert.id)
    try check(try read(saved.backup!.appendingPathComponent("properties.xml")).contains("changed property"), "SVN property backup")
    let added = root.appendingPathComponent("-new@.txt"); try write(added, "added")
    let add = try service.prepare(directory: root, action: .add, paths: [added]); _ = try service.execute(id: add.id)
    let commit = try service.prepare(directory: root, action: .commit, paths: [added]); _ = try service.execute(id: commit.id, message: "new file")
    try check(try service.status(directory: root, force: true)?.statesByPath[added.path] == .clean, "SVN @ and option names")
    let directory = root.appendingPathComponent("new folder"); try fm.createDirectory(at: directory, withIntermediateDirectories: true); try write(directory.appendingPathComponent("a"), "new")
    let directoryAdd = try service.prepare(directory: root, action: .add, paths: [directory]); _ = try service.execute(id: directoryAdd.id)
    let directoryCommit = try service.prepare(directory: root, action: .commit, paths: [directory]); try check(directoryCommit.changes.count == 2, "SVN full directory manifest"); _ = try service.execute(id: directoryCommit.id, message: "directory")
    try write(directory.appendingPathComponent("a"), "precious content"); try write(directory.appendingPathComponent("unversioned"), "preserve")
    let directoryRevert = try service.prepare(directory: root, action: .revert, paths: [directory]); _ = try service.execute(id: directoryRevert.id)
    try check(try read(directory.appendingPathComponent("unversioned")) == "preserve", "SVN revert preserves unversioned")
    try fm.removeItem(at: directory.appendingPathComponent("unversioned"))
    let nested = root.appendingPathComponent("new/nested"); try setupGit(nested)
    try rejects("子仓库") { _ = try service.prepare(directory: root, action: .add, paths: [root.appendingPathComponent("new")]) }
    try fm.removeItem(at: root.appendingPathComponent("new"))
    _ = try svn(temporary, "checkout", repository.absoluteString, second.path)
    try write(second.appendingPathComponent("remote.txt"), "remote"); _ = try svn(second, "add", "remote.txt"); _ = try svn(second, "commit", "-m", "remote")
    let update = try service.prepare(directory: root, action: .update, paths: [root]); _ = try service.execute(id: update.id)
    try check(try read(root.appendingPathComponent("remote.txt")) == "remote", "SVN update")
    try write(second.appendingPathComponent("中文 & name@.txt"), "remote\n"); _ = try svn(second, "commit", "-m", "remote change")
    try write(file, "precious local\n"); _ = try svn(root, "update", "--accept", "postpone")
    try check(try service.status(directory: root, force: true)?.statesByPath[file.path] == .conflict, "SVN conflict")
    let conflict = try service.prepare(directory: root, action: .revert, paths: [file]); let conflictResult = try service.execute(id: conflict.id)
    try check(try read(conflictResult.backup!.appendingPathComponent("files/中文 & name@.txt.mine")) == "precious local\n", "SVN conflict mine backup")
    try check(try read(file) == "remote\n", "SVN conflict restored")
    print("PASS: SVN status, properties, stale commit, add/commit, @ names, directory preservation, nested repository refusal, update, conflict sidecar backup")
  }
}
