import AppKit
import Foundation

// Keep NSWorkspace's multi-resolution icon intact until drawing at the requested
// physical pixel size. Resizing Electron's 32px bitmap cannot recover this detail.
struct Request: Decodable { let id: Int; let path: String; let pixels: Int }
struct Response: Encodable { let id: Int; let data: String?; let error: String? }

func render(_ request: Request) throws -> String {
    let pixels = min(512, max(32, request.pixels))
    guard request.path.hasPrefix("/"), FileManager.default.fileExists(atPath: request.path) else {
        throw NSError(domain: "FileIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "文件已不存在"])
    }
    let icon = NSWorkspace.shared.icon(forFile: request.path)
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "FileIcon", code: 2)
    }
    let bounds = NSRect(x: 0, y: 0, width: pixels, height: pixels)
    bitmap.size = bounds.size
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    NSColor.clear.setFill()
    bounds.fill(using: .copy)
    icon.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1,
        respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high])
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "FileIcon", code: 3)
    }
    return "data:image/png;base64," + png.base64EncodedString()
}

while let line = readLine() {
    autoreleasepool {
        guard let data = line.data(using: .utf8), let request = try? JSONDecoder().decode(Request.self, from: data) else { return }
        let response: Response
        do { response = Response(id: request.id, data: try render(request), error: nil) }
        catch { response = Response(id: request.id, data: nil, error: error.localizedDescription) }
        if let encoded = try? JSONEncoder().encode(response) {
            FileHandle.standardOutput.write(encoded)
            FileHandle.standardOutput.write(Data([10]))
        }
    }
}
