// Renders Resources/AppIcon.svg (the site's logo) into the macOS icon grid and writes Resources/AppIcon.icns.
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[1])
guard let logo = NSImage(contentsOf: root.appendingPathComponent("Resources/AppIcon.svg")) else { fatalError("cannot load AppIcon.svg") }
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func png(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // Apple's grid: an 824pt rounded square centred on a 1024pt canvas.
    let s = CGFloat(px) / 1024
    let rect = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    NSBezierPath(roundedRect: rect, xRadius: 185 * s, yRadius: 185 * s).addClip()
    logo.draw(in: rect)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try png(size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try png(size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let out = root.appendingPathComponent("Resources/AppIcon.icns").path
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out]
try p.run(); p.waitUntilExit()
print("Wrote \(out)")
