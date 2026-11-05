import AppKit
import CoreImage
import Stitch

enum Tool: CaseIterable { case arrow, line, rect, blur }

/// One mark on the picture. Coordinates are image pixels with a top-left origin.
struct Annotation {
    var tool: Tool
    var start: CGPoint
    var end: CGPoint
    var width: CGFloat

    var rect: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    var isMeaningful: Bool {
        switch tool {
        case .arrow, .line: return hypot(end.x - start.x, end.y - start.y) >= 4
        case .rect, .blur: return rect.width >= 4 && rect.height >= 4
        }
    }

    /// Shift: lines snap to 45°, boxes become squares.
    static func constrained(start: CGPoint, end: CGPoint, tool: Tool) -> CGPoint {
        let dx = end.x - start.x, dy = end.y - start.y
        switch tool {
        case .arrow, .line:
            let len = hypot(dx, dy)
            let a = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
            return CGPoint(x: start.x + cos(a) * len, y: start.y + sin(a) * len)
        case .rect, .blur:
            let s = max(abs(dx), abs(dy))
            return CGPoint(x: start.x + (dx < 0 ? -s : s), y: start.y + (dy < 0 ? -s : s))
        }
    }
}

enum Renderer {
    static let red = CGColor(srgbRed: 1.0, green: 0.23, blue: 0.19, alpha: 1)
    private static let ci = CIContext(options: [.cacheIntermediates: false])

    /// Draws into a context whose user space is image pixels with a top-left origin (y down).
    static func draw(_ a: Annotation, in ctx: CGContext, blurred: CGImage?) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setStrokeColor(red)
        ctx.setFillColor(red)
        ctx.setLineWidth(a.width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        switch a.tool {
        case .line:
            ctx.move(to: a.start)
            ctx.addLine(to: a.end)
            ctx.strokePath()
        case .rect:
            let r = a.rect
            let rad = min(a.width, r.width / 2, r.height / 2)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil))
            ctx.strokePath()
        case .arrow:
            drawArrow(a, ctx)
        case .blur:
            if let b = blurred {
                let r = a.rect.integral.intersection(CGRect(x: 0, y: 0, width: b.width, height: b.height))
                if !r.isNull, r.width >= 1, r.height >= 1, let crop = b.cropping(to: r) {
                    drawImage(crop, in: r, ctx)
                }
            } else {
                ctx.setFillColor(CGColor(gray: 0.5, alpha: 0.85))
                ctx.fill(a.rect)
            }
        }
    }

    private static func drawArrow(_ a: Annotation, _ ctx: CGContext) {
        let dx = a.end.x - a.start.x, dy = a.end.y - a.start.y
        let len = hypot(dx, dy)
        guard len > 0.5 else { return }
        let ux = dx / len, uy = dy / len
        let w = a.width
        let head = min(len * 0.8, w * 4 + 10)
        let half = head * 0.5
        let base = CGPoint(x: a.end.x - ux * head, y: a.end.y - uy * head)
        ctx.move(to: a.start)
        ctx.addLine(to: CGPoint(x: base.x + ux * head * 0.3, y: base.y + uy * head * 0.3))
        ctx.strokePath()
        ctx.setLineWidth(max(1, w * 0.35))
        ctx.move(to: a.end)
        ctx.addLine(to: CGPoint(x: base.x - uy * half, y: base.y + ux * half))
        ctx.addLine(to: CGPoint(x: base.x + uy * half, y: base.y - ux * half))
        ctx.closePath()
        ctx.drawPath(using: .fillStroke)
    }

    /// Draws an image upright inside `r` in a top-left (flipped) context.
    static func drawImage(_ img: CGImage, in r: CGRect, _ ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: r.minX, y: r.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: r.width, height: r.height))
        ctx.restoreGState()
    }

    static func blurred(_ img: CGImage, sigma: CGFloat) -> CGImage? {
        let input = CIImage(cgImage: img)
        let out = input.clampedToExtent().applyingGaussianBlur(sigma: Double(sigma)).cropped(to: input.extent)
        return ci.createCGImage(out, from: input.extent, format: .BGRA8,
                                colorSpace: img.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB))
    }

    /// The final picture: `selection` (image pixels) of `base` with all marks burned in.
    static func export(base: CGImage, selection: CGRect, annotations: [Annotation], blurred: CGImage?) -> CGImage? {
        let r = selection.integral.intersection(CGRect(x: 0, y: 0, width: base.width, height: base.height))
        guard !r.isNull, r.width >= 1, r.height >= 1, let crop = base.cropping(to: r) else { return nil }
        let w = Int(r.width), h = Int(r.height)
        guard let ctx = Stitcher.context(w, h, base.colorSpace) else { return nil }
        ctx.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -r.minX, y: -r.minY)
        for a in annotations { draw(a, in: ctx, blurred: blurred) }
        return ctx.makeImage()
    }
}
