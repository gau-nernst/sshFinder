// Draws the app icon: a folder with a shell prompt on a dark blue-teal tile.
// Usage: swift scripts/make-icon.swift <out.icns> (bundle.sh runs it)
import AppKit

let out = CommandLine.arguments[1]
let size: CGFloat = 1024

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// Apple's icon grid: an 824 pt tile centered on the 1024 canvas.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
NSGradient(colors: [NSColor(srgbRed: 0.05, green: 0.16, blue: 0.32, alpha: 1),
                    NSColor(srgbRed: 0.02, green: 0.48, blue: 0.55, alpha: 1)])!
    .draw(in: shape, angle: -60)

// White folder, from SF Symbols.
let config = NSImage.SymbolConfiguration(pointSize: 470, weight: .regular)
let folder = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil)!
    .withSymbolConfiguration(config)!
let white = NSImage(size: folder.size)
white.lockFocus()
folder.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
NSColor.white.set()
NSRect(origin: .zero, size: folder.size).fill(using: .sourceAtop)
white.unlockFocus()
let folderRect = NSRect(x: (size - white.size.width) / 2, y: (size - white.size.height) / 2 - 20,
                        width: white.size.width, height: white.size.height)
white.draw(in: folderRect)

// ">_" prompt inside the folder, in the tile's dark blue.
let prompt = NSAttributedString(string: ">_", attributes: [
    .font: NSFont.monospacedSystemFont(ofSize: 210, weight: .heavy),
    .foregroundColor: NSColor(srgbRed: 0.04, green: 0.24, blue: 0.40, alpha: 1),
])
let textSize = prompt.size()
prompt.draw(at: NSPoint(x: (size - textSize.width) / 2, y: folderRect.midY - textSize.height / 2 - 30))
image.unlockFocus()

// Write every size iconutil expects, then pack them into an .icns.
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = points * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try! rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", out]
try! iconutil.run()
iconutil.waitUntilExit()
print("Wrote \(out)")
