// Generates the Shenzhen Files installer DMG background: a neutral gradient
// with the Shenzhen Files logo mark, a "Shenzhen Files" wordmark, and a single
// accent arrow pointing from the app icon (left) to the Applications drop
// target (right). Renders both 1x and @2x PNGs.
//
//   swift dmg-background.swift dmg-background.png dmg-background@2x.png [logo.png]
//
// The DMG window is 600x400 pt; the app icon sits at (150,200) and the
// Applications link at (450,200), so the arrow spans the gap at the vertical
// center (flip-independent). Forked from shenzhen-pdf's generator.
//
// The logo is the mark rendered by make-logo.swift (via make-icon.sh). It
// defaults to dmg-logo.png beside this script; pass an explicit path as the
// optional third argument to override.
import AppKit

// Resolve the logo once (shared across the 1x/2x renders). Missing logo is a
// hard error: the whole point of this pass is to ship the official artwork.
func loadLogo() -> NSImage? {
    let explicit = CommandLine.arguments.count >= 4 ? CommandLine.arguments[3] : nil
    let defaultPath = (URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("dmg-logo.png")).path
    let logoPath = explicit ?? defaultPath
    guard FileManager.default.fileExists(atPath: logoPath),
          let image = NSImage(contentsOfFile: logoPath) else {
        FileHandle.standardError.write("error: logo not found at \(logoPath)\n".data(using: .utf8)!)
        exit(3)
    }
    return image
}

let logo = loadLogo()

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

    // Soft vertical gradient backdrop, slightly cool to echo the Shenzhen blue.
    let backdrop = NSGradient(starting: NSColor(calibratedRed: 0.975, green: 0.980, blue: 0.990, alpha: 1.0),
                              ending: NSColor(calibratedRed: 0.920, green: 0.930, blue: 0.950, alpha: 1.0))!
    backdrop.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -90)

    // Shenzhen blue accent (#005C9C, the 深圳 mark color).
    let accent = NSColor(calibratedRed: 0.0, green: 0.361, blue: 0.612, alpha: 1.0)

    // Shenzhen Files logo mark, centered in the top band (above the icon row,
    // which is vertically centered at y=200 with 128 pt icons). Drawn with a
    // soft shadow so it reads on the light gradient.
    let logoSize = 68 * scale
    let logoX = (W - logoSize) / 2
    let logoY = H - 20 * scale - logoSize      // 20 pt top margin
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(calibratedWhite: 0.0, alpha: 0.18)
    shadow.shadowOffset = NSSize(width: 0, height: -1 * scale)
    shadow.shadowBlurRadius = 4 * scale
    shadow.set()
    logo?.draw(in: NSRect(x: logoX, y: logoY, width: logoSize, height: logoSize),
               from: .zero, operation: .sourceOver, fraction: 1.0)
    NSGraphicsContext.restoreGraphicsState()

    // Wordmark, centered just below the logo (origin is bottom-left).
    let title = "Shenzhen Files" as NSString
    let titleAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 30 * scale, weight: .semibold),
        .foregroundColor: NSColor(calibratedWhite: 0.20, alpha: 1.0),
        .kern: 0.5 * scale,
    ]
    let titleSize = title.size(withAttributes: titleAttrs)
    let titleY = logoY - 34 * scale
    title.draw(at: NSPoint(x: (W - titleSize.width) / 2, y: titleY),
               withAttributes: titleAttrs)

    let subtitle = "Drag to Applications to install" as NSString
    let subtitleAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13 * scale, weight: .regular),
        .foregroundColor: NSColor(calibratedWhite: 0.45, alpha: 1.0),
    ]
    let subtitleSize = subtitle.size(withAttributes: subtitleAttrs)
    subtitle.draw(at: NSPoint(x: (W - subtitleSize.width) / 2, y: titleY - 22 * scale),
                  withAttributes: subtitleAttrs)

    // Accent arrow, vertically centered between the two icon slots.
    let yMid = H / 2
    let x1 = 232 * scale          // shaft start (right edge of app icon ≈ 214)
    let x2 = 368 * scale          // arrow tip (left edge of Applications ≈ 386)
    let shaftH = 12 * scale
    let headW = 38 * scale
    let headH = 34 * scale
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
