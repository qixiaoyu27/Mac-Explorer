import Foundation
import Darwin
import ExplorerCore

struct NativeFileFailure {
  let message: String
  let offersPrivacySettings: Bool

  static func describe(_ error: Error, at context: URL?, networkLocation: (URL) -> Bool? = NativeFileFailure.networkLocation) -> Self {
    var chain: [NSError] = [], next: NSError? = error as NSError, seen = Set<ObjectIdentifier>()
    while let current = next, chain.count < 8, seen.insert(ObjectIdentifier(current)).inserted {
      chain.append(current); next = current.userInfo[NSUnderlyingErrorKey] as? NSError
    }
    let path = chain.compactMap { value -> URL? in
      if let path = value.userInfo[NSFilePathErrorKey] as? String, path.hasPrefix("/") { return URL(fileURLWithPath: path) }
      if let url = value.userInfo[NSURLErrorKey] as? URL, url.isFileURL { return url }
      return nil
    }.last ?? context
    func denied(_ value: NSError) -> Bool {
      value.domain == NSCocoaErrorDomain && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(value.code)
      || value.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(value.code)
      || value.domain == NSOSStatusErrorDomain && [-54, -5000].contains(value.code)
    }
    if let failure = chain.last(where: denied) {
      let code = failure.domain == NSPOSIXErrorDomain ? "\(failure.code == Int(EACCES) ? "EACCES" : "EPERM") (\(failure.code))" : "\(failure.domain) \(failure.code)"
      let network = path.flatMap(networkLocation)
      let detail = network == true ? NL("共享访问被拒绝，请检查共享权限或服务器限制。（{0}）", code) : NL("访问被拒绝，请检查文件权限或应用访问授权。（{0}）", code)
      return Self(message: path.map { detail + " " + $0.path } ?? detail, offersPrivacySettings: network == false)
    }
    let missing = chain.contains { $0.domain == NSCocoaErrorDomain && $0.code == NSFileReadNoSuchFileError || $0.domain == NSPOSIXErrorDomain && $0.code == Int(ENOENT) }
    return Self(message: missing ? NL("文件夹不存在") : error.localizedDescription, offersPrivacySettings: false)
  }

  /// Cached mount information only; no network metadata reads or path-name guesses.
  static func networkLocation(_ url: URL) -> Bool? {
    guard url.isFileURL else { return url.scheme?.lowercased() == "smb" ? true : nil }
    var buffer: UnsafeMutablePointer<statfs>?
    let count = getmntinfo_r_np(&buffer, MNT_NOWAIT)
    guard count > 0, let buffer else { return nil }; defer { Darwin.free(buffer) }
    var bestLength = -1, result: Bool?
    for index in 0..<Int(count) {
      var mount = buffer[index]
      let path = withUnsafePointer(to: &mount.f_mntonname) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) } }
      if (url.path == path || url.path.hasPrefix(path == "/" ? "/" : path + "/")), path.count > bestLength {
        bestLength = path.count; result = mount.f_flags & UInt32(MNT_LOCAL) == 0
      }
    }
    return result
  }
}
