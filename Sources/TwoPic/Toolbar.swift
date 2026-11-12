import AppKit

final class ToolButton: NSView {
    var isOn = false { didSet { needsDisplay = true } }
    /// false: being "on" is drawn by `drawContent` (a ring around a color swatch) instead of an accent fill.
    var fillsWhenOn = true
    /// Custom glyph instead of an SF Symbol: (bounds, isOn).
    var drawContent: ((NSRect, Bool) -> Void)? { didSet { needsDisplay = true } }
    private var hover = false { didSet { needsDisplay = true } }
    private let image: NSImage?
    private let tip: String
    private let action: () -> Void

    init(symbol: String?, tip: String, width: CGFloat = 30, action: @escaping () -> Void) {
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(white: 0.95, alpha: 1)]))
        image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: tip)?.withSymbolConfiguration(cfg) }
        self.tip = tip
        self.action = action
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 30))
        toolTip = tip
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let bg = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6)
        if isOn && fillsWhenOn {
            NSColor.controlAccentColor.setFill(); bg.fill()
        } else if hover {
            NSColor(white: 1, alpha: 0.13).setFill(); bg.fill()
        }
        if let drawContent {
            drawContent(bounds, isOn)
        } else if let img = image {
            let s = img.size
            img.draw(in: NSRect(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2, width: s.width, height: s.height))
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { hover = true }
    override func mouseExited(with event: NSEvent) { hover = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { action() }
    }

    // VoiceOver
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { tip }
    override func accessibilityPerformPress() -> Bool { action(); return true }

    /// A filled circle of `color`, `d` points across, centred in `r` (with a faint ring so dark colors show on the dark bar).
    static func dot(_ color: CGColor, _ d: CGFloat, in r: NSRect) {
        let c = NSBezierPath(ovalIn: NSRect(x: r.midX - d / 2, y: r.midY - d / 2, width: d, height: d))
        (NSColor(cgColor: color) ?? .white).setFill()
        c.fill()
        NSColor(white: 1, alpha: 0.35).setStroke()
        c.lineWidth = 1
        c.stroke()
    }
}

/// A dark rounded strip of buttons with thin separators (nil = separator).
class ButtonStrip: NSView {
    func lay(_ items: [NSView?]) {
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.11, alpha: 0.94).cgColor
        layer?.cornerRadius = 9
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor(white: 1, alpha: 0.14).cgColor
        var x: CGFloat = 3
        for item in items {
            if let v = item {
                v.frame.origin = CGPoint(x: x, y: 3)
                addSubview(v)
                x += v.frame.width
            } else {
                let sep = NSView(frame: NSRect(x: x + 3, y: 9, width: 1, height: 18))
                sep.wantsLayer = true
                sep.layer?.backgroundColor = NSColor(white: 1, alpha: 0.18).cgColor
                addSubview(sep)
                x += 7
            }
        }
        setFrameSize(NSSize(width: x + 3, height: 36))
    }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}   // don't let clicks fall through to the canvas
}

/// Bar under the selection: move | tools, color | undo, redo | text, video, save, close, copy.
final class ToolbarView: ButtonStrip {
    private var toolButtons: [(Tool, ToolButton)] = []
    private var cropButton: ToolButton!
    private(set) var styleButton: ToolButton!
    private var styleColor = MarkStyle.colors[0]
    private var styleSize = 1

    init(record: Bool, onTool: @escaping (Tool?) -> Void, onStyle: @escaping () -> Void,
         onUndo: @escaping () -> Void, onRedo: @escaping () -> Void, onCopyText: @escaping () -> Void,
         onRecord: @escaping () -> Void, onSave: @escaping () -> Void, onCancel: @escaping () -> Void,
         onCopy: @escaping () -> Void) {
        super.init(frame: .zero)
        let tools: [(Tool, String, String)] = [
            (.arrow, "arrow.up.right", "Стрелка  A"),
            (.line, "line.diagonal", "Линия  L"),
            (.rect, "rectangle", "Рамка  R"),
            (.text, "textformat", "Текст  T"),
            (.counter, "1.circle", "Нумерация  N"),
            (.blur, "drop.halffull", "Размытие  B"),
        ]
        cropButton = ToolButton(symbol: "crop", tip: "Выделение: сдвинуть или выделить заново  C") { onTool(nil) }
        var items: [NSView?] = [cropButton, nil]
        for (t, sym, tip) in tools {
            let b = ToolButton(symbol: sym, tip: tip) { onTool(t) }
            toolButtons.append((t, b))
            items.append(b)
        }
        styleButton = ToolButton(symbol: nil, tip: "Цвет и толщина", action: onStyle)
        styleButton.fillsWhenOn = false   // an accent fill would hide a blue dot: show "open" as a light plate
        styleButton.drawContent = { [unowned self] r, open in
            if open {
                NSColor(white: 1, alpha: 0.2).setFill()
                NSBezierPath(roundedRect: r.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6).fill()
            }
            ToolButton.dot(self.styleColor, [9, 12, 15][self.styleSize], in: r)
        }
        items += [styleButton, nil,
                  ToolButton(symbol: "arrow.uturn.backward", tip: "Отменить  ⌘Z", action: onUndo),
                  ToolButton(symbol: "arrow.uturn.forward", tip: "Повторить  ⌘⇧Z", action: onRedo), nil,
                  ToolButton(symbol: "text.viewfinder", tip: "Скопировать текст с картинки  O", action: onCopyText)]
        if record {
            items.append(ToolButton(symbol: "record.circle", tip: "Записать видео этой области  V", action: onRecord))
        }
        items += [ToolButton(symbol: "square.and.arrow.down", tip: "Сохранить  ⌘S", action: onSave),
                  ToolButton(symbol: "xmark", tip: "Закрыть  Esc", action: onCancel),
                  ToolButton(symbol: "doc.on.doc", tip: "Скопировать  ⌘C / Enter", action: onCopy)]
        lay(items)
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(tool: Tool?) {
        for (t, b) in toolButtons { b.isOn = (t == tool) }
        cropButton.isOn = (tool == nil)
    }

    func setStyle(color: CGColor, size: Int) {
        styleColor = color
        styleSize = size
        styleButton.needsDisplay = true
    }

    func setStyleOpen(_ open: Bool) { styleButton.isOn = open }
}

/// Small palette that opens from the color button: colors | thickness.
final class StylePicker: ButtonStrip {
    private var swatches: [ToolButton] = []
    private var sizes: [ToolButton] = []

    init(onColor: @escaping (Int) -> Void, onSize: @escaping (Int) -> Void) {
        super.init(frame: .zero)
        var items: [NSView?] = []
        for (i, c) in MarkStyle.colors.enumerated() {
            let b = ToolButton(symbol: nil, tip: MarkStyle.colorNames[i], width: 26) { onColor(i) }
            b.fillsWhenOn = false
            b.drawContent = { r, on in
                if on {   // the chosen color: a white ring around it
                    let ring = NSBezierPath(ovalIn: NSRect(x: r.midX - 10, y: r.midY - 10, width: 20, height: 20))
                    NSColor.white.setStroke()
                    ring.lineWidth = 2
                    ring.stroke()
                }
                ToolButton.dot(c, 14, in: r)
            }
            swatches.append(b)
            items.append(b)
        }
        items.append(nil)
        for i in 0..<MarkStyle.lineWidths.count {
            let b = ToolButton(symbol: nil, tip: MarkStyle.sizeNames[i], width: 28) { onSize(i) }
            let d: CGFloat = [4, 7, 11][i]
            b.drawContent = { r, _ in ToolButton.dot(CGColor(gray: 0.95, alpha: 1), d, in: r) }
            sizes.append(b)
            items.append(b)
        }
        lay(items)
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(color: Int, size: Int) {
        for (i, b) in swatches.enumerated() { b.isOn = i == color }
        for (i, b) in sizes.enumerated() { b.isOn = i == size }
    }
}

/// Small rounded label (selection size, hints).
final class PillLabel: NSView {
    private let label = NSTextField(labelWithString: "")

    init(fontSize: CGFloat = 11) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.82).cgColor
        layer?.cornerRadius = 6
        label.font = .monospacedDigitSystemFont(ofSize: fontSize, weight: .medium)
        label.textColor = NSColor(white: 0.95, alpha: 1)
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var text: String = "" {
        didSet {
            label.stringValue = text
            label.sizeToFit()
            let s = label.frame.size
            setFrameSize(NSSize(width: s.width + 14, height: s.height + 6))
            label.frame.origin = CGPoint(x: 7, y: 3)
        }
    }
}
