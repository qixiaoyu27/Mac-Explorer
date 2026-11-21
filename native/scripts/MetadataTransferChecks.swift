import Foundation
import Darwin

private struct MetadataCheckFailure: LocalizedError {
  let errorDescription: String?
  init(_ description: String) { errorDescription = description }
}

@main
struct MetadataTransferChecks {
  static let fm = FileManager.default
  static func main() {
    do { try run() } catch { fputs("MetadataTransferChecks FAILED: \(error.localizedDescription)\n", stderr); exit(1) }
  }
  static func run() throws {
    NativeLanguage.mode = "zh-CN"
    let root = fm.temporaryDirectory.appendingPathComponent("MetadataTransferChecks-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: root) }
    var count = 0
    func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
      guard try condition() else { throw MetadataCheckFailure("Assertion \(count + 1): \(message)") }; count += 1
    }
    func exists(_ url: URL) -> Bool { var value = stat(); return lstat(url.path, &value) == 0 }
    func dates(_ url: URL) throws -> [Int] {
      var s = stat(); guard lstat(url.path, &s) == 0 else { throw VerifiedTransfer.posix() }
      return [s.st_birthtimespec.tv_sec,s.st_birthtimespec.tv_nsec,s.st_mtimespec.tv_sec,s.st_mtimespec.tv_nsec]
    }
    func fixture(_ name: String) throws -> (URL,URL,URL) {
      let folder=root.appendingPathComponent(name), source=root.appendingPathComponent(name+"/source"), target=root.appendingPathComponent(name+"/target")
      try fm.createDirectory(at:source,withIntermediateDirectories:true); try fm.createDirectory(at:target,withIntermediateDirectories:false)
      let file=source.appendingPathComponent("中文 small.txt");try Data("OK".utf8).write(to:file)
      try fm.setAttributes([.creationDate:Date(timeIntervalSince1970:1_600_000_000),.modificationDate:Date(timeIntervalSince1970:1_600_000_100)],ofItemAtPath:file.path)
      _=folder;return(file,target,target.appendingPathComponent(file.lastPathComponent))
    }
    func transfer(_ file:URL,_ target:URL, move:Bool=true, hooks:TransferHooks=TransferHooks()) -> FileActionResult {
      var value=hooks;value.forceCopyMove=true;return FileActions.transfer([file],to:target,move:move,hooks:value)
    }
    func clean(_ target:URL) throws -> Bool { try !fm.contentsOfDirectory(atPath:target.path).contains { $0.hasPrefix(".mac-explorer-") } }
    do {
      var raw = stat()
      raw.st_dev = 1; raw.st_ino = 42; raw.st_mode = S_IFLNK | 0o700; raw.st_size = 14
      let linkText = TransferStamp(raw, precision: 100)
      raw.st_size = 1067
      try check(linkText.unchanged(TransferStamp(raw, precision: 100)), "SMB symlink reparse-record length is not treated as changed link content")
      raw.st_mode = S_IFREG | 0o600; raw.st_size = 14
      let regular = TransferStamp(raw, precision: 100)
      raw.st_size = 1067
      try check(!regular.unchanged(TransferStamp(raw, precision: 100)), "regular-file length remains part of the unchanged-object guard")
      raw.st_mode = S_IFLNK | 0o700; raw.st_size = 14; raw.st_ino = 43
      try check(!linkText.unchanged(TransferStamp(raw, precision: 100)), "symlink replacement still fails identity validation")
      raw.st_ino = 42; raw.st_mtimespec.tv_sec = 1
      try check(!linkText.unchanged(TransferStamp(raw, precision: 100)), "symlink metadata changes still fail validation")
    }
    for descriptor in [false, true] {
      let (file, target, _) = try fixture("retargeted-link-\(descriptor)")
      let link = file.deletingLastPathComponent().appendingPathComponent("link")
      try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "missing-before")
      var hooks = TransferHooks(); hooks.descriptorCopy = descriptor
      hooks.checkpoint = { stage, _, payload in
        if stage == .afterCopy {
          try fm.removeItem(at: payload)
          try fm.createSymbolicLink(atPath: payload.path, withDestinationPath: "missing-after")
        }
      }
      let result = transfer(link, target, hooks: hooks)
      try check(!result.errors.isEmpty && exists(link), "changed link text cannot consume the source")
      try check(try fm.destinationOfSymbolicLink(atPath: link.path) == "missing-before", "retargeted-copy failure leaves the source link intact")
    }
    do {
      let(file,target,dest)=try fixture("copy"), before=try dates(file)
      let result=transfer(file,target,move:false)
      try check(result.errors.isEmpty && result.changes.count==1,"ordinary copy completes")
      try check(try dates(dest)==before && dates(file)==before,"copy restores and reads back raw dates")
      try check(result.transfers[0].datesVerified && !result.transfers[0].contentVerified,"system copy does not claim application checksum verification")
      try check(try Data(contentsOf:dest)==Data(contentsOf:file),"system copy preserves fixture data")
      try check(try clean(target),"success has no journals or staging residuals")
    }
    do {
      let(file,target,dest)=try fixture("rename"), identity=try FileActions.identity(file), before=try dates(file)
      var hooks=TransferHooks();hooks.copy={_,_ in throw MetadataCheckFailure("rename must not copy")}
      let result=FileActions.transfer([file],to:target,move:true,hooks:hooks)
      try check(result.errors.isEmpty && result.transfers[0].method == .rename,"same-volume move uses exclusive rename")
      try check(!exists(file) && (try dates(dest))==before && FileActions.identity(dest)==identity,"rename preserves identity and dates")
    }
    do {
      let(file,target,dest)=try fixture("move"), before=try dates(file)
      var hooks=TransferHooks();hooks.checkpoint={stage,current,_ in
        if stage == .beforeRemove { try check(current==file && exists(file),"source keeps its original name until deletion") }
      }
      let result=transfer(file,target,hooks:hooks)
      try check(result.errors.isEmpty && !exists(file) && exists(dest),"copy-move completes")
      try check(try dates(dest)==before,"move preserves dates")
      try check(result.consumedMoveSources==[file],"only complete move consumes cut source")
      try check(try clean(target) && fm.contentsOfDirectory(atPath:file.deletingLastPathComponent().path).isEmpty,"no hidden holding file or journals")
    }
    for move in [false, true] {
      let (file, target, dest) = try fixture("smb-reserved-target-\(move)"), before = try dates(file)
      var hooks = TransferHooks(), order: [String] = []
      hooks.nativeCopy.synchronizedMetadata = true
      hooks.exclusiveRename = { _, _ in throw MetadataCheckFailure("SMB must not depend on rename-stable inode numbers") }
      hooks.copy = { _, _ in throw MetadataCheckFailure("SMB must use the synchronized descriptor copy") }
      hooks.nativeCopy.descriptorCopy = { from, to, state, flags in
        order.append(flags & copyfile_flags_t(COPYFILE_DATA) != 0 ? "data" : "metadata")
        return fcopyfile(from, to, state, flags)
      }
      hooks.nativeCopy.synchronize = { fd in order.append("flush"); return fsync(fd) }
      let result = transfer(file, target, move: move, hooks: hooks)
      try check(result.errors.isEmpty && result.succeeded == [dest], "SMB-style target succeeds without renaming its copied inode")
      try check(order == ["data", "flush", "metadata"], "SMB copy flushes data before applying file properties even when exclusive rename is supported")
      try check(try Data(contentsOf: dest) == Data("OK".utf8) && dates(dest) == before && exists(file) != move, "SMB-style copy/move preserves dates and only consumes a verified move source")
      try check(try clean(target), "SMB-style success leaves no private staging directories")
    }
    for move in [false,true] {
      let(file,target,dest)=try fixture("date-skip-\(move)")
      var hooks=TransferHooks();hooks.restoreDates={_,_ in throw VerifiedTransfer.posix(ENOTSUP)}
      var problems=0;hooks.control=FileTransferControl(onProblem:{problem in problems+=1;return .skip})
      let result=transfer(file,target,move:move,hooks:hooks)
      try check(result.succeeded.isEmpty && exists(file) && !exists(dest),"skip date loss retains original source")
      try check(problems==1,"date loss is presented once, without duplicate generic dialog")
      try check(try clean(target) && result.transfers[0].recoveryLocations.isEmpty,"skip removes owned incomplete copy")
      try check(result.consumedMoveSources.isEmpty,"skipped move remains on cut clipboard")
    }
    for move in [false,true] {
      let(file,target,dest)=try fixture("date-continue-\(move)")
      var hooks=TransferHooks();hooks.restoreDates={_,_ in throw VerifiedTransfer.posix(ENOTSUP)}
      hooks.control=FileTransferControl(onProblem:{problem in problem.propertyLoss ? .continueWithoutProperties : .skip})
      let result=transfer(file,target,move:move,hooks:hooks)
      try check(result.succeeded==[dest] && result.errors.count==1 && !result.transfers[0].datesVerified,"explicit continuation completes with property warning")
      try check(exists(file) != move && (try Data(contentsOf:dest))==Data("OK".utf8),"only explicitly accepted move removes source")
      try check(try clean(target),"accepted property loss leaves no stage")
    }
    do {
      let(file,target,_)=try fixture("date-retry")
      var attempts=0, problems=0;var hooks=TransferHooks()
      hooks.restoreDates={fd,stamp in attempts+=1;if attempts==1 { throw VerifiedTransfer.posix(ENOTSUP) };try VerifiedTransfer.restoreDates(fd,stamp)}
      hooks.control=FileTransferControl(onProblem:{_ in problems+=1;return .retry})
      let result=transfer(file,target,hooks:hooks)
      try check(result.errors.isEmpty && attempts==2 && problems==1,"retry restores dates without recopying")
    }
    for code in [ENOSPC,EROFS,EACCES,ENOTCONN] {
      let(file,target,dest)=try fixture("copy-error-\(code)")
      var hooks=TransferHooks();hooks.copy={_,payload in try Data("P".utf8).write(to:payload);throw VerifiedTransfer.posix(code)}
      let result=transfer(file,target,hooks:hooks)
      try check(result.errors.count==1 && exists(file) && !exists(dest),"copy error preserves source")
      try check(try clean(target),"copy error automatically removes incomplete payload")
    }
    do {
      let(file,target,dest)=try fixture("generic-retry")
      var attempts=0;var hooks=TransferHooks()
      hooks.copy={source,payload in attempts+=1;if attempts==1 { try Data("P".utf8).write(to:payload);throw VerifiedTransfer.posix(ENOTCONN) };try fm.copyItem(at:source,to:payload)}
      hooks.control=FileTransferControl(onProblem:{_ in .retry})
      let result=transfer(file,target,hooks:hooks)
      try check(result.errors.isEmpty && attempts==2 && exists(dest),"copy retry starts from clean owned stage")
      try check(try clean(target),"retry does not accumulate leftovers")
    }
    do {
      let(file,target,dest)=try fixture("collision")
      try Data("existing".utf8).write(to:dest)
      var hooks=TransferHooks();hooks.control=FileTransferControl(onProblem:{$0.collision ? .keepBoth : .skip})
      let result=transfer(file,target,hooks:hooks)
      try check(result.succeeded.count==1 && result.succeeded[0] != dest && !exists(file),"keep both chooses an unused destination")
      try check(try Data(contentsOf:dest)==Data("existing".utf8),"collision never overwrites existing bytes")
    }
    do {
      let(file,target,dest)=try fixture("changed-source")
      var hooks=TransferHooks();hooks.checkpoint={stage,source,_ in if stage == .afterCopy { try Data("NEW".utf8).write(to:source) }}
      let result=transfer(file,target,hooks:hooks)
      try check(result.errors.count==1 && exists(file) && !exists(dest),"metadata change check prevents deleting concurrently changed source")
      try check(try Data(contentsOf:file)==Data("NEW".utf8) && clean(target),"changed source bytes retained and stage cleaned")
    }
    do {
      let trash = root.appendingPathComponent("replace-trash")
      try fm.createDirectory(at: trash, withIntermediateDirectories: false)
      let original = Data("existing".utf8), copied = Data("OK".utf8), occupant = Data("concurrent".utf8)
      for scenario in ["success", "stale", "copy-failure", "late-collision", "link"] {
        let (file, target, dest) = try fixture("replace-" + scenario)
        if scenario == "link" { try fm.createSymbolicLink(atPath: dest.path, withDestinationPath: "missing") }
        else { try original.write(to: dest) }
        var choices: [Bool] = []
        var hooks = TransferHooks()
        hooks.control = FileTransferControl(onProblem: { problem in
          choices.append(problem.canReplace)
          if scenario == "stale" { try! occupant.write(to: dest, options: .atomic) }
          return .replace
        })
        hooks.checkpoint = { checkpoint, _, _ in
          if scenario == "copy-failure", checkpoint == .beforeCopy { throw VerifiedTransfer.posix(EIO) }
          if scenario == "late-collision", checkpoint == .beforePublish { try occupant.write(to: dest, options: .withoutOverwriting) }
        }
        let result = FileActions.transfer([file], to: target, move: false, hooks: hooks, testTrash: trash)
        try check(choices == [scenario != "link"] && (try Data(contentsOf: file)) == copied, "\(scenario): eligibility and source preservation")
        switch scenario {
        case "success":
          try check(result.errors.isEmpty && result.succeeded.count == 1 && (try Data(contentsOf: dest)) == copied, "Replace publishes the new copy")
          try check(result.changes.map(\.kind) == [.trash, .copy], "Replace records both file changes")
          let undone = FileActions.undo(result.changes, testTrash: trash)
          try check(undone.errors.isEmpty && (try Data(contentsOf: dest)) == original, "Undo restores the original destination")
          let redone = FileActions.undo(undone.changes, testTrash: trash)
          try check(redone.errors.isEmpty && (try Data(contentsOf: dest)) == copied, "Redo restores the actual copied file")
        case "link":
          try check(result.succeeded.isEmpty && (try fm.destinationOfSymbolicLink(atPath: dest.path)) == "missing", "Replace preserves dangling destination links")
        case "late-collision":
          try check(result.succeeded.isEmpty && (try Data(contentsOf: dest)) == occupant && result.changes.count == 1, "Rollback leaves a new destination occupant untouched")
          let backup = result.changes[0].destination
          try check((try Data(contentsOf: backup)) == original && result.errors.contains { $0.contains(backup.path) }, "Rollback reports where the original can be recovered")
        default:
          let expected = scenario == "stale" ? occupant : original
          try check(result.succeeded.isEmpty && result.changes.isEmpty && (try Data(contentsOf: dest)) == expected, "\(scenario): failed replacement preserves the destination")
        }
      }
    }
    do {
      let(file,target,dest)=try fixture("unlink-error")
      var hooks=TransferHooks();hooks.checkpoint={stage,_,_ in if stage == .beforeRemove { throw VerifiedTransfer.posix(EACCES) }}
      let result=transfer(file,target,hooks:hooks)
      try check(result.errors.count==1 && exists(file) && exists(dest),"cleanup failure keeps source at original name")
      try check(result.consumedMoveSources.isEmpty && result.changes.isEmpty,"incomplete cleanup has no successful move or consumed clipboard source")
      try check(try clean(target),"cleanup failure needs no journal or hidden source recovery")
    }
    do {
      let(file,target,dest)=try fixture("target-loss")
      var hooks=TransferHooks();hooks.checkpoint={stage,_,_ in if stage == .beforeRemove { try fm.removeItem(at:dest) }}
      let result=transfer(file,target,hooks:hooks)
      try check(result.errors.count==1 && exists(file) && !exists(dest),"target disappearance stops before source deletion")
      try check(!result.transfers[0].datesVerified && !result.transfers[0].contentVerified,"failure cannot claim final verification")
    }
    do {
      let(file,target,dest)=try fixture("source-replaced")
      let saved=file.deletingLastPathComponent().appendingPathComponent("externally-saved")
      var hooks=TransferHooks();hooks.checkpoint={stage,_,_ in if stage == .beforeRemove { try fm.moveItem(at:file,to:saved);try Data("new occupant".utf8).write(to:file) }}
      let result=transfer(file,target,hooks:hooks)
      try check(result.errors.count==1 && exists(dest) && exists(saved),"source replacement fails cleanup safely")
      try check(try Data(contentsOf:file)==Data("new occupant".utf8),"replacement original name is not deleted")
    }
    do {
      let(file,target,_)=try fixture("tree")
      let tree=file.deletingLastPathComponent().appendingPathComponent("tree"), nested=file.deletingLastPathComponent().appendingPathComponent("tree/nested")
      try fm.createDirectory(at:nested,withIntermediateDirectories:true)
      try Data("child".utf8).write(to:nested.appendingPathComponent("child"));try Data().write(to:tree.appendingPathComponent("empty"))
      try fm.createSymbolicLink(atPath:tree.appendingPathComponent("broken").path,withDestinationPath:"missing")
      try fm.createSymbolicLink(atPath:tree.appendingPathComponent("relative").path,withDestinationPath:"nested/child")
      for path in [nested,tree] { try fm.setAttributes([.creationDate:Date(timeIntervalSince1970:1_500_000_000),.modificationDate:Date(timeIntervalSince1970:1_500_000_100)],ofItemAtPath:path.path) }
      let before=try [tree,nested].map(dates), result=transfer(tree,target)
      let copied=target.appendingPathComponent("tree")
      try check(result.errors.isEmpty && !exists(tree),"directory move handles links and empty files")
      try check(try [copied,copied.appendingPathComponent("nested")].map(dates)==before,"postorder restoration keeps directory dates")
      try check(exists(copied.appendingPathComponent("broken")) && (try fm.destinationOfSymbolicLink(atPath:copied.appendingPathComponent("relative").path))=="nested/child","links stay links without traversal")
    }
    do {
      let(file,target,_)=try fixture("unexpected-child")
      let tree=file.deletingLastPathComponent().appendingPathComponent("tree")
      try fm.createDirectory(at:tree,withIntermediateDirectories:false);try Data("child".utf8).write(to:tree.appendingPathComponent("child"))
      var inserted=false;var hooks=TransferHooks();hooks.checkpoint={stage,_,_ in if stage == .beforeRemove && !inserted { inserted=true;try Data("new".utf8).write(to:tree.appendingPathComponent("new-child")) }}
      let result=transfer(tree,target,hooks:hooks)
      try check(result.transfers[0].outcome == .cleanupIncomplete && exists(tree.appendingPathComponent("new-child")),"partial cleanup preserves unknown child at original path")
      try check(result.consumedMoveSources.isEmpty && exists(target.appendingPathComponent("tree/child")),"partial cleanup retains cut source and copied destination")
    }
    do {
      let(file,target,dest)=try fixture("resource-fork")
      let fork=Data(repeating:0x5a,count:1_048_593)
      guard fork.withUnsafeBytes({setxattr(file.path,"com.apple.ResourceFork",$0.baseAddress,$0.count,0,0)})==0 else { throw VerifiedTransfer.posix() }
      let result=transfer(file,target)
      try check(result.errors.isEmpty && getxattr(dest.path,"com.apple.ResourceFork",nil,0,0,0)==fork.count,"system copy retains large resource forks")
    }
    do {
      let(file,target,dest)=try fixture("cancel-copy")
      try Data(repeating:0x55,count:4*1024*1024).write(to:file)
      var control:FileTransferControl!
      control=FileTransferControl(onProgress:{value in if value.completedBytes>0 { control.cancel() }})
      var hooks=TransferHooks();hooks.control=control
      let result=transfer(file,target,hooks:hooks)
      try check(result.transfers[0].outcome == .cancelled && exists(file) && !exists(dest),"cancel during system copy preserves original")
      try check(try clean(target),"cancel cleans owned partial copy")
    }
    do {
      let(file,target,_)=try fixture("cancel-batch")
      let other=file.deletingLastPathComponent().appendingPathComponent("other");try Data("other".utf8).write(to:other)
      var hooks=TransferHooks();hooks.forceCopyMove=true;hooks.restoreDates={_,_ in throw VerifiedTransfer.posix(ENOTSUP)}
      hooks.control=FileTransferControl(onProblem:{_ in .cancel})
      let result=FileActions.transfer([file,other],to:target,move:true,hooks:hooks)
      try check(result.transfers.count==1 && exists(file) && exists(other),"cancel stops remaining batch items")
      try check(try fm.contentsOfDirectory(atPath:target.path).isEmpty,"cancelled batch leaves destination clean")
    }
    do {
      let(file,target,_)=try fixture("silent-date-loss")
      var hooks=TransferHooks();hooks.checkpoint={stage,_,payload in if stage == .afterCopy { try fm.setAttributes([.modificationDate:Date()],ofItemAtPath:payload.path) }}
      hooks.restoreDates={_,_ in }
      let result=transfer(file,target,hooks:hooks)
      try check(result.errors.count==1 && exists(file),"silent date-setting failure cannot delete source")
      try check(try clean(target),"silent date loss cleans unpublished copy")
    }
    do {
      let(file,target,dest)=try fixture("nanoseconds-readonly")
      var info=stat();guard lstat(file.path,&info)==0 else { throw VerifiedTransfer.posix() }
      info.st_birthtimespec.tv_nsec=123_456_789;info.st_mtimespec.tv_nsec=987_654_321
      let fd=open(file.path,O_RDONLY);guard fd>=0 else { throw VerifiedTransfer.posix() };defer {close(fd)}
      try VerifiedTransfer.restoreDates(fd,TransferStamp(info));try fm.setAttributes([.posixPermissions:0o444],ofItemAtPath:file.path)
      let before=try dates(file), result=transfer(file,target)
      try check(result.errors.isEmpty && (try dates(dest))==before,"native timestamps retain local nanosecond precision")
      try check((try fm.attributesOfItem(atPath:dest.path)[.posixPermissions] as? NSNumber)?.intValue==0o444,"native copy retains readonly file mode")
    }
    do {
      let(file,target,_)=try fixture("cleanup-retry")
      var attempts=0;var hooks=TransferHooks();hooks.checkpoint={stage,_,_ in if stage == .beforeRemove { attempts+=1;if attempts==1 {throw VerifiedTransfer.posix(EACCES)} }}
      hooks.control=FileTransferControl(onProblem:{_ in .retry})
      let result=transfer(file,target,hooks:hooks)
      try check(result.errors.isEmpty && attempts==2 && !exists(file),"retry resumes guarded cleanup rather than creating another target")
    }
    do {
      let(file,target,dest)=try fixture("late-collision")
      var hooks=TransferHooks();hooks.checkpoint={stage,_,_ in if stage == .beforePublish { try Data("occupant".utf8).write(to:dest) }}
      let result=transfer(file,target,hooks:hooks)
      try check(result.errors.count==1 && exists(file) && (try Data(contentsOf:dest))==Data("occupant".utf8),"late destination collision cannot overwrite or delete source")
      try check(try clean(target),"late collision cleans temporary payload")
    }
    do {
      let(file,target,_)=try fixture("hardlinks")
      let tree=file.deletingLastPathComponent().appendingPathComponent("tree")
      try fm.createDirectory(at:tree,withIntermediateDirectories:false)
      let a=tree.appendingPathComponent("a"),b=tree.appendingPathComponent("b")
      try Data("linked".utf8).write(to:a);try fm.linkItem(at:a,to:b)
      let result=transfer(tree,target)
      try check(result.errors.isEmpty && !exists(tree),"hardlinked sources clean up without false inode change errors")
      try check(try Data(contentsOf:target.appendingPathComponent("tree/a"))==Data(contentsOf:target.appendingPathComponent("tree/b")),"both hardlinked fixture contents arrive")
    }
    do {
      let(file,target,_)=try fixture("parent-replaced")
      let saved=target.deletingLastPathComponent().appendingPathComponent("saved-target")
      var hooks=TransferHooks();hooks.checkpoint={stage,_,_ in if stage == .beforePublish {try fm.moveItem(at:target,to:saved);try fm.createDirectory(at:target,withIntermediateDirectories:false)} }
      let result=transfer(file,target,hooks:hooks)
      try check(result.errors.count==1 && exists(file),"parent identity change refuses publication")
      try check(result.transfers[0].recoveryLocations.contains { exists($0) && $0.resolvingSymlinksInPath().path.hasPrefix(saved.resolvingSymlinksInPath().path) },"uncleanable temporary copy reports its actual relocated recovery path")
    }
    do {
      let(file,target,_)=try fixture("pre-cancel")
      let control=FileTransferControl();control.cancel();var hooks=TransferHooks();hooks.control=control
      let result=transfer(file,target,hooks:hooks)
      try check(result.errors==[NL("已取消")] && result.succeeded.isEmpty && exists(file),"pre-cancel is not reported as successful completion")
    }
    do {
      let(file,target,_)=try fixture("property-already-handled")
      var prompts=0;var hooks=TransferHooks()
      hooks.copy={_,payload in
        try Data("P".utf8).write(to:payload)
        throw NativeTransferCopy.Failure(underlying:VerifiedTransfer.posix(ENOTSUP),handled:true)
      }
      hooks.control=FileTransferControl(onProblem:{_ in prompts+=1;return .skip})
      let result=transfer(file,target,hooks:hooks)
      try check(prompts==0 && result.errors.count==1 && exists(file) && (try clean(target)),"a handled system-property failure never triggers a second generic prompt")
    }
    // Reproduce a filesystem rejecting the exclusive publish primitive, without a NAS.
    func unsupported() -> TransferHooks {
      var hooks = TransferHooks()
      hooks.exclusiveRename = { _,_ in throw VerifiedTransfer.posix(ENOTSUP) }
      return hooks
    }
    for checkpoint in [TransferCheckpoint.afterCopy, .afterDates, .beforePublish, .afterPublish] {
      for replace in [false, true] {
        let(file,target,dest)=try fixture("target-change-\(checkpoint)-\(replace)")
        var hooks=unsupported()
        hooks.checkpoint={stage,_,_ in if stage == checkpoint {
          if replace { try fm.removeItem(at:dest) }
          let descriptor=open(dest.path,O_WRONLY|O_CREAT|O_TRUNC,0o600)
          guard descriptor>=0 else {throw VerifiedTransfer.posix()};defer{close(descriptor)}
          guard Darwin.write(descriptor,"NO",2)==2 else {throw VerifiedTransfer.posix()}
        }}
        // Continuing after a property warning must never accept a changed target.
        hooks.control=FileTransferControl(onProblem:{$0.propertyLoss ? .continueWithoutProperties : .skip})
        let result=transfer(file,target,hooks:hooks)
        try check(!result.errors.isEmpty && exists(file) && result.consumedMoveSources.isEmpty,"target changes at \(checkpoint) cannot consume a cut source")
        try check(try Data(contentsOf:file)==Data("OK".utf8) && Data(contentsOf:dest)==Data("NO".utf8),"target changes at \(checkpoint) preserve both the original and the external edit")
      }
    }
    do {
      let(file,target,dest)=try fixture("date-retry-after-write")
      var hooks=unsupported(),attempts=0,problems=0
      hooks.restoreDates={fd,stamp in
        attempts+=1;try VerifiedTransfer.restoreDates(fd,stamp)
        if attempts==1 {throw VerifiedTransfer.posix(EIO)}
      }
      hooks.control=FileTransferControl(onProblem:{_ in problems+=1;return problems==1 ? .retry : .skip})
      let result=transfer(file,target,hooks:hooks)
      try check(result.errors.isEmpty && attempts==2 && problems==1 && exists(dest) && !exists(file),"retry trusts only the metadata changes made by this transfer")
    }
    func aclText(_ url:URL) throws -> String {
      guard let acl=acl_get_file(url.path,ACL_TYPE_EXTENDED) else {throw VerifiedTransfer.posix()};defer{acl_free(UnsafeMutableRawPointer(acl))}
      guard let text=acl_to_text(acl,nil) else {throw VerifiedTransfer.posix()};defer{acl_free(text)}
      return String(cString:text)
    }
    for descriptor in [false,true] {
      let(file,target,dest)=try fixture("explicit-acl-\(descriptor)")
      let chmod=Process();chmod.executableURL=URL(fileURLWithPath:"/bin/chmod");chmod.arguments=["+a","everyone deny write",file.path]
      try chmod.run();chmod.waitUntilExit();try check(chmod.terminationStatus==0,"ACL fixture is installed")
      let before=try aclText(file)
      let result=transfer(file,target,hooks:descriptor ? unsupported() : TransferHooks())
      try check(result.errors.isEmpty && !exists(file),"ACL-preserving move completes on both copy paths")
      try check(try aclText(dest)==before,"native and descriptor copies preserve explicit ACL entries")
    }
    for choice in [FileTransferDecision.skip, .continueWithoutProperties] {
      let(file,target,dest)=try fixture("lost-acl-\(choice)")
      let chmod=Process();chmod.executableURL=URL(fileURLWithPath:"/bin/chmod");chmod.arguments=["+a","everyone deny write",file.path]
      try chmod.run();chmod.waitUntilExit();try check(chmod.terminationStatus==0,"ACL-loss fixture is installed")
      var hooks=unsupported(),problems=0
      hooks.restoreDates={fd,stamp in
        guard let empty=acl_init(0) else {throw VerifiedTransfer.posix()};defer{acl_free(UnsafeMutableRawPointer(empty))}
        guard acl_set_fd_np(fd,empty,ACL_TYPE_EXTENDED)==0 else {throw VerifiedTransfer.posix()}
        try VerifiedTransfer.restoreDates(fd,stamp)
      }
      hooks.control=FileTransferControl(onProblem:{problem in if problem.propertyLoss {problems+=1};return choice})
      let result=transfer(file,target,hooks:hooks)
      if choice == .skip {
        try check(!result.errors.isEmpty && exists(file) && !exists(dest) && result.consumedMoveSources.isEmpty,"silent ACL loss cannot delete the source")
      } else {
        try check(result.succeeded==[dest] && !exists(file) && result.errors.count==1,"only explicit permission allows a move with ACL loss")
      }
      try check(problems==1,"ACL readback failure uses the property-loss decision")
    }
    do {
      let a=TransferMoment(timespec(tv_sec:100,tv_nsec:999_999_950)),b=TransferMoment(timespec(tv_sec:101,tv_nsec:0))
      try check(!a.matches(b,precision:1) && a.matches(b,precision:100),"only SMB tolerates sub-100ns client/server representation differences")
      try check(!a.matches(TransferMoment(timespec(tv_sec:101,tv_nsec:50)),precision:100),"a full 100ns metadata change is still rejected")
      var first=stat();first.st_mode=mode_t(S_IFREG|0o600);first.st_ino=1;first.st_size=2;first.st_birthtimespec=timespec(tv_sec:100,tv_nsec:0);first.st_mtimespec=timespec(tv_sec:200,tv_nsec:0);first.st_ctimespec=timespec(tv_sec:300,tv_nsec:0)
      var second=first;second.st_ctimespec=second.st_mtimespec
      try check(TransferStamp(first,precision:100).unchanged(TransferStamp(second,precision:100)) && !TransferStamp(first).unchanged(TransferStamp(second)),"SMB ChangeTime alias refresh is not treated as a local change token")
      second.st_mtimespec.tv_nsec=100
      try check(!TransferStamp(first,precision:100).unchanged(TransferStamp(second,precision:100)),"SMB mtime changes remain guarded despite unstable ChangeTime")
    }
    for move in [false,true] {
      let (file,target,dest) = try fixture("unsupported-\(move)"), before = try dates(file)
      let result = transfer(file,target,move:move,hooks:unsupported())
      try check(result.errors.isEmpty && result.transfers[0].method == .systemCopy,"unsupported exclusive rename uses the compatibility copy")
      try check(try dates(dest)==before && Data(contentsOf:dest)==Data("OK".utf8) && exists(file) != move,"compatibility copy preserves data/dates before source removal")
      try check(try clean(target),"compatibility success removes its empty probe/stage")
    }
    do {
      let (file,target,_) = try fixture("unsupported-tree")
      let tree=file.deletingLastPathComponent().appendingPathComponent("tree"), nested=tree.appendingPathComponent("nested")
      try fm.createDirectory(at:nested,withIntermediateDirectories:true)
      try Data().write(to:nested.appendingPathComponent("empty"))
      try fm.createSymbolicLink(atPath:tree.appendingPathComponent("broken").path,withDestinationPath:"absent")
      try Data("fork".utf8).write(to:tree.appendingPathComponent("data"))
      let fork = Data("resource".utf8)
      guard fork.withUnsafeBytes({setxattr(tree.appendingPathComponent("data").path,"com.apple.ResourceFork",$0.baseAddress,$0.count,0,0)})==0 else {throw VerifiedTransfer.posix()}
      try fm.setAttributes([.creationDate:Date(timeIntervalSince1970:1_500_000_000),.modificationDate:Date(timeIntervalSince1970:1_500_000_100)],ofItemAtPath:tree.path)
      let before=try dates(tree),result=transfer(tree,target,hooks:unsupported()),copied=target.appendingPathComponent("tree")
      try check(result.errors.isEmpty && !exists(tree),"compatibility directory move includes empty files and dangling links")
      try check(try dates(copied)==before && fm.destinationOfSymbolicLink(atPath:copied.appendingPathComponent("broken").path)=="absent","compatibility keeps directory dates and never follows links")
      try check(getxattr(copied.appendingPathComponent("data").path,"com.apple.ResourceFork",nil,0,0,0)==fork.count,"descriptor copy preserves resource forks")
    }
    for link in [false,true] {
      let(file,target,dest)=try fixture("unsupported-collision-\(link)")
      var hooks=unsupported()
      hooks.checkpoint={stage,_,_ in if stage == .beforeCopy {
        if link {try fm.createSymbolicLink(atPath:dest.path,withDestinationPath:"missing")} else {try Data("occupant".utf8).write(to:dest)}
      }}
      let result=transfer(file,target,hooks:hooks)
      try check(result.succeeded.isEmpty && exists(file),"late compatibility collision keeps source")
      try check(link ? try fm.destinationOfSymbolicLink(atPath:dest.path)=="missing" : try Data(contentsOf:dest)==Data("occupant".utf8),"late file/link collision is never overwritten or cleaned as owned")
    }
    do {
      let(file,target,dest)=try fixture("unsupported-date-skip")
      var hooks=unsupported();hooks.restoreDates={_,_ in throw VerifiedTransfer.posix(ENOTSUP)}
      let result=transfer(file,target,hooks:hooks)
      try check(result.errors.count==1 && exists(file) && !exists(dest) && (try clean(target)),"compatibility date rejection cleans only the reserved output")
    }
    do {
      let(file,target,dest)=try fixture("unsupported-cancel")
      try Data(repeating:0x55,count:4*1024*1024).write(to:file)
      var control:FileTransferControl!
      control=FileTransferControl(onProgress:{value in if value.completedBytes>0 {control.cancel()}})
      var hooks=unsupported();hooks.control=control
      let result=transfer(file,target,hooks:hooks)
      try check(result.transfers[0].outcome == .cancelled && exists(file) && !exists(dest) && (try clean(target)),"descriptor progress cancellation cleans owned partial output and keeps source")
    }
    do {
      let(file,target,_)=try fixture("unsupported-unknown-child")
      let tree=file.deletingLastPathComponent().appendingPathComponent("tree")
      try fm.createDirectory(at:tree,withIntermediateDirectories:false)
      try Data("OK".utf8).write(to:tree.appendingPathComponent("data"))
      let dest=target.appendingPathComponent("tree")
      var hooks=unsupported();hooks.checkpoint={stage,_,_ in if stage == .afterCopy {try Data("external".utf8).write(to:dest.appendingPathComponent("external"));throw VerifiedTransfer.posix(EIO)}}
      let result=transfer(tree,target,hooks:hooks)
      try check(result.succeeded.isEmpty && exists(tree) && exists(dest.appendingPathComponent("external")),"compatibility rollback preserves unknown children")
      try check(result.transfers[0].recoveryLocations.contains { $0.resolvingSymlinksInPath()==dest.resolvingSymlinksInPath() },"incomplete compatibility cleanup reports the public output path")
    }
    do {
      let(file,target,dest)=try fixture("unsupported-companion-collision")
      let companion=target.appendingPathComponent("._"+file.lastPathComponent)
      var hooks=unsupported();hooks.checkpoint={stage,_,_ in if stage == .beforeCopy {try Data("user data".utf8).write(to:companion)}}
      let result=transfer(file,target,hooks:hooks)
      try check(result.errors.isEmpty && !exists(file) && exists(dest),"APFS permits independent literal ._ names beside a copied file")
      try check(try Data(contentsOf:companion)==Data("user data".utf8),"an arbitrary ._ file is never overwritten by metadata copying")
    }
    do {
      let(file,target,_)=try fixture("dotunderscore-data")
      let tree=file.deletingLastPathComponent().appendingPathComponent("tree")
      try fm.createDirectory(at:tree,withIntermediateDirectories:false)
      try Data("data".utf8).write(to:tree.appendingPathComponent("paired"))
      // A valid FinderInfo-only AppleDouble header remains a data file on APFS.
      var header=Data([0,5,22,7,0,2,0,0]);header.append(Data(repeating:0,count:16));header.append(contentsOf:[0,1,0,0,0,9,0,0,0,38,0,0,0,32]);header.append(Data(repeating:0,count:32))
      try header.write(to:tree.appendingPathComponent("._paired"))
      try Data("plain".utf8).write(to:tree.appendingPathComponent("._plain"))
      let fd=open(tree.path,O_RDONLY|O_DIRECTORY);guard fd>=0 else {throw VerifiedTransfer.posix()};defer{close(fd)}
      try check(try AppleDoubleCompanion.stamp(in:fd,primary:"paired") != nil,"AppleDouble recognition validates the bounded header and entry table")
      var reads=0
      var offsets:[off_t]=[]
      let refreshed=try AppleDoubleCompanion.stamp(in:fd,primary:"paired",reader:{descriptor,buffer,length,position in
        reads+=1;offsets.append(position);if reads==1 {errno=EINTR;return -1}
        _=lseek(descriptor,0,SEEK_END);return Darwin.pread(descriptor,buffer,min(length,7),position)
      })
      try check(refreshed != nil && offsets==[0,0,7,14,21,26,33],"positioned header/table reads tolerate short reads and interruption independently of stream offset")
      reads=0
      do {_=try AppleDoubleCompanion.stamp(in:fd,primary:"paired",reader:{_,_,_,_ in reads+=1;errno=EIO;return -1});throw MetadataCheckFailure("I/O failure must propagate")} catch {
        try check((error as NSError).code==Int(EIO) && reads==1,"real metadata I/O errors are not silently retried or ignored")
      }
      try check(try !AppleDoubleCompanion.isMetadata("._paired",in:fd) && !AppleDoubleCompanion.isMetadata("._plain",in:fd),"APFS ._ data and unpaired names are not hidden as SMB metadata")
      let result=transfer(tree,target,hooks:unsupported()),copied=target.appendingPathComponent("tree")
      try check(result.errors.isEmpty && (try Data(contentsOf:copied.appendingPathComponent("._paired")))==header,"compatibility copy preserves literal ._ data")
    }
    do {
      let(file,target,dest)=try fixture("descriptor-staged-publish"),before=try dates(file)
      var hooks=TransferHooks();hooks.descriptorCopy=true
      hooks.copy={_,_ in throw MetadataCheckFailure("descriptor path must not recursively copy raw SMB sidecars")}
      let result=transfer(file,target,hooks:hooks)
      try check(result.errors.isEmpty && !exists(file) && (try Data(contentsOf:dest))==Data("OK".utf8),"descriptor copying also supports an exclusively published private payload")
      try check(try dates(dest)==before && clean(target),"descriptor staging preserves dates and cleans its private payload")
    }
    // Simulate a transient xattr syscall failure through the real copyfile callback.
    // DATA is real; only the first metadata syscall is injected.
    for behavior in ["retry", "source-change", "target-replace", "sync-failure"] {
      let (file,target,dest) = try fixture("metadata-order-" + behavior)
      var hooks = unsupported(), dataCalls = 0, metadataCalls = 0, syncCalls = 0, prompts = 0
      var order: [String] = []
      hooks.nativeCopy.synchronizedMetadata = true
      hooks.nativeCopy.synchronize = { fd in
        syncCalls += 1; order.append("sync")
        if behavior == "sync-failure" { errno = EIO; return -1 }
        return fsync(fd)
      }
      hooks.nativeCopy.descriptorCopy = { from,to,state,flags in
        if flags & copyfile_flags_t(COPYFILE_DATA) != 0 { dataCalls += 1; order.append("data") }
        if flags & copyfile_flags_t(COPYFILE_XATTR) != 0 {
          metadataCalls += 1; order.append("metadata")
          if metadataCalls == 1 {
            var function: UnsafeRawPointer?, context: UnsafeMutableRawPointer?
            guard copyfile_state_get(state, UInt32(COPYFILE_STATE_STATUS_CB), &function) == 0,
              copyfile_state_get(state, UInt32(COPYFILE_STATE_STATUS_CTX), &context) == 0, let function else { errno = EINVAL; return -1 }
            let callback = unsafeBitCast(function, to: copyfile_callback_t.self)
            errno = EIO
            _ = callback(COPYFILE_COPY_XATTR, COPYFILE_ERR, state, nil, nil, context)
            errno = EIO
            return -1
          }
        }
        return fcopyfile(from,to,state,flags)
      }
      hooks.control = FileTransferControl(onProblem: { problem in
        prompts += 1
        if !problem.propertyLoss { return .skip }
        if behavior == "source-change" { try? Data("changed".utf8).write(to: file) }
        if behavior == "target-replace" {
          try? fm.moveItem(at: dest, to: target.appendingPathComponent("owned-original"))
          try? Data("external".utf8).write(to: dest)
        }
        return prompts == 1 ? .retry : .skip
      })
      let before = try dates(file), result = transfer(file,target,hooks:hooks)
      try check(dataCalls == 1 && syncCalls == 1, "metadata retries and flush failures never perform a second DATA pass")
      try check(order.prefix(2).elementsEqual(["data","sync"]), "data is synchronized before any metadata writes")
      if behavior == "retry" {
        try check(result.errors.isEmpty && metadataCalls == 2 && prompts == 1 && !exists(file), "Retry really retries the metadata syscall without a second generic prompt")
        try check(try dates(dest) == before && Data(contentsOf: dest) == Data("OK".utf8), "retried metadata retains dates and payload before removing source")
      } else {
        try check(!result.errors.isEmpty && exists(file) && result.consumedMoveSources.isEmpty, "concurrent source/target changes and flush errors still retain the source")
        if behavior == "source-change" { try check(metadataCalls == 1, "a changed source stops before the metadata retry") }
        if behavior == "target-replace" { try check(try Data(contentsOf: dest) == Data("external".utf8), "metadata retry never overwrites the replacement path") }
        if behavior == "sync-failure" { try check(metadataCalls == 0, "failed data synchronization prevents metadata writes") }
      }
    }
    do {
      let (file,target,dest) = try fixture("path-property-retry")
      var hooks = TransferHooks(), attempts = 0, prompts = 0
      hooks.copy = { from,to in
        attempts += 1
        try fm.copyItem(at: from, to: to)
        if attempts == 1 { throw NativeTransferCopy.Retry() }
      }
      hooks.control = FileTransferControl(onProblem: { _ in prompts += 1; return .skip })
      let result = transfer(file,target,hooks:hooks)
      try check(result.errors.isEmpty && attempts == 2 && prompts == 0 && !exists(file) && exists(dest), "path-copy property retry cleans its private stage and restarts without another prompt")
      try check(try clean(target), "path-copy property retry leaves no extra stage")
    }
    do {
      let (file,target,dest) = try fixture("read-only-loss")
      guard chmod(file.path,0o400)==0 else {throw VerifiedTransfer.posix()}
      var hooks=TransferHooks(),problems=0
      hooks.copy={from,to in try fm.copyItem(at:from,to:to);guard chmod(to.path,0o600)==0 else {throw VerifiedTransfer.posix()}}
      hooks.control=FileTransferControl(onProblem:{problem in
        if problem.propertyLoss && problem.message.contains("只读") {problems+=1}
        return .skip
      })
      let result=transfer(file,target,hooks:hooks)
      try check(problems==1 && result.succeeded.isEmpty && exists(file) && !exists(dest),"a destination gaining write permission on a read-only source requires explicit property-loss consent")
      try check(result.consumedMoveSources.isEmpty && (try clean(target)),"read-only loss keeps its cut source and cleans only its owned target")
    }
    print("MetadataTransferChecks: \(count) assertions passed; Windows-style decisions use local fixtures only, no real cross-volume or NAS operations.")
  }
}
