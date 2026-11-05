import AppKit

final class ToolButton: NSView {
    var isOn = false { didSet { needsDisplay = true } }
    private var hover = false { didSet { needsDisplay = true } }
    private let image: NSImage?
    private let action: () -> Void

    init(symbol: String, tip: String, action: @escaping () -> Void) {
        let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(white: 0.95, alpha: 1)]))
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?.withSymbolConfiguration(cfg)
        self.action = action
        super.init(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
        toolTip = tip
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let bg = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6)
        if isOn { NSColor.controlAccentColor.setFill(); bg.fill() } else if hover { NSColor(white: 1, alpha: 0.13).setFill(); bg.fill() }
        if let img = image {
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
}

/// Small dark bar under the selection: tools | undo | save, cancel, copy.
final class ToolbarView: NSView {
    private var toolButtons: [(Tool, ToolButton)] = []

    init(onTool: @escaping (Tool) -> Void, onUndo: @escaping () -> Void, onSave: @escaping () -> Void,
         onCancel: @escaping () -> Void, onCopy: @escaping () -> Void) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.11, alpha: 0.94).cgColor
        layer?.cornerRadius = 9
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor(white: 1, alpha: 0.14).cgColor

        let tools: [(Tool, String, String)] = [
            (.arrow, "arrow.up.right", "Стрелка  A"),
            (.line, "line.diagonal", "Линия  L"),
            (.rect, "rectangle", "Рамка  R"),
            (.blur, "drop.halffull", "Размытие  B"),
        ]
        var items: [NSView?] = []
        for (t, sym, tip) in tools {
            let b = ToolButton(symbol: sym, tip: tip) { onTool(t) }
            toolButtons.append((t, b))
            items.append(b)
        }
        items.append(nil)
        items.append(ToolButton(symbol: "arrow.uturn.backward", tip: "Отменить  ⌘Z", action: onUndo))
        items.append(nil)
        items.append(ToolButton(symbol: "square.and.arrow.down", tip: "Сохранить на рабочий стол  ⌘S", action: onSave))
        items.append(ToolButton(symbol: "xmark", tip: "Закрыть  Esc", action: onCancel))
        items.append(ToolButton(symbol: "doc.on.doc", tip: "Скопировать  ⌘C / Enter", action: onCopy))

        var x: CGFloat = 3
        for item in items {
            if let v = item {
                v.frame.origin = CGPoint(x: x, y: 3)
                addSubview(v)
                x += v.frame.width
            } else {
                let sep = NSView(frame: NSRect(x: x + 3, y: 10, width: 1, height: 18))
                sep.wantsLayer = true
                sep.layer?.backgroundColor = NSColor(white: 1, alpha: 0.18).cgColor
                addSubview(sep)
                x += 7
            }
        }
        setFrameSize(NSSize(width: x + 3, height: 38))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}   // don't let clicks fall through to the canvas

    func show(tool: Tool?) {
        for (t, b) in toolButtons { b.isOn = (t == tool) }
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
