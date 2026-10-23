import Foundation

@main
enum LatestCoreChecks {
  static func main() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-latest-core-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    var checks = 0
    func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
      guard try condition() else { throw NSError(domain: "LatestCoreChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }; checks += 1
    }
    let folder = root.appendingPathComponent("项目"), alias = root.appendingPathComponent("alias"), file = root.appendingPathComponent("file.txt"), app = root.appendingPathComponent("Fake.app")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    try Data("preserved".utf8).write(to: file)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: folder)
    func searchNames(_ query: String, _ mode: FileSearchMode = .text, hidden: Bool = false) throws -> [String] {
      try FileSearch.search(in: root, query: query, showHidden: hidden, mode: mode).entries.map(\.name).sorted()
    }
    try Data().write(to: folder.appendingPathComponent("Report.PDF"))
    try Data().write(to: app.appendingPathComponent("private.pdf"))
    try Data().write(to: root.appendingPathComponent(".hidden.pdf"))
    try Data().write(to: root.appendingPathComponent("a[1].txt"))
    try expect(try searchNames("FILE") == ["file.txt"], "Default search remains case insensitive plain text")
    try expect(try searchNames("*.pdf").isEmpty, "Plain text does not interpret wildcards")
    try expect(try searchNames("*.pdf", .wildcard) == ["Report.PDF"], "Wildcards recurse without following links or packages and hide hidden files")
    try expect(try searchNames("*.pdf", .wildcard, hidden: true) == [".hidden.pdf", "Report.PDF"], "Wildcard search honors hidden files")
    try expect(try searchNames("a[?].txt", .wildcard) == ["a[1].txt"], "Question mark matches one character and regex punctuation stays literal")
    try expect(try searchNames("file", .wildcard).isEmpty, "Wildcards match the whole filename")
    try expect(try searchNames(#"^report.*\.(pdf|docx)$"#, .regex) == ["Report.PDF"], "Regex supports anchors, groups and alternatives")
    try expect(try searchNames("port", .regex) == ["Report.PDF"], "Regex can match part of a filename")
    do { _ = try searchNames("[", .regex); throw CocoaError(.validationMissingMandatoryProperty) }
    catch { try expect((error as NSError).domain == "FileSearch", "Invalid regex returns a search error") }
    let expensive = root.appendingPathComponent(String(repeating: "a", count: 100) + "!")
    try Data().write(to: expensive)
    do { _ = try searchNames("^(a+)+$", .regex); throw CocoaError(.validationMissingMandatoryProperty) }
    catch { try expect((error as NSError).domain == "FileSearch" && (error as NSError).code == 2, "Pathological regex is interrupted") }
    try FileManager.default.removeItem(at: expensive)
    let candidates = [FinderFavorite(path: folder.path, name: "收藏名称"), FinderFavorite(path: alias.path, name: "Alias duplicate"), FinderFavorite(path: file.path, name: "File"), FinderFavorite(path: app.path, name: "App"), FinderFavorite(path: "relative", name: "Invalid"), FinderFavorite(path: root.appendingPathComponent("missing").path, name: "Missing")]
    let result = FinderFavoritesReader.filter(candidates)
    try expect(result.places.count == 1 && result.places[0].name == "收藏名称", "Finder deduplicates aliases and retains the first display name")
    try expect(result.skipped == 4, "Finder rejects files, packages, relative and missing locations")
    let suite = "native-latest-core.\(UUID().uuidString)", defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let bookmark = try URL(string: "smb://user:secret@fixture.invalid/share")!.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    let snapshot = try NSKeyedArchiver.archivedData(withRootObject: ["items": [["Name": "Fixture server", "Bookmark": bookmark], ["Name": "Broken", "Bookmark": Data([0])]]], requiringSecureCoding: true)
    let decoded = try FinderServersReader.decodeSnapshot(snapshot)
    try expect(decoded.servers == [FinderServer(address: "smb://fixture.invalid/share", name: "Fixture server")] && decoded.skipped == 1, "Modern Finder archive resolves offline bookmarks and rejects corrupt entries without mounting")
    for corrupt in [Data("bad archive".utf8), try NSKeyedArchiver.archivedData(withRootObject: ["wrong": []], requiringSecureCoding: true), Data(repeating: 0, count: 4 * 1024 * 1024 + 1)] {
      do { _ = try FinderServersReader.decodeSnapshot(corrupt); throw CocoaError(.validationMissingMandatoryProperty) }
      catch { try expect((error as NSError).domain != NSCocoaErrorDomain || (error as NSError).code != CocoaError.Code.validationMissingMandatoryProperty.rawValue, "Invalid server archives fail safely") }
    }
    let servers = FinderServersReader.filter([
      FinderServer(address: "SMB://user:secret@NAS.invalid:445/share", name: "Shared"),
      FinderServer(address: "smb://nas.invalid/share", name: "Duplicate"),
      FinderServer(address: "smb://nas.invalid/Other", name: "Other"),
      FinderServer(address: "smb://nas.invalid/share?secret=value", name: "Invalid"),
      FinderServer(address: "afp://nas.invalid/share", name: "Unsupported"),
      FinderServer(address: "file:///Volumes/Test", name: "Mounted path"),
      FinderServer(address: "smb://nas.invalid/share\n", name: "Control"),
      FinderServer(address: "smb://[::1]:1445/中文 空格", name: "Unicode"),
      FinderServer(address: "smb://offline.invalid/", name: "smb://user:secret@offline.invalid/")
    ])
    try expect(servers.servers.count == 4 && servers.skipped == 4, "Server import rejects unsupported, invalid and file addresses without mounting")
    try expect(servers.servers[0] == FinderServer(address: "smb://nas.invalid/share", name: "Shared"), "Server import strips credentials and normalizes authority without losing first name")
    try expect(servers.servers.last?.name == "offline.invalid", "URL display names cannot retain credentials")
    try expect(servers.servers.contains { $0.address.contains("[::1]:1445/") }, "IPv6, nondefault ports and Unicode paths survive import")
    try expect(try NativeServerFavorites.merge(servers.servers, into: defaults) == 4, "Server import persists all valid offline favorites")
    try expect(try NativeServerFavorites.merge(servers.servers.reversed(), into: defaults) == 0 && NativeServerFavorites.load(defaults) == servers.servers, "Repeated import preserves existing server names and order")
    let savedServers = defaults.data(forKey: NativeServerFavorites.preferenceKey)!
    try expect(!String(decoding: savedServers, as: UTF8.self).contains("secret"), "No imported URL credentials reach persisted preferences")
    try NativeServerFavorites.remove(servers.servers[0].address, from: defaults)
    try expect(NativeServerFavorites.load(defaults) == Array(servers.servers.dropFirst()), "Removing a favorite preserves all remaining servers")
    let largeFavorites = (0..<500).map { FinderServer(address: "smb://fixture.invalid/" + String($0) + String(repeating: "a", count: 1500), name: String(repeating: "收藏", count: 200)) }
    defaults.removeObject(forKey: NativeServerFavorites.preferenceKey)
    try expect(try NativeServerFavorites.merge(largeFavorites, into: defaults) == 500 && defaults.data(forKey: NativeServerFavorites.preferenceKey)!.count > 1024 * 1024 && NativeServerFavorites.load(defaults) == largeFavorites, "The bounded 500-server list reloads even when long Unicode names exceed one MiB")
    defaults.set(Data("bad".utf8), forKey: NativeServerFavorites.preferenceKey)
    try expect(NativeServerFavorites.load(defaults).isEmpty, "Corrupt server favorites are ignored")
    var places = QuickAccessState(defaults: defaults)
    places.toggle("/Existing", defaultPaths: ["/Downloads"])
    places.toggle("/Downloads", defaultPaths: ["/Downloads"])
    let imported = [FinderFavorite(path: "/Downloads", name: "下载"), result.places[0], FinderFavorite(path: "/Cloud", name: "Cloud")]
    try expect(places.merge(imported, defaultPaths: ["/Downloads"], excludedPaths: ["/Cloud"]) == 2, "Import restores defaults and appends new items")
    try expect(places.visible(defaultPaths: ["/Downloads"]) == ["/Existing", "/Downloads", folder.standardizedFileURL.path], "Import preserves existing order")
    try expect(places.merge(imported, defaultPaths: ["/Downloads"], excludedPaths: ["/Cloud"]) == 0, "Repeated import adds no duplicates")
    places.save(to: defaults)
    try expect(QuickAccessState(defaults: defaults).importedNames[folder.standardizedFileURL.path] == "收藏名称", "Imported names survive reload")
    try expect(NativeStartLocation.load(defaults) == .home, "Unset startup setting retains the personal folder default")
    defaults.set("computer", forKey: NativeStartLocation.preferenceKey)
    try expect(NativeStartLocation.load(defaults).url(home: root).absoluteString == "explorer://computer", "This PC is a virtual location rather than a filesystem path")
    try expect(NativeStartLocation.initialURL(explicit: nil, defaults: defaults, home: root).absoluteString == "explorer://computer", "A normal start uses the selected landing page")
    try expect(NativeStartLocation.initialURL(explicit: folder.path, defaults: defaults, home: root).path == folder.path, "An explicit local path overrides This PC")
    try expect(NativeStartLocation.initialURL(explicit: folder.absoluteString, defaults: defaults, home: root) == folder, "An explicit file URL remains supported")
    try expect(NativeStartLocation.initialURL(explicit: "explorer://network", defaults: defaults, home: root).absoluteString == "explorer://network", "An explicit virtual path overrides the default")
    defaults.set("home", forKey: NativeStartLocation.preferenceKey)
    try expect(NativeStartLocation.initialURL(explicit: nil, defaults: defaults, home: root) == root, "Personal folder uses the caller's configured home")
    try expect(NativeStartLocation.initialURL(explicit: "explorer://computer", defaults: defaults, home: root).absoluteString == "explorer://computer", "An explicit This PC URL overrides personal folder")
    for invalid in ["network", "trash", "smb://fixture/share", folder.path, 1, ["computer"]] as [Any] {
      defaults.set(invalid, forKey: NativeStartLocation.preferenceKey)
      try expect(NativeStartLocation.load(defaults).url(home: root) == root, "Unknown startup values safely fall back without opening arbitrary paths")
    }
    defaults.removeObject(forKey: NativeStartLocation.preferenceKey)
    let windows = [NativeSavedWindow(locations: [folder.absoluteString, "explorer://trash", "https://example.com", "file://evil.example/etc/passwd", "explorer://unknown"], frame: "{{0, 0}, {1000, 700}}")]
    try NativeSessions.save(windows, to: defaults)
    try expect(NativeSessions.load(defaults).first?.locations == [folder.absoluteString, "explorer://trash"], "Session persistence rejects remote URLs and unknown virtual locations")
    defaults.set(Data("corrupt".utf8), forKey: "nativeWindows")
    try expect(NativeSessions.load(defaults).isEmpty, "Corrupt session data is ignored")
    NativeLanguage.load(from: URL(fileURLWithPath: CommandLine.arguments[1]))
    NativeLanguage.mode = "en"
    try expect(NL("从 Finder 导入收藏夹") == "Import Finder favorites", "English catalog is loaded")
    try expect(NL("已导入 {0} 项", "归档{1}.zip") == "Imported 归档{1}.zip items", "Interpolation preserves filenames containing placeholder syntax")
    let copied = FileActions.transfer([file], to: root, move: false)
    try expect(copied.errors.isEmpty && copied.succeeded.first?.lastPathComponent == "file - Copy.txt", "Generated copy names follow the interface language")
    NativeLanguage.mode = "zh-TW"
    try expect(NL("从 Finder 导入收藏夹") == "從 Finder 匯入喜好項目", "Traditional Chinese catalog is loaded")
    NativeLanguage.mode = "zh-CN"
    let literal = "含空格 $(touch forbidden); --literal"
    try expect(NativeCommand.run(executable: "/usr/bin/printf", arguments: ["%s", literal]).text == literal, "Native command arguments remain literal without a shell")
    do { _ = try NativeCommand.run(executable: "/usr/bin/false", arguments: []); throw CocoaError(.validationMissingMandatoryProperty) } catch let error as NativeCommandError { try expect(error.result.status != 0, "Command errors retain the actual exit status") }
    do { _ = try NativeCommand.run(executable: "/bin/sleep", arguments: ["3"], timeout: 0.1); throw CocoaError(.validationMissingMandatoryProperty) } catch { try expect((error as NSError).domain == "NativeCommand", "Native commands enforce deadlines") }
    do { _ = try NativeCommand.run(executable: "/usr/bin/head", arguments: ["-c", "4096", "/dev/zero"], limit: 128); throw CocoaError(.validationMissingMandatoryProperty) } catch { try expect((error as NSError).domain == "NativeCommand", "Native commands enforce output limits") }
    try expect(try String(contentsOf: file, encoding: .utf8) == "preserved", "All source fixture contents remain unchanged")
    print("LatestCoreChecks: \(checks) checks passed.")
  }
}
