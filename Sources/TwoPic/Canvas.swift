import AppKit
import Carbon.HIToolbox

enum OverlayMode { case capture, scrollSelect, editResult }

enum Outcome {
    case cancel, copy, save
    case copyText         // recognize the text on the picture and copy it
    case scroll(CGRect)   // chosen region, screen-local top-left points
    case record(CGRect)   // same, for video
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
final class CanvasView: NSView, NSTextFieldDelegate {
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
    private(set) var tool: Tool?
    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []
    private var colorIndex = Settings.markColor
    private var sizeIndex = Settings.markSize
    private let windowRects: [CGRect]
    private(set) var hover: CGRect?
    private var drag: Drag = .none
    private var dragging = false
    private var downPoint = CGPoint.zero
    var onFinish: ((Outcome) -> Void)?

    private let imageView: ImageLayerView
    private let marksView = MarksView()
    private let chrome = ChromeView()
    private var toolbar: ToolbarView!
    private var picker: StylePicker!
    private let sizeLabel = PillLabel()
    private var hint: PillLabel?

    // The text being typed (text tool).
    private(set) var textField: MarkTextField?
    private var textOrigin = CGPoint.zero       // image pixels: top-left of the text
    private var textColor = MarkStyle.colors[0]
    private var textSize: CGFloat = 0           // font size, image pixels
    private var textReplacesMark = false        // re-editing a mark: its undo step was recorded when it was lifted
    /// Where the text field draws its first glyph relative to its frame, so typed and finished text line up.
    private static let fieldInset = CGPoint(x: 2.5, y: -0.5)   // measured by `--selftest ui`
    static var fieldInsetForTests: CGPoint { fieldInset }

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
        toolbar = ToolbarView(record: mode == .capture,
                              onTool: { [weak self] t in self?.setTool(t, via: "button") },
                              onStyle: { [weak self] in self?.togglePicker() },
                              onUndo: { [weak self] in self?.undo() },
                              onRedo: { [weak self] in self?.redo() },
                              onCopyText: { [weak self] in self?.finish(.copyText, via: "button") },
                              onRecord: { [weak self] in self?.startRecord(via: "button") },
                              onSave: { [weak self] in self?.finish(.save, via: "button") },
                              onCancel: { [weak self] in self?.finish(.cancel, via: "button") },
                              onCopy: { [weak self] in self?.finish(.copy, via: "button") })
        picker = StylePicker(onColor: { [weak self] i in self?.setColor(i) },
                             onSize: { [weak self] i in self?.setSize(i) })
        picker.isHidden = true
        for v in [imageView, marksView, chrome, toolbar!, picker!, sizeLabel] as [NSView] { addSubview(v) }
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
        toolbar.setStyle(color: color, size: sizeIndex)
        picker.show(color: colorIndex, size: sizeIndex)
        setTool(mode == .editResult ? .arrow : nil)
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
    func toView(_ p: CGPoint) -> CGPoint {
        CGPoint(x: imageRect.minX + p.x * scale, y: imageRect.minY + p.y * scale)
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

    private var isEditing: Bool { selection != nil && mode != .scrollSelect }

    // Current style, in image pixels.
    private var color: CGColor { MarkStyle.colors[colorIndex] }
    private var lineWidth: CGFloat { MarkStyle.lineWidths[sizeIndex] * pxPerPt }
    private var fontSize: CGFloat { MarkStyle.fontSizes[sizeIndex] * pxPerPt }
    private var counterSize: CGFloat { MarkStyle.counterSizes[sizeIndex] * pxPerPt }

    /// The selection's edges and corners can be dragged in every mode. The grab zone reaches further
    /// outside the frame than inside it, so drawing right next to an edge still draws.
    private func handle(at p: CGPoint, in sv: CGRect) -> Handle? {
        for h in [Handle.tl, .tr, .br, .bl] where hypot(h.point(sv).x - p.x, h.point(sv).y - p.y) <= 10 { return h }
        let outside: CGFloat = 7, inside: CGFloat = 4
        let inX = p.x > sv.minX && p.x < sv.maxX, inY = p.y > sv.minY && p.y < sv.maxY
        if inX && p.y >= sv.minY - outside && p.y <= sv.minY + inside { return .t }
        if inX && p.y <= sv.maxY + outside && p.y >= sv.maxY - inside { return .b }
        if inY && p.x >= sv.minX - outside && p.x <= sv.minX + inside { return .l }
        if inY && p.x <= sv.maxX + outside && p.x >= sv.maxX - inside { return .r }
        return nil
    }

    // MARK: drawing state → views

    func refresh() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageView.frame = imageRect
        let sv = selection.map(toView)
        let hv = selection == nil ? hover.map(toView) : nil
        var reshaping = false, drawing = false
        switch drag {
        case .select: reshaping = dragging
        case .resize: reshaping = true
        case .draw: drawing = true
        default: break
        }
        chrome.update(hole: sv ?? hv,
                      selection: sv,
                      hover: hv,
                      handles: (sv != nil && isEditing && !drawing) ? Handle.allCases.map { $0.point(sv!) } : [])
        if let sv {
            let vis = sv.intersection(bounds)
            marksView.isHidden = vis.isNull
            if !vis.isNull { marksView.frame = vis; marksView.needsDisplay = true }
        } else {
            marksView.isHidden = true
        }
        toolbar.isHidden = !(isEditing && !reshaping)
        if toolbar.isHidden && !picker.isHidden { picker.isHidden = true; toolbar.setStyleOpen(false) }
        if !toolbar.isHidden, let sv { placeToolbar(sv) }
        if let sel = selection, let sv, reshaping || mode == .scrollSelect {
            sizeLabel.text = "\(Int(sel.width)) × \(Int(sel.height))"
            let y = sv.minY - sizeLabel.frame.height - 6
            sizeLabel.setFrameOrigin(CGPoint(x: max(4, sv.minX), y: y >= 2 ? y : sv.minY + 6))
            sizeLabel.isHidden = false
        } else {
            sizeLabel.isHidden = true
        }
        layoutTextField()
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
        guard !picker.isHidden else { return }
        // The palette opens at the color button, on the far side of the bar from the selection
        // (below a bar that hangs under it, above otherwise), so it covers as little of the picture as possible.
        let ps = picker.frame.size
        let button = toolbar.styleButton.frame.offsetBy(dx: toolbar.frame.minX, dy: toolbar.frame.minY)
        let barBelow = toolbar.frame.minY >= vis.maxY
        var py = barBelow ? toolbar.frame.maxY + 6 : toolbar.frame.minY - 6 - ps.height
        if py + ps.height > bounds.height - 6 { py = toolbar.frame.minY - 6 - ps.height }
        if py < 6 { py = toolbar.frame.maxY + 6 }
        let px = min(max(6, button.midX - ps.width / 2), bounds.width - ps.width - 6)
        picker.setFrameOrigin(CGPoint(x: px.rounded(), y: py.rounded()))
    }

    // MARK: actions

    /// nil = selection mode: drag inside moves the frame, outside selects anew.
    /// `via`: "key" or "button" when the user picked it (for the statistics); nil when the app switched itself.
    func setTool(_ t: Tool?, via: String? = nil) {
        endTextEditing()
        if let via, t != tool {
            Usage.count("toolvia.\(via)")
            if t == nil { Usage.count("tool.select") }
            Log.info("editor", "tool \(t.map { "\($0)" } ?? "select") via \(via)")
        }
        tool = t
        toolbar.show(tool: tool)
        if tool == .blur { prepareBlur() }
        refresh()
        if let w = window { updateCursor(convert(w.mouseLocationOutsideOfEventStream, from: nil)) }
    }

    private let openedAt = Date()

    /// Every way out of the editor comes through here: the outcome, how it was reached and what was on the picture
    /// go to the log and the usage statistics.
    private func finish(_ o: Outcome, via: String) {
        endTextEditing()
        let kind: String
        switch o {
        case .cancel: kind = "cancel"
        case .copy: kind = "copy"
        case .save: kind = "save"
        case .copyText: kind = "copyText"
        case .scroll: kind = "scroll"
        case .record: kind = "record"
        }
        let seconds = Date().timeIntervalSince(openedAt)
        Usage.count("finish.\(kind)")
        if kind == "copy" { Usage.count("copy.via.\(via)") }
        if kind == "cancel" { Usage.count("cancel.via.\(via)") }
        if kind != "cancel" {
            Usage.measure("editor.seconds", seconds)
            if mode != .scrollSelect { Usage.measure("marks.perShot", Double(annotations.count)) }
            if selection == nil && mode == .capture { Usage.count("select.enter") }
        }
        let marks = Dictionary(grouping: annotations, by: { "\($0.tool)" }).map { "\($0.key)×\($0.value.count)" }.sorted()
        let sel = selection.map { "\(Int($0.width))×\(Int($0.height)) px" } ?? (hover != nil ? "the hovered window" : "none")
        Log.info("editor", String(format: "%@ via %@ after %.1f s (%@); selection %@; marks: %@", kind, via, seconds, "\(mode)",
                                  sel, marks.isEmpty ? "none" : marks.joined(separator: " ")))
        onFinish?(o)
    }

    func startRecord(via: String) {
        guard mode == .capture, let sel = selection else { return }
        finish(.record(toView(sel)), via: via)
    }

    private func togglePicker() {
        if picker.isHidden { Usage.count("style.picker") }
        picker.isHidden.toggle()
        toolbar.setStyleOpen(!picker.isHidden)
        refresh()
    }

    private func setColor(_ i: Int) {
        Usage.count("style.color.\(i)")
        Log.info("editor", "color \(MarkStyle.colorNames[i])")
        colorIndex = i
        Settings.markColor = i
        styleChanged()
        if textField != nil { textColor = color; styleTextField() }
    }

    private func setSize(_ i: Int) {
        Usage.count("style.size.\(i)")
        Log.info("editor", "thickness \(MarkStyle.sizeNames[i])")
        sizeIndex = i
        Settings.markSize = i
        styleChanged()
        if textField != nil { textSize = fontSize; styleTextField() }
    }

    private func styleChanged() {
        toolbar.setStyle(color: color, size: sizeIndex)
        picker.show(color: colorIndex, size: sizeIndex)
        // Picking a style while in selection mode means "I want to draw": switch to the arrow.
        if tool == nil { setTool(.arrow) }
    }

    // MARK: undo / redo (snapshots of the marks)

    private func recordUndo() {
        undoStack.append(annotations)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo() {
        endTextEditing()
        guard let prev = undoStack.popLast() else { return }
        Usage.count("undo")
        redoStack.append(annotations)
        annotations = prev
        refresh()
    }

    func redo() {
        endTextEditing()
        guard let next = redoStack.popLast() else { return }
        Usage.count("redo")
        undoStack.append(annotations)
        annotations = next
        refresh()
    }

    private var nextCounterNumber: Int {
        (annotations.filter { $0.tool == .counter }.map(\.number).max() ?? 0) + 1
    }

    private func prepareBlur() {
        if blurred == nil { blurred = Renderer.blurred(base, sigma: 6 * pxPerPt) }
    }

    /// The final image: selection (or hovered window, or whole image) with marks.
    func render() -> CGImage? {
        endTextEditing()
        let sel = selection ?? hover ?? imageBounds
        if annotations.contains(where: { $0.tool == .blur }) { prepareBlur() }
        return Renderer.export(base: base, selection: sel, annotations: annotations, blurred: blurred)
    }

    /// For self-tests.
    func debugSet(selection: CGRect, annotations: [Annotation], tool: Tool?) {
        self.selection = selection
        self.annotations = annotations
        setTool(tool)
        if annotations.contains(where: { $0.tool == .blur }) { prepareBlur() }
        refresh()
    }
    func debugOpenPicker() { if picker.isHidden { togglePicker() } }

    /// A short message at the top of the editor that fades away by itself (the editor sits above toasts).
    func showNotice(_ text: String) {
        let label = PillLabel(fontSize: 13)
        label.text = text
        label.setFrameOrigin(CGPoint(x: ((bounds.width - label.frame.width) / 2).rounded(), y: 8))
        addSubview(label)
        DispatchQueue.main.asyncAfter(deadline: .now() + 7) { [weak label] in
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.5; label?.animator().alphaValue = 0 }) {
                MainActor.assumeIsolated { label?.removeFromSuperview() }
            }
        }
    }

    // MARK: text tool

    private func beginText(at ip: CGPoint) {
        // Clicking an existing text edits it.
        if let i = annotations.lastIndex(where: { $0.tool == .text && Renderer.textBounds($0).insetBy(dx: -6, dy: -4).contains(ip) }) {
            let a = annotations[i]
            Usage.count("text.reedit")
            recordUndo()
            annotations.remove(at: i)
            textReplacesMark = true
            openTextField(origin: a.start, text: a.text, color: a.color, size: a.size)
            return
        }
        textReplacesMark = false
        // The click marks the middle of the first line.
        let font = Renderer.textFont(fontSize)
        let lineHeight = font.ascender - font.descender + font.leading
        openTextField(origin: CGPoint(x: ip.x, y: ip.y - lineHeight / 2), text: "", color: color, size: fontSize)
    }

    private func openTextField(origin: CGPoint, text: String, color: CGColor, size: CGFloat) {
        textOrigin = origin
        textColor = color
        textSize = size
        let f = MarkTextField(string: text)
        f.delegate = self
        Self.configureTextField(f)
        f.wantsLayer = true
        f.layer?.cornerRadius = 3
        f.layer?.borderWidth = 1
        f.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor
        addSubview(f, positioned: .below, relativeTo: toolbar)
        textField = f
        styleTextField()
        refresh()
        window?.makeFirstResponder(f)
        if let ed = f.currentEditor() as? NSTextView {
            ed.insertionPointColor = NSColor(cgColor: color) ?? .white
            ed.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        }
    }

    private func styleTextField() {
        guard let f = textField else { return }
        f.font = Renderer.textFont(textSize * scale)
        f.textColor = NSColor(cgColor: textColor)
        (f.currentEditor() as? NSTextView)?.insertionPointColor = NSColor(cgColor: textColor) ?? .white
        layoutTextField()
    }

    /// Sizes the field to what has been typed so far (the field's own value lags behind its editor while typing).
    private func layoutTextField() {
        guard let f = textField, let font = f.font else { return }
        var s = f.currentEditor()?.string ?? f.stringValue
        if s.isEmpty || s.hasSuffix("\n") { s += " " }   // room for the caret on an empty last line
        let text = NSAttributedString(string: s, attributes: [.font: font]).size()
        let w = max(ceil(text.width) + 6, textSize * scale) + 2 * Self.fieldInset.x
        let h = ceil(text.height) + 2 * Self.fieldInset.y + 2
        let o = toView(textOrigin)
        f.frame = CGRect(x: o.x - Self.fieldInset.x, y: o.y - Self.fieldInset.y, width: w, height: h)
    }

    /// Sets up a text field to look like a text mark (also used by the self-test that checks they line up).
    static func configureTextField(_ f: NSTextField) {
        f.isBordered = false
        f.isBezeled = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.usesSingleLineMode = false
        f.cell?.wraps = false
        f.cell?.isScrollable = false
        f.lineBreakMode = .byClipping
    }

    /// Turns the typed text into a mark (or nothing, if it is empty).
    func endTextEditing() {
        guard let f = textField else { return }
        textField = nil   // first, so the focus change below doesn't come back here
        var s = f.stringValue
        while s.last?.isWhitespace == true { s.removeLast() }
        // Still typing in it: hand the keyboard back to the canvas. (If focus already moved elsewhere, leave it.)
        if let ed = f.currentEditor(), window?.firstResponder === ed { window?.makeFirstResponder(self) }
        f.delegate = nil
        f.removeFromSuperview()
        var a = Annotation(tool: .text, start: textOrigin, end: textOrigin, width: lineWidth, color: textColor)
        a.size = textSize
        a.text = s
        if a.isMeaningful {
            if !textReplacesMark { recordUndo(); Usage.count("mark.text") }
            annotations.append(a)
            Log.info("editor", "text mark: \(s.count) characters")
        }
        textReplacesMark = false
        refresh()
    }

    func controlTextDidChange(_ obj: Notification) { layoutTextField() }
    func controlTextDidEndEditing(_ obj: Notification) { endTextEditing() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {   // Shift+Enter: new line
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                endTextEditing()                                               // Enter: done
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)), #selector(NSResponder.insertTab(_:)):
            endTextEditing()   // Esc / Tab: done (Esc doesn't close the screenshot while typing)
            return true
        default:
            return false
        }
    }

    // MARK: mouse

    private var hadSelection = false
    private var selectionAtDown: CGRect?
    private static let minSelection: CGFloat = 6   // image pixels; smaller frames are treated as a slip of the mouse

    private func isUsable(_ r: CGRect?) -> Bool {
        guard let r else { return false }
        return r.width >= Self.minSelection && r.height >= Self.minSelection
    }

    override func mouseDown(with e: NSEvent) {
        let p = location(e)
        if !picker.isHidden { togglePicker() }   // a click anywhere else closes the palette
        endTextEditing()
        hadSelection = selection != nil
        selectionAtDown = selection
        downPoint = p
        dragging = false
        guard isEditing, let sel = selection else { drag = .select(p); return }
        let sv = toView(sel)
        if let h = handle(at: p, in: sv) { drag = .resize(h, sel); return }
        if e.clickCount == 2, sv.contains(p), tool != .text, tool != .counter { current = nil; finish(.copy, via: "doubleClick"); return }
        if sv.contains(p) {
            switch tool {
            case nil:
                drag = .move(p, sel)
                NSCursor.closedHand.set()
            case .text?:
                beginText(at: toImage(p))
                drag = .none
            case let t?:
                if t == .blur { prepareBlur() }
                let ip = toImage(p)
                var a = Annotation(tool: t, start: ip, end: ip, width: lineWidth, color: color)
                if t == .counter { a.size = counterSize; a.number = nextCounterNumber }
                current = a
                drag = .draw
                refresh()
            }
            return
        }
        // Outside the selection: in selection mode start a new one, with a drawing tool do nothing.
        drag = (tool != nil || (mode == .editResult && !imageRect.contains(p))) ? .none : .select(p)
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
            if c.tool == .counter {   // a numbered circle follows the mouse until it is let go
                c.start = ip
                c.end = ip
            } else {
                if e.modifierFlags.contains(.shift) { ip = Annotation.constrained(start: c.start, end: ip, tool: c.tool) }
                c.end = ip
            }
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
            let firstSelection = !hadSelection
            var kind = "drag"
            if !dragging {
                guard selection == nil else { return }   // stray click outside: keep the selection
                kind = hover != nil ? "window" : "screen"
                selection = hover ?? imageBounds          // click: the window under the cursor, or the whole screen
            }
            defer { if firstSelection && mode == .capture && selection != nil { setTool(.arrow) } }
            guard let sel = selection, isUsable(sel) else {
                // Too thin to be meant: keep the frame that was there before (none on the first selection),
                // instead of losing it or leaving an empty one that would copy nothing.
                selection = selectionAtDown
                return
            }
            hover = nil
            Usage.count(firstSelection ? "select.\(kind)" : "frame.reselect")
            Log.info("editor", "selected \(firstSelection ? kind : "anew"): \(Int(sel.width))×\(Int(sel.height)) px")
            if mode == .scrollSelect {
                let r = toView(sel)
                drag = .none
                finish(.scroll(r), via: kind)
            }
        case .draw:
            if let c = current, c.isMeaningful {
                recordUndo()
                annotations.append(c)
                Usage.count("mark.\(c.tool)")
            }
            current = nil
        case .resize(_, let orig):
            if !isUsable(selection) {
                selection = orig   // an edge dragged onto the opposite one
            } else if dragging, let sel = selection {
                Usage.count("frame.resize")
                Log.info("editor", "frame resized to \(Int(sel.width))×\(Int(sel.height)) px")
            }
        case .move:
            if dragging { Usage.count("frame.move") }
        default:
            break
        }
    }

    override func rightMouseDown(with event: NSEvent) { finish(.cancel, via: "rightClick") }

    override func mouseMoved(with e: NSEvent) { pointerMoved(to: location(e)) }

    /// Highlights the window under the mouse right away, without waiting for the mouse to move.
    func syncWithMouse() {
        guard let w = window else { return }
        pointerMoved(to: convert(w.mouseLocationOutsideOfEventStream, from: nil))
    }

    func pointerMoved(to p: CGPoint) {
        if selection == nil && mode != .editResult {
            let ip = toImage(p)
            let h = windowRects.first { $0.contains(ip) }
            if h != hover { hover = h; refresh() }
        }
        updateCursor(p)
    }

    override func cursorUpdate(with event: NSEvent) { updateCursor(location(event)) }

    private func updateCursor(_ p: CGPoint) {
        if (!toolbar.isHidden && toolbar.frame.contains(p)) || (!picker.isHidden && picker.frame.contains(p)) {
            NSCursor.arrow.set(); return
        }
        if let f = textField, f.frame.contains(p) { NSCursor.iBeam.set(); return }
        guard isEditing, let sel = selection else { NSCursor.crosshair.set(); return }
        let sv = toView(sel)
        if let h = handle(at: p, in: sv) { Self.resizeCursor(h).set(); return }
        if sv.contains(p) {
            switch tool {
            case nil: NSCursor.openHand.set()
            case .text?: NSCursor.iBeam.set()
            default: NSCursor.crosshair.set()
            }
            return
        }
        // Outside: a new selection can start only in selection mode.
        (tool == nil ? NSCursor.crosshair : NSCursor.arrow).set()
    }

    private static func resizeCursor(_ h: Handle) -> NSCursor {
        if #available(macOS 15.0, *) {
            let pos: NSCursor.FrameResizePosition
            switch h {
            case .tl: pos = .topLeft
            case .t: pos = .top
            case .tr: pos = .topRight
            case .r: pos = .right
            case .br: pos = .bottomRight
            case .b: pos = .bottom
            case .bl: pos = .bottomLeft
            case .l: pos = .left
            }
            return .frameResize(position: pos, directions: .all)
        }
        switch h {
        case .t, .b: return .resizeUpDown
        case .l, .r: return .resizeLeftRight
        default: return .crosshair
        }
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
        if let f = textField {
            if f.performKeyEquivalent(with: e) { return true }   // ⌘A / ⌘C / ⌘V / ⌘X / ⌘Z edit the text
            endTextEditing()                                    // other shortcuts act on the picture
        }
        return handleKey(e)
    }

    override func keyDown(with e: NSEvent) {
        if !handleKey(e) { super.keyDown(with: e) }
    }

    private func handleKey(_ e: NSEvent) -> Bool {
        let cmd = e.modifierFlags.contains(.command), shift = e.modifierFlags.contains(.shift)
        switch Int(e.keyCode) {
        case kVK_Escape:
            if !picker.isHidden { togglePicker() } else { finish(.cancel, via: "esc") }
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if mode != .scrollSelect { finish(.copy, via: "enter") }
        case kVK_ANSI_C where cmd:
            if mode != .scrollSelect { finish(.copy, via: "cmdC") }
        case kVK_ANSI_S where cmd:
            if mode != .scrollSelect { finish(.save, via: "cmdS") }
        case kVK_ANSI_Z where cmd:
            if shift { redo() } else { undo() }
        case kVK_ANSI_C where !cmd && isEditing: setTool(nil, via: "key")
        case kVK_ANSI_V where !cmd && isEditing: startRecord(via: "key")
        case kVK_ANSI_A where !cmd && isEditing: setTool(.arrow, via: "key")
        case kVK_ANSI_L where !cmd && isEditing: setTool(.line, via: "key")
        case kVK_ANSI_R where !cmd && isEditing: setTool(.rect, via: "key")
        case kVK_ANSI_T where !cmd && isEditing: setTool(.text, via: "key")
        case kVK_ANSI_N where !cmd && isEditing: setTool(.counter, via: "key")
        case kVK_ANSI_B where !cmd && isEditing: setTool(.blur, via: "key")
        case kVK_ANSI_O where !cmd && isEditing: finish(.copyText, via: "key")
        default:
            return false
        }
        return true
    }
}

/// The text field of the text tool. The app has no Edit menu, so ⌘A / ⌘C / ⌘V / ⌘X / ⌘Z are wired here
/// (by key code, so they work in any keyboard layout).
final class MarkTextField: NSTextField {
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), let ed = currentEditor() as? NSTextView else { return false }
        switch Int(e.keyCode) {
        case kVK_ANSI_A: ed.selectAll(nil)
        case kVK_ANSI_C: ed.copy(nil)
        case kVK_ANSI_V: ed.pasteAsPlainText(nil)
        case kVK_ANSI_X: ed.cut(nil)
        case kVK_ANSI_Z: if flags.contains(.shift) { ed.undoManager?.redo() } else { ed.undoManager?.undo() }
        default: return false
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
        canvas.syncWithMouse()   // the window under the cursor is highlighted at once: a click takes it
    }

    func close() {
        panel.orderOut(nil)
        canvas.onFinish = nil
    }
}
