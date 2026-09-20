import AppKit

let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsLocalKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey]
func volumes() throws -> [[String: Any]] {
    let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: []) ?? []
    return try urls.filter { $0.path == "/" || $0.path.hasPrefix("/Volumes/") }.map { url in
        let values = try url.resourceValues(forKeys: keys)
        let ejectable = url.path != "/" && (values.volumeIsEjectable == true || values.volumeIsRemovable == true || values.volumeIsLocal == false)
        return ["path": url.path, "name": values.volumeName ?? url.lastPathComponent, "icon": "drive", "total": values.volumeTotalCapacity ?? 0, "free": values.volumeAvailableCapacity ?? 0, "canEject": ejectable]
    }
}
do {
    let arguments = CommandLine.arguments
    if arguments.count == 3 && arguments[1] == "eject" {
        let requested = arguments[2]
        guard try volumes().contains(where: { $0["path"] as? String == requested && $0["canEject"] as? Bool == true }) else {
            throw NSError(domain: "MacExplorer", code: 1, userInfo: [NSLocalizedDescriptionKey: "此位置不是可推出的已挂载磁盘。"])
        }
        try NSWorkspace.shared.unmountAndEjectDevice(at: URL(fileURLWithPath: requested))
    } else if arguments.count != 2 || arguments[1] != "list" {
        throw NSError(domain: "MacExplorer", code: 2, userInfo: [NSLocalizedDescriptionKey: "无效的磁盘操作。"])
    }
    let data = try JSONSerialization.data(withJSONObject: volumes())
    FileHandle.standardOutput.write(data)
} catch {
    FileHandle.standardError.write(Data(error.localizedDescription.utf8))
    exit(1)
}
