import Foundation

do {
    guard CommandLine.arguments.count == 2 else { throw CocoaError(.fileReadInvalidFileName) }
    var destination: NSURL?
    try FileManager.default.trashItem(at: URL(fileURLWithPath: CommandLine.arguments[1]), resultingItemURL: &destination)
    guard let destination = destination else { throw CocoaError(.fileWriteUnknown) }
    let data = try JSONSerialization.data(withJSONObject: ["path": destination.path!])
    FileHandle.standardOutput.write(data)
} catch {
    FileHandle.standardError.write(Data(error.localizedDescription.utf8))
    exit(1)
}
