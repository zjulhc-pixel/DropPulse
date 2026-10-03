// Renders the app icon (Resources/AppIcon.icns: a frosted-glass tile on deep blue holding the
// "pd" monogram, a ring with two parallel slanted stems) and the menu bar template images
// (Resources/MenuBar*Template.pdf: the monogram alone, solid when connected, faint when not).
// Usage: swift scripts/make-icon.swift Resources [preview.png]
import AppKit

let resources = URL(filePath: CommandLine.arguments[1])
let set = URL(filePath: NSTemporaryDirectory()).appending(path: "AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ stops: [(CGFloat, CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.displayP3), colors: stops.map(\.1) as CFArray, locations: stops.map(\.0))!
}

/// The monogram in unit coordinates of the tile (y up), centred at (0.5, 0.5).
func monogram() -> CGPath {
    let center = CGPoint(x: 0.5, y: 0.5)
    let outer = 0.198, hole = 0.084, stem = 0.105, reach = 0.415
    let angle = 67.3 * Double.pi / 180
    let along = CGPoint(x: cos(angle), y: sin(angle)), side = CGPoint(x: along.y, y: -along.x)
    func stemPath(_ sign: Double) -> CGPath {
        // A rounded bar whose outer edge is tangent to the ring, running out to `reach`.
        let offset = sign * (outer - stem / 2)
        var t = CGAffineTransform(translationX: center.x + side.x * offset, y: center.y + side.y * offset)
        t = t.rotated(by: atan2(along.y, along.x) + (sign < 0 ? .pi : 0))
        return CGPath(roundedRect: CGRect(x: 0, y: -stem / 2, width: reach, height: stem),
                      cornerWidth: 0.014, cornerHeight: 0.014, transform: &t)
    }
    let ring = CGPath(ellipseIn: CGRect(x: center.x - outer, y: center.y - outer, width: 2 * outer, height: 2 * outer), transform: nil)
    let inner = CGPath(ellipseIn: CGRect(x: center.x - hole, y: center.y - hole, width: 2 * hole, height: 2 * hole), transform: nil)
    // Round the two inside corners where a stem leaves the ring: a small circle touches both
    // the ring and the stem's inner edge, and the sliver between it and the corner is filled.
    func fillet(_ sign: Double) -> CGPath {
        let f = 0.035, edge = outer - stem
        func at(_ a: Double, _ b: Double) -> CGPoint {
            CGPoint(x: center.x + sign * (a * along.x + b * side.x), y: center.y + sign * (a * along.y + b * side.y))
        }
        let b = edge - f, a = ((outer + f) * (outer + f) - b * b).squareRoot()
        let k = outer / (outer + f)
        let wedge = CGMutablePath()
        wedge.addLines(between: [at(k * a, k * b), at((outer * outer - edge * edge).squareRoot(), edge), at(a, edge)])
        wedge.closeSubpath()
        let disc = CGPath(ellipseIn: CGRect(x: at(a, b).x - f, y: at(a, b).y - f, width: 2 * f, height: 2 * f), transform: nil)
        return wedge.subtracting(disc)
    }
    let glyph = ring.union(stemPath(1)).union(stemPath(-1)).union(fillet(1)).union(fillet(-1)).subtracting(inner)
    // Boolean ops can leave hairline slivers at the seams; keep only real contours.
    var contours: [CGMutablePath] = []
    glyph.applyWithBlock { element in
        let p = element.pointee.points
        switch element.pointee.type {
        case .moveToPoint: contours.append(CGMutablePath()); contours[contours.count - 1].move(to: p[0])
        case .addLineToPoint: contours.last?.addLine(to: p[0])
        case .addQuadCurveToPoint: contours.last?.addQuadCurve(to: p[1], control: p[0])
        case .addCurveToPoint: contours.last?.addCurve(to: p[2], control1: p[0], control2: p[1])
        case .closeSubpath: contours.last?.closeSubpath()
        @unknown default: break
        }
    }
    let clean = CGMutablePath()
    contours.filter { max($0.boundingBox.width, $0.boundingBox.height) > 0.03 }.forEach { clean.addPath($0) }
    return clean
}

func render(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let cg = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    let s = CGFloat(px)
    // macOS icon grid: an 824/1024 tile, centred.
    let box = CGRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
    let tile = CGPath(roundedRect: box, cornerWidth: box.width * 0.225, cornerHeight: box.width * 0.225, transform: nil)
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: box.minX + x * box.width, y: box.minY + y * box.height) }

    // Drop shadow under the tile.
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: color(0x0A2A66, 0.35))
    cg.addPath(tile); cg.setFillColor(color(0x1A5DD3)); cg.fillPath()
    cg.restoreGState()

    // Deep blue, a touch lighter at the top so the glass reads as lit from above.
    cg.saveGState()
    cg.addPath(tile); cg.clip()
    cg.drawLinearGradient(gradient([(0, color(0x2F7BE6)), (0.55, color(0x1A5DD3)), (1, color(0x0F4AC4))]),
                          start: point(0.2, 1), end: point(0.8, 0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    cg.drawRadialGradient(gradient([(0, color(0x6FB8F5, 0.45)), (1, color(0x6FB8F5, 0))]),
                          startCenter: point(0.15, 0.4), startRadius: 0, endCenter: point(0.15, 0.4), endRadius: box.width * 0.45, options: [])
    // Frosted sheen: a soft white wash from the top.
    cg.drawLinearGradient(gradient([(0, color(0xFFFFFF, 0.22)), (0.45, color(0xFFFFFF, 0.05)), (1, color(0xFFFFFF, 0))]),
                          start: point(0.5, 1), end: point(0.5, 0), options: [])

    // The monogram: milky glass, brighter at the top, with a lit rim and a soft shadow.
    var toBox = CGAffineTransform(translationX: box.minX, y: box.minY).scaledBy(x: box.width, y: box.height)
    let glyph = monogram().copy(using: &toBox)!
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.03, color: color(0x0A3A8C, 0.35))
    cg.addPath(glyph); cg.setFillColor(color(0xFFFFFF, 0.5)); cg.fillPath()
    cg.restoreGState()
    cg.saveGState()
    cg.addPath(glyph); cg.clip()
    cg.drawLinearGradient(gradient([(0, color(0xFFFFFF, 0.97)), (0.5, color(0xE6ECFB, 0.88)), (1, color(0xB4BCEB, 0.82))]),
                          start: point(0.78, 0.8), end: point(0.25, 0.2), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    cg.restoreGState()
    cg.addPath(glyph); cg.setStrokeColor(color(0xFFFFFF, 0.85)); cg.setLineWidth(s * 0.004); cg.strokePath()

    // Glass edge: a bright hairline, strongest along the top.
    cg.saveGState()
    cg.addPath(tile); cg.setLineWidth(s * 0.006); cg.replacePathWithStrokedPath(); cg.clip()
    cg.drawLinearGradient(gradient([(0, color(0xFFFFFF, 0.95)), (0.5, color(0xFFFFFF, 0.35)), (1, color(0xFFFFFF, 0.6))]),
                          start: point(0.5, 1), end: point(0.5, 0), options: [])
    cg.restoreGState()
    return rep
}

for size in [16, 32, 128, 256, 512] {
    try render(size).representation(using: .png, properties: [:])!.write(to: set.appending(path: "icon_\(size)x\(size).png"))
    try render(size * 2).representation(using: .png, properties: [:])!.write(to: set.appending(path: "icon_\(size)x\(size)@2x.png"))
}
if CommandLine.arguments.count > 2 {
    try render(1024).representation(using: .png, properties: [:])!.write(to: URL(filePath: CommandLine.arguments[2]))
}
let task = Process()
task.executableURL = URL(filePath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", set.path, "-o", resources.appending(path: "AppIcon.icns").path]
try task.run()
task.waitUntilExit()

/// Menu bar: an 18 pt vector template, the monogram filling its height.
func menuBarIcon(_ name: String, alpha: CGFloat) {
    let size = CGFloat(18), glyph = monogram(), bounds = glyph.boundingBox
    let scale = (size - 1) / max(bounds.width, bounds.height)
    var fit = CGAffineTransform(translationX: size / 2, y: size / 2)
        .scaledBy(x: scale, y: scale).translatedBy(x: -bounds.midX, y: -bounds.midY)
    var page = CGRect(x: 0, y: 0, width: size, height: size)
    let pdf = CGContext(resources.appending(path: name) as CFURL, mediaBox: &page, nil)!
    pdf.beginPDFPage(nil)
    pdf.addPath(glyph.copy(using: &fit)!)
    pdf.setFillColor(CGColor(gray: 0, alpha: alpha))
    pdf.fillPath()
    pdf.endPDFPage()
    pdf.closePDF()
}
menuBarIcon("MenuBarTemplate.pdf", alpha: 1)
menuBarIcon("MenuBarOffTemplate.pdf", alpha: 0.45)
