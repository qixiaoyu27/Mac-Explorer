import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Keep NSWorkspace's multi-resolution icon intact until drawing at the requested
// physical pixel size. Resizing Electron's 32px bitmap cannot recover this detail.
struct Request: Decodable { let id: Int; let path: String; let pixels: Int }
struct Response: Encodable { let id: Int; let data: String?; let error: String? }

func imageThumbnail(_ path: String, pixels: Int) -> NSImage? {
    let url = URL(fileURLWithPath: path)
    guard UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true,
        let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
        let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
        ] as CFDictionary) else { return nil }
    return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
}

func render(_ request: Request) throws -> String {
    let pixels = min(512, max(32, request.pixels))
    guard request.path.hasPrefix("/"), FileManager.default.fileExists(atPath: request.path) else {
        throw NSError(domain: "FileIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "文件已不存在"])
    }
    let thumbnail = imageThumbnail(request.path, pixels: pixels)
    let icon = thumbnail ?? NSWorkspace.shared.icon(forFile: request.path)
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
    var imageBounds = bounds
    if thumbnail != nil {
        let scale = min(bounds.width / icon.size.width, bounds.height / icon.size.height)
        let width = icon.size.width * scale, height = icon.size.height * scale
        imageBounds = NSRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
    }
    icon.draw(in: imageBounds, from: .zero, operation: .sourceOver, fraction: 1,
        respectFlipped: false, hints: [.interpolation: NSImageInterpolation.high])
    // Photographs and transparent artwork must retain their original pixels.
    let cleaned = thumbnail == nil ? stripShadow(bitmap, pixels: pixels) : bitmap
    guard let png = cleaned.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "FileIcon", code: 3)
    }
    return "data:image/png;base64," + png.base64EncodedString()
}

// macOS document icons (txt/pdf/generic) ship with a strong drop shadow baked
// into the artwork, which clashes with this app's flat icon style — but removing
// it entirely makes white pages blend into the background. The page body is
// opaque while the shadow is semi-transparent neutral gray, so: find the opaque
// content bbox, confirm there is a gray halo outside it, then recenter the
// content on a cleared canvas and repaint the halo at ~1/4 strength as a soft
// grounding shadow. Icons without a baked shadow pass through untouched.
func stripShadow(_ bitmap: NSBitmapImageRep, pixels: Int) -> NSBitmapImageRep {
    guard let data = bitmap.bitmapData else { return bitmap }
    let bpr = bitmap.bytesPerRow
    var minX = pixels, minY = pixels, maxX = -1, maxY = -1
    for y in 0..<pixels {
        let row = data + y * bpr
        for x in 0..<pixels {
            if row[x * 4 + 3] > 127 {
                if x < minX { minX = x }; if x > maxX { maxX = x }
                if y < minY { minY = y }; if y > maxY { maxY = y }
            }
        }
    }
    if maxX < 0 { return bitmap } // fully transparent, nothing to do
    var shadowPixels = 0
    for y in 0..<pixels {
        let row = data + y * bpr
        for x in 0..<pixels {
            if x >= minX && x <= maxX && y >= minY && y <= maxY { continue }
            let alpha = row[x * 4 + 3]
            guard alpha > 12 && alpha <= 127 else { continue }
            let r = Int(row[x * 4]), g = Int(row[x * 4 + 1]), b = Int(row[x * 4 + 2])
            if max(r, g, b) - min(r, g, b) <= 18 { shadowPixels += 1 }
        }
    }
    if shadowPixels < max(12, pixels * pixels / 300) { return bitmap } // no baked shadow
    guard let recomposed = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let target = recomposed.bitmapData else { return bitmap }
    recomposed.size = NSSize(width: pixels, height: pixels)
    // Recenter the content and soften the shadow via per-pixel math. The bitmap
    // is premultiplied, so a pixel's true darkness is max(r,g,b) relative to its
    // alpha: shadow pixels are dark for their alpha (black/gray at low opacity),
    // while the page's antialiased fringe is light for its alpha. Attenuate only
    // shadow-like pixels — wherever they sit, including the rounded-corner
    // cutouts inside the bbox rectangle. NSImage drawing is avoided on purpose:
    // its compositing turned black low-alpha corner shadows into dark specks.
    let w = maxX - minX + 1, h = maxY - minY + 1
    let dx = (pixels - w) / 2 - minX, dy = (pixels - h) / 2 - minY
    let obpr = recomposed.bytesPerRow
    for y in 0..<pixels {
        let ny = y + dy
        if ny < 0 || ny >= pixels { continue }
        let srow = data + y * bpr
        let drow = target + ny * obpr
        for x in 0..<pixels {
            let nx = x + dx
            if nx < 0 || nx >= pixels { continue }
            let s = srow + x * 4
            let d = drow + nx * 4
            let alpha = Int(s[3])
            let maxc = max(Int(s[0]), Int(s[1]), Int(s[2]))
            if alpha < 100 && maxc * 3 <= alpha * 2 {
                d[0] = s[0] / 4; d[1] = s[1] / 4; d[2] = s[2] / 4; d[3] = s[3] / 4
            } else {
                d[0] = s[0]; d[1] = s[1]; d[2] = s[2]; d[3] = s[3]
            }
        }
    }
    return recomposed
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
