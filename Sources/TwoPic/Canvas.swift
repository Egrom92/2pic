import AppKit
import Carbon.HIToolbox

enum OverlayMode { case capture, scrollSelect, editResult }

enum Outcome {
    case cancel, copy, save
    case scroll(CGRect)   // chosen region, screen-local top-left points
}

private enum Handle: CaseIterable {
    case tl, t, tr, r, br, b, bl, l
    func point(_ s: CGRect) -> CGPoint {
        switch self {
        case .tl: return CGPoint(x: s.minX, y: s.minY)
        case .t: return CGPoint(x: s.midX, y: s.minY)
        case .tr: return CGPoint(x: s.maxX, y: s.minY)
        case .r: return CGPoint(x: s.maxX, y: s.midY)
        case .br: return CGPoint(x: s.maxX, y: s.maxY)
        case .b: return CGPoint(x: s.midX, y: s.maxY)
        case .bl: return CGPoint(x: s.minX, y: s.maxY)
        case .l: return CGPoint(x: s.minX, y: s.midY)
        }
    }
}

private enum Drag {
    case none
    case select(CGPoint)
    case move(CGPoint, CGRect)
    case resize(Handle, CGRect)
    case draw
}

/// Shows the base image, the dimmed surroundings, the selection and its marks.
/// View coordinates are top-left points; selection and marks are stored in image pixels.
final class CanvasView: NSView {
    let mode: OverlayMode
    let base: CGImage
    let pxPerPt: CGFloat
    private(set) var imageRect: CGRect
    var scale: CGFloat { imageRect.width / CGFloat(base.width) }   // view points per image pixel
    var imageBounds: CGRect { CGRect(x: 0, y: 0, width: base.width, height: base.height) }

    private(set) var selection: CGRect?
    private(set) var annotations: [Annotation] = []
    private(set) var current: Annotation?
    private(set) var blurred: CGImage?
    private var tool: Tool?
    private let windowRects: [CGRect]
    private var hover: CGRect?
    private var drag: Drag = .none
    private var dragging = false
    private var downPoint = CGPoint.zero
    var onFinish: ((Outcome) -> Void)?

    private let imageView: ImageLayerView
    private let marksView = MarksView()
    private let chrome = ChromeView()
    private var toolbar: ToolbarView!
    private let sizeLabel = PillLabel()
    private var hint: PillLabel?

    private let topMargin: CGFloat = 36, bottomMargin: CGFloat = 64

    init(frame: CGRect, base: CGImage, pxPerPt: CGFloat, mode: OverlayMode, windows: [CGRect]) {
        self.mode = mode
        self.base = base
        self.pxPerPt = pxPerPt
        self.windowRects = windows
        if mode == .editResult {
            let availW = frame.width - 80, availH = frame.height - topMargin - bottomMargin
            let s = min(1 / pxPerPt, availW / CGFloat(base.width))
            let w = CGFloat(base.width) * s, h = CGFloat(base.height) * s
            let y = h < availH ? topMargin + (availH - h) / 2 : topMargin
            imageRect = CGRect(x: ((frame.width - w) / 2).rounded(), y: y.rounded(), width: w, height: h)
        } else {
            imageRect = CGRect(origin: .zero, size: frame.size)
        }
        imageView = ImageLayerView(image: base)
        super.init(frame: frame)
        wantsLayer = true
        if mode == .editResult {
            layer?.backgroundColor = NSColor(white: 0, alpha: 0.55).cgColor
            selection = imageBounds
        }
        marksView.canvas = self
        toolbar = ToolbarView(onTool: { [weak self] t in self?.toggle(t) },
                              onUndo: { [weak self] in self?.undo() },
                              onSave: { [weak self] in self?.onFinish?(.save) },
                              onCancel: { [weak self] in self?.onFinish?(.cancel) },
                              onCopy: { [weak self] in self?.onFinish?(.copy) })
        for v in [imageView, marksView, chrome, toolbar!, sizeLabel] as [NSView] { addSubview(v) }
        chrome.frame = bounds
        sizeLabel.isHidden = true
        if mode == .scrollSelect {
            let h = PillLabel(fontSize: 13)
            h.text = "Выделите область или кликните по окну — начнётся прокрутка.  Esc — отмена"
            h.setFrameOrigin(CGPoint(x: ((bounds.width - h.frame.width) / 2).rounded(), y: 40))
            addSubview(h)
            hint = h
        }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate],
                                       owner: self))
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: geometry

    func toView(_ r: CGRect) -> CGRect {
        CGRect(x: imageRect.minX + r.minX * scale, y: imageRect.minY + r.minY * scale,
               width: r.width * scale, height: r.height * scale)
    }
    func toImage(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - imageRect.minX) / scale, y: (p.y - imageRect.minY) / scale)
    }
    private func clampToImage(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(0, p.x), imageBounds.width), y: min(max(0, p.y), imageBounds.height))
    }
    private func pixelRect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        let p = clampToImage(a), q = clampToImage(b)
        let x0 = min(p.x, q.x).rounded(), y0 = min(p.y, q.y).rounded()
        let x1 = max(p.x, q.x).rounded(), y1 = max(p.y, q.y).rounded()
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
    private func location(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }

    private var lineWidth: CGFloat { 3 * pxPerPt }
    private var isEditing: Bool { selection != nil && mode != .scrollSelect }

    private func handle(at p: CGPoint, in sv: CGRect) -> Handle? {
        for h in [Handle.tl, .tr, .br, .bl] where hypot(h.point(sv).x - p.x, h.point(sv).y - p.y) <= 9 { return h }
        let e: CGFloat = 5
        let inX = p.x > sv.minX && p.x < sv.maxX, inY = p.y > sv.minY && p.y < sv.maxY
        if inX && abs(p.y - sv.minY) <= e { return .t }
        if inX && abs(p.y - sv.maxY) <= e { return .b }
        if inY && abs(p.x - sv.minX) <= e { return .l }
        if inY && abs(p.x - sv.maxX) <= e { return .r }
        return nil
    }

    // MARK: drawing state → views

    func refresh() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageView.frame = imageRect
        let sv = selection.map(toView)
        let hv = selection == nil ? hover.map(toView) : nil
        var dragActive = false
        if case .select = drag, dragging { dragActive = true }
        if case .resize = drag { dragActive = true }
        chrome.update(hole: sv ?? hv,
                      selection: sv,
                      hover: hv,
                      handles: (sv != nil && isEditing) ? Handle.allCases.map { $0.point(sv!) } : [])
        if let sv {
            let vis = sv.intersection(bounds)
            marksView.isHidden = vis.isNull
            if !vis.isNull { marksView.frame = vis; marksView.needsDisplay = true }
        } else {
            marksView.isHidden = true
        }
        toolbar.isHidden = !(isEditing && !dragActive)
        if !toolbar.isHidden, let sv { placeToolbar(sv) }
        if let sel = selection, let sv, dragActive || mode == .scrollSelect {
            sizeLabel.text = "\(Int(sel.width)) × \(Int(sel.height))"
            let y = sv.minY - sizeLabel.frame.height - 6
            sizeLabel.setFrameOrigin(CGPoint(x: max(4, sv.minX), y: y >= 2 ? y : sv.minY + 6))
            sizeLabel.isHidden = false
        } else {
            sizeLabel.isHidden = true
        }
        CATransaction.commit()
    }

    private func placeToolbar(_ sv: CGRect) {
        let s = toolbar.frame.size
        let vis = sv.intersection(bounds)
        guard !vis.isNull else { return }
        var x = vis.maxX - s.width
        var y = vis.maxY + 8
        if y + s.height > bounds.height - 6 {
            let above = vis.minY - 8 - s.height
            if above >= 6 { y = above } else { y = vis.maxY - s.height - 10; x -= 10 }
        }
        x = min(max(6, x), bounds.width - s.width - 6)
        toolbar.setFrameOrigin(CGPoint(x: x.rounded(), y: y.rounded()))
    }

    // MARK: actions

    func toggle(_ t: Tool) {
        tool = (tool == t) ? nil : t
        toolbar.show(tool: tool)
        if tool == .blur { prepareBlur() }
    }

    func undo() {
        if !annotations.isEmpty { annotations.removeLast(); refresh() }
    }

    private func prepareBlur() {
        if blurred == nil { blurred = Renderer.blurred(base, sigma: 6 * pxPerPt) }
    }

    /// The final image: selection (or hovered window, or whole image) with marks.
    func render() -> CGImage? {
        let sel = selection ?? hover ?? imageBounds
        if annotations.contains(where: { $0.tool == .blur }) { prepareBlur() }
        return Renderer.export(base: base, selection: sel, annotations: annotations, blurred: blurred)
    }

    /// For self-tests.
    func debugSet(selection: CGRect, annotations: [Annotation], tool: Tool?) {
        self.selection = selection
        self.annotations = annotations
        if let tool { toggle(tool) }
        if annotations.contains(where: { $0.tool == .blur }) { prepareBlur() }
        refresh()
    }

    // MARK: mouse

    override func mouseDown(with e: NSEvent) {
        let p = location(e)
        downPoint = p
        dragging = false
        guard isEditing, let sel = selection else { drag = .select(p); return }
        let sv = toView(sel)
        if e.clickCount == 2, tool == nil, sv.contains(p) { onFinish?(.copy); return }
        if let h = handle(at: p, in: sv) { drag = .resize(h, sel); return }
        if sv.contains(p) {
            if let t = tool {
                if t == .blur { prepareBlur() }
                let ip = toImage(p)
                current = Annotation(tool: t, start: ip, end: ip, width: lineWidth)
                drag = .draw
            } else {
                drag = .move(p, sel)
                NSCursor.closedHand.set()
            }
            return
        }
        drag = (mode == .editResult && !imageRect.contains(p)) ? .none : .select(p)
    }

    override func mouseDragged(with e: NSEvent) {
        let p = location(e)
        if !dragging {
            if hypot(p.x - downPoint.x, p.y - downPoint.y) < 3 { return }
            dragging = true
        }
        switch drag {
        case .select(let s):
            hover = nil
            selection = pixelRect(toImage(s), toImage(p))
        case .move(let s, let orig):
            var r = orig.offsetBy(dx: ((p.x - s.x) / scale).rounded(), dy: ((p.y - s.y) / scale).rounded())
            r.origin.x = min(max(0, r.minX), imageBounds.width - r.width)
            r.origin.y = min(max(0, r.minY), imageBounds.height - r.height)
            selection = r
        case .resize(let h, let o):
            let q = toImage(p)
            var x0 = o.minX, y0 = o.minY, x1 = o.maxX, y1 = o.maxY
            switch h {
            case .tl: x0 = q.x; y0 = q.y
            case .t: y0 = q.y
            case .tr: x1 = q.x; y0 = q.y
            case .r: x1 = q.x
            case .br: x1 = q.x; y1 = q.y
            case .b: y1 = q.y
            case .bl: x0 = q.x; y1 = q.y
            case .l: x0 = q.x
            }
            selection = pixelRect(CGPoint(x: x0, y: y0), CGPoint(x: x1, y: y1))
        case .draw:
            guard var c = current else { break }
            var ip = toImage(p)
            if e.modifierFlags.contains(.shift) { ip = Annotation.constrained(start: c.start, end: ip, tool: c.tool) }
            c.end = ip
            current = c
        case .none:
            return
        }
        refresh()
    }

    override func mouseUp(with e: NSEvent) {
        defer { drag = .none; dragging = false; refresh(); updateCursor(location(e)) }
        switch drag {
        case .select:
            if !dragging {
                guard selection == nil else { return }   // stray click outside: keep the selection
                selection = hover ?? imageBounds          // click: the window under the cursor, or the whole screen
            }
            guard let sel = selection, sel.width >= 6, sel.height >= 6 else {
                if mode != .editResult { selection = nil }
                return
            }
            hover = nil
            if mode == .scrollSelect {
                let r = toView(sel)
                drag = .none
                onFinish?(.scroll(r))
            }
        case .draw:
            if let c = current, c.isMeaningful { annotations.append(c) }
            current = nil
        default:
            break
        }
    }

    override func rightMouseDown(with event: NSEvent) { onFinish?(.cancel) }

    override func mouseMoved(with e: NSEvent) {
        let p = location(e)
        if selection == nil && mode != .editResult {
            let ip = toImage(p)
            let h = windowRects.first { $0.contains(ip) }
            if h != hover { hover = h; refresh() }
        }
        updateCursor(p)
    }

    override func cursorUpdate(with event: NSEvent) { updateCursor(location(event)) }

    private func updateCursor(_ p: CGPoint) {
        if !toolbar.isHidden && toolbar.frame.contains(p) { NSCursor.arrow.set(); return }
        guard isEditing, let sel = selection else { NSCursor.crosshair.set(); return }
        let sv = toView(sel)
        if let h = handle(at: p, in: sv) {
            switch h {
            case .t, .b: NSCursor.resizeUpDown.set()
            case .l, .r: NSCursor.resizeLeftRight.set()
            default: NSCursor.crosshair.set()
            }
            return
        }
        if sv.contains(p) && tool == nil { NSCursor.openHand.set(); return }
        NSCursor.crosshair.set()
    }

    override func scrollWheel(with e: NSEvent) {
        guard mode == .editResult, imageRect.height > bounds.height - topMargin - bottomMargin else { return }
        var dy = e.scrollingDeltaY
        if !e.hasPreciseScrollingDeltas { dy *= 14 }
        imageRect.origin.y = min(topMargin, max(bounds.height - bottomMargin - imageRect.height, imageRect.origin.y + dy))
        refresh()
    }

    // MARK: keyboard (by key code, so it works in any keyboard layout)

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard e.modifierFlags.contains(.command) else { return false }
        return handleKey(e)
    }

    override func keyDown(with e: NSEvent) {
        if !handleKey(e) { super.keyDown(with: e) }
    }

    private func handleKey(_ e: NSEvent) -> Bool {
        let cmd = e.modifierFlags.contains(.command)
        switch Int(e.keyCode) {
        case kVK_Escape:
            onFinish?(.cancel)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if mode != .scrollSelect { onFinish?(.copy) }
        case kVK_ANSI_C where cmd:
            if mode != .scrollSelect { onFinish?(.copy) }
        case kVK_ANSI_S where cmd:
            if mode != .scrollSelect { onFinish?(.save) }
        case kVK_ANSI_Z where cmd:
            undo()
        case kVK_ANSI_A where !cmd && isEditing: toggle(.arrow)
        case kVK_ANSI_L where !cmd && isEditing: toggle(.line)
        case kVK_ANSI_R where !cmd && isEditing: toggle(.rect)
        case kVK_ANSI_B where !cmd && isEditing: toggle(.blur)
        default:
            return false
        }
        return true
    }
}

// MARK: - Layers

/// Shows the frozen screenshot / stitched image as a layer (GPU, no redraw cost).
final class ImageLayerView: NSView {
    let image: CGImage
    init(image: CGImage) {
        self.image = image
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.contents = image
        layer?.contentsGravity = .resize
        layer?.minificationFilter = .trilinear
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.contents = image }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Dim outside the selection, selection border, handles, hovered-window outline.
final class ChromeView: NSView {
    private let dims = (0..<4).map { _ in CALayer() }
    private let border = CAShapeLayer(), hoverBorder = CAShapeLayer(), knobs = CAShapeLayer()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        for d in dims { d.backgroundColor = NSColor(white: 0, alpha: 0.5).cgColor; layer?.addSublayer(d) }
        border.fillColor = nil
        border.strokeColor = NSColor.controlAccentColor.cgColor
        border.lineWidth = 1.5
        hoverBorder.fillColor = nil
        hoverBorder.strokeColor = NSColor.controlAccentColor.cgColor
        hoverBorder.lineWidth = 3
        knobs.fillColor = NSColor.white.cgColor
        knobs.strokeColor = NSColor.controlAccentColor.cgColor
        knobs.lineWidth = 1.5
        for l in [hoverBorder, border, knobs] { layer?.addSublayer(l) }
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }


    func update(hole: CGRect?, selection: CGRect?, hover: CGRect?, handles: [CGPoint]) {
        for l in [border, hoverBorder, knobs] { l.frame = bounds }
        // Four bands around the hole (or one band covering everything).
        let b = bounds
        if let h = hole?.intersection(b), !h.isNull {
            dims[0].frame = CGRect(x: b.minX, y: b.minY, width: b.width, height: h.minY - b.minY)
            dims[1].frame = CGRect(x: b.minX, y: h.maxY, width: b.width, height: b.maxY - h.maxY)
            dims[2].frame = CGRect(x: b.minX, y: h.minY, width: h.minX - b.minX, height: h.height)
            dims[3].frame = CGRect(x: h.maxX, y: h.minY, width: b.maxX - h.maxX, height: h.height)
        } else {
            dims[0].frame = b
            for d in dims.dropFirst() { d.frame = .zero }
        }
        border.path = selection.map { CGPath(rect: $0.insetBy(dx: -0.75, dy: -0.75), transform: nil) }
        hoverBorder.path = hover.map { CGPath(rect: $0.insetBy(dx: 1.5, dy: 1.5), transform: nil) }
        let k = CGMutablePath()
        for p in handles { k.addEllipse(in: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)) }
        knobs.path = k
    }
}

/// Marks, clipped to the selection. Its frame is the visible part of the selection.
final class MarksView: NSView {
    weak var canvas: CanvasView?
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let c = canvas, let sel = c.selection, let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.translateBy(x: c.imageRect.minX - frame.minX, y: c.imageRect.minY - frame.minY)
        ctx.scaleBy(x: c.scale, y: c.scale)
        ctx.clip(to: sel)
        for a in c.annotations { Renderer.draw(a, in: ctx, blurred: c.blurred) }
        if let cur = c.current { Renderer.draw(cur, in: ctx, blurred: c.blurred) }
    }
}

// MARK: - Window

final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class OverlayController {
    let panel: OverlayPanel
    let canvas: CanvasView
    let screen: NSScreen
    var onFinish: ((OverlayController, Outcome) -> Void)?

    init(screen: NSScreen, base: CGImage, mode: OverlayMode, windows: [CGRect], pxPerPt: CGFloat) {
        self.screen = screen
        panel = OverlayPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        panel.setFrame(screen.frame, display: false)
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)))
        panel.isOpaque = mode != .editResult
        panel.backgroundColor = mode == .editResult ? .clear : .black
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.acceptsMouseMovedEvents = true
        panel.hidesOnDeactivate = false
        canvas = CanvasView(frame: CGRect(origin: .zero, size: screen.frame.size), base: base,
                            pxPerPt: pxPerPt, mode: mode, windows: windows)
        panel.contentView = canvas
        canvas.onFinish = { [weak self] o in
            guard let self else { return }
            self.onFinish?(self, o)
        }
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(canvas)
        NSCursor.crosshair.set()
    }

    func close() {
        panel.orderOut(nil)
        canvas.onFinish = nil
    }
}
