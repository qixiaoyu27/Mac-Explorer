import Foundation

public struct FileEntry: Identifiable, Hashable, Sendable {
  public let url: URL
  public let name: String
  public let isDirectory: Bool
  public let isSymbolicLink: Bool
  public let isPackage: Bool
  public let size: Int64
  public let modified: Date?
  public let created: Date?
  public let resourceIdentifier: Data?
  public let added: Date?
  public var vcsMark: String? = nil
  public let isHidden: Bool

  public var id: String { url.path }

  public var kind: String {
    if isSymbolicLink {
      return isDirectory ? NL("文件夹链接") : NL("符号链接")
    }
    if isDirectory { return isPackage ? NL("应用程序") : NL("文件夹") }
    let fileExtension = url.pathExtension
    let names = ["pdf": NL("PDF 文档"), "txt": NL("文本文档"), "md": NL("Markdown 文档"), "png": NL("PNG 图像"), "jpg": NL("JPEG 图像"), "jpeg": NL("JPEG 图像"), "heic": NL("HEIC 图像"), "zip": NL("ZIP 压缩文件"), "dmg": NL("磁盘映像"), "mp4": NL("MP4 视频"), "mov": NL("QuickTime 视频"), "mp3": NL("MP3 音频"), "docx": NL("Word 文档"), "xlsx": NL("Excel 工作簿"), "pptx": NL("PowerPoint 演示文稿")]
    return names[fileExtension.lowercased()] ?? (fileExtension.isEmpty ? NL("文件") : NL("{0} 文件", fileExtension.uppercased()))
  }

  public init(
    url: URL,
    name: String,
    isDirectory: Bool,
    isSymbolicLink: Bool,
    isPackage: Bool,
    size: Int64,
    modified: Date?,
    isHidden: Bool,
    created: Date? = nil,
    resourceIdentifier: Data? = nil,
    added: Date? = nil
  ) {
    self.url = url
    self.name = name
    self.isDirectory = isDirectory
    self.isSymbolicLink = isSymbolicLink
    self.isPackage = isPackage
    self.size = size
    self.modified = modified
    self.created = created
    self.resourceIdentifier = resourceIdentifier
    self.added = added
    self.isHidden = isHidden
  }
}

public struct DirectorySnapshot: Sendable {
  public let directory: URL
  public let entries: [FileEntry]
  public let skippedCount: Int
  public let elapsedMilliseconds: Double

  public init(
    directory: URL,
    entries: [FileEntry],
    skippedCount: Int,
    elapsedMilliseconds: Double
  ) {
    self.directory = directory
    self.entries = entries
    self.skippedCount = skippedCount
    self.elapsedMilliseconds = elapsedMilliseconds
  }
}
