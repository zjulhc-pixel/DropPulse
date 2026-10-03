// Renders the app icon (a white drop on a blue squircle) into an .icns file.
import AppKit

let out = CommandLine.arguments[1]
let set = URL(filePath: NSTemporaryDirectory()).appending(path: "AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px), inset = s * 0.1, box = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = NSBezierPath(roundedRect: box, xRadius: box.width * 0.225, yRadius: box.width * 0.225)
    NSGradient(colors: [NSColor(red: 0.36, green: 0.72, blue: 1, alpha: 1), NSColor(red: 0.0, green: 0.38, blue: 0.9, alpha: 1)])!
        .draw(in: shape, angle: -90)
    NSColor.white.withAlphaComponent(0.35).setStroke()
    shape.lineWidth = s * 0.006
    shape.stroke()
    let config = NSImage.SymbolConfiguration(pointSize: s * 0.42, weight: .medium)
        .applying(.init(paletteColors: [.white]))
    let drop = NSImage(systemSymbolName: "drop.fill", accessibilityDescription: nil)!.withSymbolConfiguration(config)!
    drop.draw(in: NSRect(x: (s - drop.size.width) / 2, y: (s - drop.size.height) / 2,
                         width: drop.size.width, height: drop.size.height))
    NSGraphicsContext.current = nil
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: set.appending(path: "icon_\(size)x\(size).png"))
    try render(size * 2).write(to: set.appending(path: "icon_\(size)x\(size)@2x.png"))
}
let task = Process()
task.executableURL = URL(filePath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", set.path, "-o", out]
try task.run()
task.waitUntilExit()
