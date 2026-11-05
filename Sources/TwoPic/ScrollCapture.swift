import AppKit
import Carbon.HIToolbox
import Stitch

/// Scrolls the content under a region with synthetic wheel events, grabs frames and stitches them.
@MainActor
final class ScrollCapturer {
    let screen: NSScreen
    let rect: CGRect   // screen-local top-left points
    private var stopRequested = false
    private var hud: ScrollHUD?
    private var escKey: UInt32?
    private var clickMonitor: Any?
    var log: ((String) -> Void)?
    /// Self-test only: save every grabbed frame here.
    static var debugFrameDir: String?
    private func dump(_ img: CGImage, _ n: Int) {
        guard let dir = Self.debugFrameDir, let d = Output.encode(img, type: .png, dpi: 144) else { return }
        try? d.write(to: URL(fileURLWithPath: "\(dir)/frame\(n).png"))
    }

    init(screen: NSScreen, rect: CGRect) {
        self.screen = screen
        self.rect = rect.integral
    }

    func stop() { stopRequested = true }

    func run() async -> CGImage? {
        let scale = screen.backingScaleFactor
        hud = ScrollHUD(screen: screen, rect: rect) { [weak self] in self?.stop() }
        hud?.show()
        escKey = HotKeys.shared.register(keyCode: kVK_Escape, modifiers: 0) { [weak self] in self?.stop() }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.stop()
        }
        defer { cleanup() }

        let center = Screens.quartzPoint(CGPoint(x: rect.midX, y: rect.midY), on: screen)
        CGWarpMouseCursorPosition(center)
        try? await Task.sleep(nanoseconds: 120_000_000)

        guard let grabber = try? await RegionGrabber(screen: screen, rect: rect),
              let first = try? await grabber.grab() else { log?("capture failed"); return nil }
        log?("start rect \(rect) frame \(first.width)x\(first.height) center \(center)")
        let stitcher = Stitcher(maxHeight: 16000)
        dump(first, 1)
        _ = stitcher.add(first, requestedShift: 0)
        var frames = 1
        let t0 = Date()
        while !stopRequested && frames < 200 {
            let body = CGFloat(stitcher.bodyHeight ?? first.height)
            let stepPt = max(24, (body / scale * 0.5).rounded())
            let req = Int(stepPt * scale)
            Input.scroll(points: stepPt, at: center)
            try? await Task.sleep(nanoseconds: 170_000_000)
            if stopRequested { break }
            guard var img = try? await grabber.grab() else { break }
            frames += 1
            dump(img, frames)
            var step = stitcher.add(img, requestedShift: req)
            if step == .noChange {   // maybe the app was slow to repaint: look once more
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard let again = try? await grabber.grab() else { break }
                img = again
                step = stitcher.add(img, requestedShift: req)
            }
            let m = stitcher.lastRaw
            log?("frame \(frames): \(step) req \(req)px, match shift \(m?.shift ?? -1) hdr \(m?.header ?? -1) ftr \(m?.footer ?? -1) score \(String(format: "%.2f", m?.score ?? -1)), total \(stitcher.height)px")
            if step == .noChange || step == .failed || step == .full { break }
            hud?.progress(heightPt: CGFloat(stitcher.height) / scale)
        }
        log?(String(format: "done: %d frames, %.1fs", frames, Date().timeIntervalSince(t0)))
        return stitcher.compose()
    }

    private func cleanup() {
        HotKeys.shared.unregister(escKey)
        escKey = nil
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
        clickMonitor = nil
        hud?.close()
        hud = nil
    }
}

/// Thin outline around the region and a small "stop" pill while scrolling.
@MainActor
final class ScrollHUD {
    private let frameWin: NSPanel
    private let pillWin: NSPanel
    private let pill: StopPill

    init(screen: NSScreen, rect: CGRect, onStop: @escaping () -> Void) {
        let g = Screens.cocoaRect(rect, on: screen)
        func panel(_ r: CGRect) -> NSPanel {
            let p = NSPanel(contentRect: r, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .popUpMenu
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            p.isReleasedWhenClosed = false
            p.animationBehavior = .none
            p.hidesOnDeactivate = false
            return p
        }
        frameWin = panel(g.insetBy(dx: -4, dy: -4))
        frameWin.ignoresMouseEvents = true
        frameWin.contentView = OutlineView()

        pill = StopPill(onStop: onStop)
        let size = pill.frame.size
        var origin = CGPoint(x: g.midX - size.width / 2, y: g.minY - size.height - 10)
        if origin.y < screen.frame.minY + 4 { origin.y = g.maxY + 10 }
        if origin.y + size.height > screen.frame.maxY - 4 { origin.y = g.minY + 10 }
        pillWin = panel(CGRect(origin: origin, size: size))
        pillWin.contentView = pill
    }

    func show() {
        frameWin.orderFrontRegardless()
        pillWin.orderFrontRegardless()
    }

    func progress(heightPt: CGFloat) { pill.setHeight(heightPt) }

    func close() {
        frameWin.orderOut(nil)
        pillWin.orderOut(nil)
    }

    private final class OutlineView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor.controlAccentColor.setStroke()
            let p = NSBezierPath(rect: bounds.insetBy(dx: 2, dy: 2))
            p.lineWidth = 2
            p.stroke()
        }
    }

    private final class StopPill: NSView {
        private let label = NSTextField(labelWithString: "")
        private let onStop: () -> Void
        init(onStop: @escaping () -> Void) {
            self.onStop = onStop
            super.init(frame: .zero)
            wantsLayer = true
            layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.92).cgColor
            layer?.cornerRadius = 8
            label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            label.textColor = .white
            addSubview(label)
            setHeight(99999)   // size the pill for the longest text
            setHeight(0)
        }
        required init?(coder: NSCoder) { fatalError() }
        func setHeight(_ h: CGFloat) {
            label.stringValue = h > 0 ? "Прокрутка… \(Int(h)) pt   ■ Стоп (Esc)" : "Прокрутка…   ■ Стоп (Esc)"
            label.sizeToFit()
            let s = label.frame.size
            if frame.width < s.width + 24 { setFrameSize(NSSize(width: s.width + 24, height: s.height + 12)) }
            label.frame.origin = CGPoint(x: (frame.width - s.width) / 2, y: 6)
        }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { onStop() }
    }
}
