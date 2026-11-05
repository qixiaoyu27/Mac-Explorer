import Foundation

/// A locally mounted cloud provider folder. Authentication and hydration stay
/// with the provider's own macOS client; Explorer only reads the file system.
public struct NativeCloudDrive: Equatable, Sendable {
  public enum Provider: String, Sendable { case oneDrive, box, dropbox, googleDrive }
  public let url: URL
  public let name: String
  public let provider: Provider
}

public enum NativeCloudDrives {
  public static func discover(home: URL = FileManager.default.homeDirectoryForCurrentUser, mountedVolumes: [URL]? = nil) -> [NativeCloudDrive] {
    let manager = FileManager.default
    let cloudStorage = home.appendingPathComponent("Library/CloudStorage", isDirectory: true)
    var candidates = (try? manager.contentsOfDirectory(at: cloudStorage, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])) ?? []
    // Legacy sync clients may still expose a home folder instead of File Provider storage.
    candidates += ["OneDrive", "Box", "Dropbox", "Google Drive"].map { home.appendingPathComponent($0, isDirectory: true) }
    candidates += mountedVolumes ?? (manager.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey], options: [.skipHiddenVolumes]) ?? [])

    var seen = Set<String>(), result: [NativeCloudDrive] = []
    for candidate in candidates {
      let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL
      let path = resolved.path
      guard seen.insert(path).inserted,
            let values = try? resolved.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]), values.isDirectory == true, values.isPackage != true,
            let provider = provider(for: candidate.lastPathComponent) else { continue }
      result.append(NativeCloudDrive(url: resolved, name: displayName(candidate.lastPathComponent, provider: provider), provider: provider))
    }
    return result.sorted { lhs, rhs in
      let left = rank(lhs.provider), right = rank(rhs.provider)
      return left == right ? lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending : left < right
    }
  }

  private static func provider(for name: String) -> NativeCloudDrive.Provider? {
    let value = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    if value.hasPrefix("onedrive") { return .oneDrive }
    if value == "box" || value.hasPrefix("box-") || value.hasPrefix("box ") { return .box }
    if value.hasPrefix("dropbox") { return .dropbox }
    if value.hasPrefix("googledrive") || value.hasPrefix("google drive") { return .googleDrive }
    return nil
  }

  private static func displayName(_ value: String, provider: NativeCloudDrive.Provider) -> String {
    switch provider {
    case .oneDrive: return value
    case .box: return value == "Box" ? "Box Drive" : value
    case .dropbox: return value
    case .googleDrive: return value
    }
  }

  private static func rank(_ provider: NativeCloudDrive.Provider) -> Int {
    switch provider { case .oneDrive: return 0; case .box: return 1; case .dropbox: return 2; case .googleDrive: return 3 }
  }
}
