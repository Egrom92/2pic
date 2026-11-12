import AppKit
import CoreImage
import Stitch

enum Tool: CaseIterable { case arrow, line, rect, text, counter, blur }

/// Colors and sizes offered for marks. Sizes are in points; marks themselves store image pixels.
enum MarkStyle {
    static let colors: [CGColor] = [
        CGColor(srgbRed: 1.00, green: 0.23, blue: 0.19, alpha: 1),   // red
        CGColor(srgbRed: 1.00, green: 0.58, blue: 0.00, alpha: 1),   // orange
        CGColor(srgbRed: 1.00, green: 0.80, blue: 0.00, alpha: 1),   // yellow
        CGColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1),   // green
        CGColor(srgbRed: 0.00, green: 0.48, blue: 1.00, alpha: 1),   // blue
        CGColor(srgbRed: 0.69, green: 0.32, blue: 0.87, alpha: 1),   // purple
        CGColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 1),   // white
        CGColor(srgbRed: 0.10, green: 0.10, blue: 0.10, alpha: 1),   // black
    ]
    static let colorNames = ["Красный", "Оранжевый", "Жёлтый", "Зелёный", "Синий", "Фиолетовый", "Белый", "Чёрный"]
    static let sizeNames = ["Тонко", "Средне", "Толсто"]
    static let lineWidths: [CGFloat] = [2, 3, 5]          // lines, arrows, frames
    static let fontSizes: [CGFloat] = [14, 18, 26]        // text
    static let counterSizes: [CGFloat] = [20, 24, 32]     // diameter of a numbered circle

    /// Light colors (yellow, white…) get dark details on top, dark colors get light ones.
    static func isLight(_ c: CGColor) -> Bool {
        guard let rgb = c.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?
                .components, rgb.count >= 3 else { return false }
        return 0.299 * rgb[0] + 0.587 * rgb[1] + 0.114 * rgb[2] > 0.6
    }
}

/// One mark on the picture. Coordinates are image pixels with a top-left origin.
struct Annotation {
    var tool: Tool
    var start: CGPoint        // text: top-left of the text; counter: centre of the circle
    var end: CGPoint
    var width: CGFloat        // line width
    var color: CGColor = MarkStyle.colors[0]
    var size: CGFloat = 0     // text: font size; counter: circle diameter
    var text = ""             // .text
    var number = 0            // .counter

    var rect: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    var isMeaningful: Bool {
        switch tool {
        case .arrow, .line: return hypot(end.x - start.x, end.y - start.y) >= 4
        case .rect, .blur: return rect.width >= 4 && rect.height >= 4
        case .text: return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .counter: return true
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
        case .text, .counter:
            return end
        }
    }
}

enum Renderer {
    static let red = MarkStyle.colors[0]
    private static let ci = CIContext(options: [.cacheIntermediates: false])

    /// Draws into a context whose user space is image pixels with a top-left origin (y down).
    static func draw(_ a: Annotation, in ctx: CGContext, blurred: CGImage?) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setStrokeColor(a.color)
        ctx.setFillColor(a.color)
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
        case .text:
            withAppKit(ctx) { NSAttributedString(string: a.text, attributes: textAttributes(a)).draw(at: a.start) }
        case .counter:
            drawCounter(a, ctx)
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

    // MARK: text and numbered circles

    static func textFont(_ size: CGFloat) -> NSFont { .systemFont(ofSize: size, weight: .semibold) }

    /// Text in the mark color with a soft halo, so it stays readable on any background.
    static func textAttributes(_ a: Annotation) -> [NSAttributedString.Key: Any] {
        let halo = NSShadow()
        halo.shadowColor = MarkStyle.isLight(a.color) ? NSColor(white: 0, alpha: 0.6) : NSColor(white: 1, alpha: 0.75)
        halo.shadowBlurRadius = max(1.5, a.size * 0.1)
        halo.shadowOffset = .zero
        return [.font: textFont(a.size), .foregroundColor: NSColor(cgColor: a.color) ?? .systemRed, .shadow: halo]
    }

    /// The area a text mark covers (for clicking on it to edit), in image pixels.
    static func textBounds(_ a: Annotation) -> CGRect {
        CGRect(origin: a.start, size: NSAttributedString(string: a.text, attributes: textAttributes(a)).size())
    }

    private static func drawCounter(_ a: Annotation, _ ctx: CGContext) {
        let d = a.size
        let circle = CGRect(x: a.start.x - d / 2, y: a.start.y - d / 2, width: d, height: d)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: max(1, d * 0.12), color: CGColor(gray: 0, alpha: 0.35))
        ctx.fillEllipse(in: circle)
        ctx.restoreGState()
        let font = NSFont.monospacedDigitSystemFont(ofSize: (d * (a.number >= 10 ? 0.46 : 0.56)).rounded(), weight: .bold)
        let s = NSAttributedString(string: "\(a.number)", attributes: [
            .font: font, .foregroundColor: MarkStyle.isLight(a.color) ? NSColor.black : NSColor.white])
        // Centre the digits' cap height on the circle (the line box would sit too low).
        let w = s.size().width
        let top = a.start.y + font.capHeight / 2 - font.ascender
        withAppKit(ctx) { s.draw(at: CGPoint(x: a.start.x - w / 2, y: top)) }
    }

    /// Runs AppKit text drawing on a top-left (flipped) CGContext.
    private static func withAppKit(_ ctx: CGContext, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        body()
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: images

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
