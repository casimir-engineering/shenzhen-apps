// Renders the approved Shenzhen Files macOS app-icon artwork at any size.
//
// The master fills its square canvas with a white-to-icy-blue gradient but has
// no pre-rounded corners. Current macOS supplies the final squircle mask; this
// keeps the artwork large without producing a nested icon enclosure.
//
//   swift make-logo.swift <out.png> <pixel-size>
import AppKit

guard CommandLine.arguments.count >= 3, let size = Int(CommandLine.arguments[2]) else {
    FileHandle.standardError.write("usage: make-logo.swift <out.png> <pixel-size>\n".data(using: .utf8)!)
    exit(2)
}

let outputPath = CommandLine.arguments[1]
let canvasSize = CGFloat(size)
let sourceURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("AppIcon-source-v7.png")

guard let source = NSImage(contentsOf: sourceURL) else {
    FileHandle.standardError.write("failed to load icon master at \(sourceURL.path)\n".data(using: .utf8)!)
    exit(3)
}

let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                              pixelsWide: size,
                              pixelsHigh: size,
                              bitsPerSample: 8,
                              samplesPerPixel: 4,
                              hasAlpha: true,
                              isPlanar: false,
                              colorSpaceName: .deviceRGB,
                              bytesPerRow: 0,
                              bitsPerPixel: 0)!

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSGraphicsContext.current?.imageInterpolation = .high
NSGraphicsContext.current?.shouldAntialias = true

let canvas = NSRect(x: 0, y: 0, width: canvasSize, height: canvasSize)
NSColor.clear.setFill()
canvas.fill()

source.draw(in: canvas,
            from: NSRect(origin: .zero, size: source.size),
            operation: .sourceOver,
            fraction: 1.0,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high])

NSGraphicsContext.restoreGraphicsState()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("failed to encode PNG\n".data(using: .utf8)!)
    exit(1)
}
try! png.write(to: URL(fileURLWithPath: outputPath))
