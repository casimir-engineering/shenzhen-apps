// Generates the Shenzhen PDF installer DMG background: a light gradient with a
// single accent arrow pointing from the app icon (left) to the Applications
// drop target (right). Renders both 1x and @2x PNGs.
//
//   swift dmg-background.swift out.png out@2x.png
//
// The DMG window is 600x400 pt; the app icon sits at (150,200) and the
// Applications link at (450,200), so the arrow spans the gap at the vertical
// center (flip-independent).
import AppKit

func render(scale: CGFloat, to path: String) {
    let W = 600 * scale
    let H = 400 * scale
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                               pixelsWide: Int(W), pixelsHigh: Int(H),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Soft vertical gradient backdrop.
    let backdrop = NSGradient(starting: NSColor(calibratedWhite: 0.985, alpha: 1.0),
                              ending: NSColor(calibratedWhite: 0.935, alpha: 1.0))!
    backdrop.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)

    // Accent arrow, vertically centered.
    let yMid = H / 2
    let x1 = 232 * scale          // shaft start (right edge of app icon ≈ 214)
    let x2 = 368 * scale          // arrow tip (left edge of Applications ≈ 386)
    let shaftH = 12 * scale
    let headW = 38 * scale
    let headH = 34 * scale
    let accent = NSColor(calibratedRed: 0.30, green: 0.40, blue: 0.95, alpha: 1.0)
    accent.setFill()

    let shaft = NSBezierPath(roundedRect: NSRect(x: x1, y: yMid - shaftH / 2,
                                                 width: (x2 - headW) - x1, height: shaftH),
                             xRadius: shaftH / 2, yRadius: shaftH / 2)
    shaft.fill()

    let head = NSBezierPath()
    head.move(to: NSPoint(x: x2, y: yMid))
    head.line(to: NSPoint(x: x2 - headW, y: yMid + headH / 2))
    head.line(to: NSPoint(x: x2 - headW, y: yMid - headH / 2))
    head.close()
    head.fill()

    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("failed to encode PNG\n".data(using: .utf8)!)
        exit(1)
    }
    try! data.write(to: URL(fileURLWithPath: path))
}

guard CommandLine.arguments.count >= 3 else {
    FileHandle.standardError.write("usage: dmg-background.swift <out.png> <out@2x.png>\n".data(using: .utf8)!)
    exit(2)
}
render(scale: 1, to: CommandLine.arguments[1])
render(scale: 2, to: CommandLine.arguments[2])
