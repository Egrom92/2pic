// Draws the 2pic icon (dark rounded square, viewfinder corners, red arrow) into an .iconset.
import AppKit
let out = CommandLine.arguments[1]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.1, box = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let bg = NSBezierPath(roundedRect: box, xRadius: box.width * 0.22, yRadius: box.width * 0.22)
    NSGradient(starting: NSColor(white: 0.22, alpha: 1), ending: NSColor(white: 0.08, alpha: 1))!.draw(in: bg, angle: -90)
    let m = box.width * 0.2, l = box.width * 0.17
    let f = box.insetBy(dx: m, dy: m)
    let corners = NSBezierPath()
    for (p, dx, dy) in [(NSPoint(x: f.minX, y: f.maxY), 1.0, -1.0), (NSPoint(x: f.maxX, y: f.maxY), -1.0, -1.0),
                        (NSPoint(x: f.minX, y: f.minY), 1.0, 1.0), (NSPoint(x: f.maxX, y: f.minY), -1.0, 1.0)] {
        corners.move(to: NSPoint(x: p.x, y: p.y + dy * l)); corners.line(to: p); corners.line(to: NSPoint(x: p.x + dx * l, y: p.y))
    }
    corners.lineWidth = box.width * 0.055; corners.lineCapStyle = .round; corners.lineJoinStyle = .round
    NSColor(white: 0.96, alpha: 1).setStroke(); corners.stroke()
    let red = NSColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 1)
    let a0 = NSPoint(x: f.minX + f.width * 0.22, y: f.minY + f.height * 0.22), a1 = NSPoint(x: f.maxX - f.width * 0.2, y: f.maxY - f.height * 0.2)
    let shaft = NSBezierPath(); shaft.move(to: a0); shaft.line(to: NSPoint(x: a1.x - f.width * 0.14, y: a1.y - f.height * 0.14))
    shaft.lineWidth = box.width * 0.06; shaft.lineCapStyle = .round; red.setStroke(); shaft.stroke()
    let h = f.width * 0.3
    let head = NSBezierPath(); head.move(to: a1); head.line(to: NSPoint(x: a1.x - h, y: a1.y - h * 0.25)); head.line(to: NSPoint(x: a1.x - h * 0.25, y: a1.y - h)); head.close()
    red.setFill(); head.fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
