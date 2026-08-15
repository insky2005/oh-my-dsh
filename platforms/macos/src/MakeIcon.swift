//
//  MakeIcon — renders the app icon for the DeepSeek Harness shell.
//
//  Usage: MakeIcon <output.iconset-dir>
//  Renders PNGs at 16…1024 px (all @1x/@2x sizes) into the iconset dir;
//  the build script then runs `iconutil -c icns`.
//

import AppKit
import Foundation

func render(px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: px,
        pixelsHigh: px,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: px, height: px)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)

    // Rounded-rect backdrop with a deep blue gradient.
    let rect = NSRect(x: 0, y: 0, width: s, height: s)
    let corner = s * 0.2237
    let backdrop = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.32, green: 0.44, blue: 1.00, alpha: 1),
        NSColor(calibratedRed: 0.10, green: 0.16, blue: 0.55, alpha: 1),
    ])!
    gradient.draw(in: backdrop, angle: -70)

    // A subtle top-left sheen.
    let sheen = NSBezierPath(roundedRect: NSRect(x: 0, y: s * 0.55, width: s, height: s * 0.45), xRadius: corner, yRadius: 0)
    NSColor(white: 1, alpha: 0.08).setFill()
    sheen.fill()

    // Harness ring behind the letter.
    let ringRect = NSRect(x: s * 0.17, y: s * 0.17, width: s * 0.66, height: s * 0.66)
    let ring = NSBezierPath(ovalIn: ringRect)
    ring.lineWidth = s * 0.045
    NSColor(white: 1, alpha: 0.92).setStroke()
    ring.stroke()

    // Bold "D".
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: s * 0.52, weight: .bold),
        .foregroundColor: NSColor.white,
    ]
    let letter = NSAttributedString(string: "D", attributes: attrs)
    let ls = letter.size()
    letter.draw(at: NSPoint(x: (s - ls.width) / 2, y: (s - ls.height) / 2))

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func main() {
    let args = CommandLine.arguments
    guard args.count >= 2 else {
        FileHandle.standardError.write(Data("usage: MakeIcon <iconset-dir>\n".utf8))
        exit(2)
    }
    let outDir = args[1]
    try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

    let entries: [(name: String, px: Int)] = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024),
    ]
    for e in entries {
        let rep = render(px: e.px)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("failed to encode \(e.name)\n".utf8))
            exit(1)
        }
        let path = outDir + "/" + e.name
        do {
            try data.write(to: URL(fileURLWithPath: path))
        } catch {
            FileHandle.standardError.write(Data("failed to write \(path): \(error)\n".utf8))
            exit(1)
        }
    }
    print("icons written to \(outDir)")
}

main()
