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
    private var stopTap: CFMachPort?
    private var stopTapSource: CFRunLoopSource?
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    /// Why the capture ended early, for the result editor to tell the user (nil: it reached the end or was stopped).
    private(set) var notice: String?
    /// How it ended, for the usage statistics: end, userStopped, stoppedEarly, full, noCapture.
    private(set) var outcome = "noCapture"
    private(set) var frames = 0
    /// Self-test only: save every grabbed frame here.
    static var debugFrameDir: String?
    /// Diagnostics, off by default: `defaults write local.2pic saveScrollFramesOnFailure -bool YES` keeps the two
    /// frames that could not be glued in ~/Library/Logs/2pic-scroll-failures (they are screenshots: local only).
    private func saveFailedPair(_ a: CGImage?, _ b: CGImage) {
        guard UserDefaults.standard.bool(forKey: "saveScrollFramesOnFailure"), let a else { return }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/2pic-scroll-failures/\(f.string(from: Date()))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (img, name) in [(a, "1-before.png"), (b, "2-after.png")] {
            try? Output.encode(img, type: .png, dpi: 144)?.write(to: dir.appendingPathComponent(name))
        }
        Log.info("scroll", "frames saved to \(dir.lastPathComponent)")
    }
    private func dump(_ img: CGImage, _ n: Int) {
        guard let dir = Self.debugFrameDir, let d = Output.encode(img, type: .png, dpi: 144) else { return }
        try? d.write(to: URL(fileURLWithPath: "\(dir)/frame\(n).png"))
    }

    init(screen: NSScreen, rect: CGRect) {
        self.screen = screen
        self.rect = rect.integral
    }

    func stop() {
        if !stopRequested { Log.info("scroll", "stop requested by the user") }
        stopRequested = true
    }

    private func grabFailed() {
        outcome = "stoppedEarly"
        Log.error("scroll", "capturing frame \(frames + 1) failed")
        notice = "Прокрутка остановилась: не удалось снять следующий кадр. Снято до этого места."
    }

    func run() async -> CGImage? {
        let scale = screen.backingScaleFactor
        hud = ScrollHUD(screen: screen, rect: rect) { [weak self] in self?.stop() }
        hud?.show()
        escKey = HotKeys.shared.register(keyCode: kVK_Escape, modifiers: 0) { [weak self] in self?.stop() }
        // Any click or key stops scrolling. The event tap also swallows it, so it doesn't reach the app being
        // captured (the cursor sits in the middle of its page: a click there could follow a link, a key could
        // submit a form). If the tap can't be created, fall back to monitors, which only watch.
        if !installStopTap() {
            Log.warn("scroll", "event tap unavailable, using monitors: the stopping click will reach the app")
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.stop()
            }
            keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] _ in
                self?.stop()
            }
        }
        defer { cleanup() }

        let center = Screens.quartzPoint(CGPoint(x: rect.midX, y: rect.midY), on: screen)
        CGWarpMouseCursorPosition(center)
        try? await Task.sleep(nanoseconds: 120_000_000)

        guard let grabber = try? await RegionGrabber(screen: screen, rect: rect),
              let first = try? await grabber.grab() else { Log.error("scroll", "could not capture the region"); return nil }
        Log.info("scroll", "start: region \(Int(rect.width))×\(Int(rect.height)) pt, frame \(first.width)×\(first.height) px, "
                 + "app under it: \(WindowList.app(at: center) ?? "?")")
        let stitcher = Stitcher(maxHeight: 16000)
        dump(first, 1)
        _ = stitcher.add(first, requestedShift: 0)
        var glued: CGImage? = first   // the frame the stitcher compares the next one with
        frames = 1
        let t0 = Date()
        while !stopRequested && frames < 200 {
            let body = CGFloat(stitcher.bodyHeight ?? first.height)
            let stepPt = max(24, (body / scale * 0.5).rounded())
            let req = Int(stepPt * scale)
            Input.scroll(points: stepPt, at: center)
            try? await Task.sleep(nanoseconds: 170_000_000)
            if stopRequested { break }
            guard var img = try? await grabber.grab() else { grabFailed(); break }
            frames += 1
            dump(img, frames)
            var step = stitcher.add(img, requestedShift: req)
            if step == .noChange || step == .failed {
                // The app may still be repainting, loading or animating the scroll: look once more.
                if step == .failed { Log.info("scroll", "frame \(frames): no match yet (\(stitcher.lastProbe.map { "\($0)" } ?? "")), retrying") }
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard let again = try? await grabber.grab() else { grabFailed(); break }
                img = again
                step = stitcher.add(img, requestedShift: req)
            }
            let m = stitcher.lastRaw
            Log.info("scroll", "frame \(frames): \(step) req \(req)px, match shift \(m?.shift ?? -1) hdr \(m?.header ?? -1) ftr \(m?.footer ?? -1) score \(String(format: "%.2f", m?.score ?? -1)), total \(stitcher.height)px")
            switch step {
            case .first, .appended:
                glued = img
                hud?.progress(heightPt: CGFloat(stitcher.height) / scale)
                continue
            case .noChange:
                outcome = "end"
                Log.info("scroll", "end of the content")
            case .full:
                outcome = "full"
                Log.warn("scroll", "size limit reached")
                notice = "Достигнут предел длины снимка (\(stitcher.maxHeight) пикселей): дальше страница не снята."
            case .failed:
                if stitcher.lastStepShort {
                    // The previous step already moved less than asked: this is the end, where something
                    // on the page keeps changing (a video, an animation). Not an error.
                    outcome = "end"
                    Log.info("scroll", "end of the content (it keeps changing): \(stitcher.lastProbe.map { "\($0)" } ?? "")")
                } else {
                    outcome = "stoppedEarly"
                    Log.error("scroll", "stopped early, frame \(frames): \(stitcher.lastProbe.map { "\($0)" } ?? "")")
                    notice = "Прокрутка остановилась раньше конца: страница менялась во время съёмки. Снято до этого места."
                    saveFailedPair(glued, img)
                }
            }
            break
        }
        if stopRequested && outcome == "noCapture" { outcome = "userStopped" }
        if outcome == "noCapture" { outcome = "end" }   // the 200-frame cap
        Log.info("scroll", String(format: "done (%@): %d frames, %d px, %.1f s", outcome, frames, stitcher.height,
                                  Date().timeIntervalSince(t0)))
        return stitcher.compose()
    }

    /// Active event tap (needs Accessibility, which scrolling capture requires anyway) that turns any mouse
    /// button or key into "stop" and drops it. Button-up / key-up events are dropped too, so the app never
    /// sees half a click. Runs on the main run loop.
    private func installStopTap() -> Bool {
        let types: [CGEventType] = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
                                    .otherMouseDown, .otherMouseUp, .keyDown, .keyUp]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<ScrollCapturer>.fromOpaque(refcon).takeUnretainedValue()
            return MainActor.assumeIsolated {   // the tap's source is on the main run loop
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = me.stopTap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                me.stop()
                return nil
            }
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else { return false }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        stopTap = tap
        stopTapSource = source
        return true
    }

    private func cleanup() {
        HotKeys.shared.unregister(escKey)
        escKey = nil
        if let tap = stopTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let s = stopTapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
            CFMachPortInvalidate(tap)
        }
        stopTap = nil
        stopTapSource = nil
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
        clickMonitor = nil
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
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
            label.stringValue = h > 0 ? "Прокрутка… \(Int(h)) pt   ■ Стоп (любая клавиша)" : "Прокрутка…   ■ Стоп (любая клавиша)"
            label.sizeToFit()
            let s = label.frame.size
            if frame.width < s.width + 24 { setFrameSize(NSSize(width: s.width + 24, height: s.height + 12)) }
            label.frame.origin = CGPoint(x: (frame.width - s.width) / 2, y: 6)
        }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { onStop() }
    }
}
