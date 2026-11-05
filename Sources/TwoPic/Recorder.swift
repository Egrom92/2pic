import AppKit
import AVFoundation
import ScreenCaptureKit

/// Records one screen region to an H.264 .mp4 (ScreenCaptureKit → AVAssetWriter), with the cursor.
final class RegionRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    let url: URL
    private var stream: SCStream?
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let queue = DispatchQueue(label: "2pic.recorder")
    private var started = false
    private var lastPTS = CMTime.invalid
    private(set) var frames = 0

    /// `rect`: screen-local top-left points. `exclude`: our own HUD windows to keep out of the video.
    init(screen: NSScreen, rect: CGRect, url: URL, exclude: [NSWindow]) async throws {
        self.url = url
        let scale = screen.backingScaleFactor
        // H.264 wants even pixel sizes.
        let wPx = max(2, Int(rect.width * scale) / 2 * 2), hPx = max(2, Int(rect.height * scale) / 2 * 2)
        let src = CGRect(x: rect.minX, y: rect.minY, width: CGFloat(wPx) / scale, height: CGFloat(hPx) / scale)

        let content = try await Capture.content()
        let ids = Set(exclude.map { CGWindowID($0.windowNumber) })
        let hidden = content.windows.filter { ids.contains($0.windowID) }
        let filter = SCContentFilter(display: try Capture.display(for: screen, in: content), excludingWindows: hidden)
        let cfg = SCStreamConfiguration()
        cfg.sourceRect = src
        cfg.width = wPx
        cfg.height = hPx
        cfg.showsCursor = true
        cfg.captureResolution = .best
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.colorSpaceName = CGColorSpace.sRGB
        cfg.queueDepth = 6

        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let bitrate = min(40_000_000, max(4_000_000, wPx * hPx * 5))
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: wPx,
            AVVideoHeightKey: hPx,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: 60,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
        super.init()

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = atts.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
        if !started {
            guard writer.startWriting() else { return }
            writer.startSession(atSourceTime: sb.presentationTimeStamp)
            started = true
        }
        if input.isReadyForMoreMediaData, input.append(sb) {
            lastPTS = sb.presentationTimeStamp
            frames += 1
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DiagLog.write("record: stream stopped: \(error)")
    }

    /// Stops and finalizes the file. Returns the file URL, or nil if nothing was recorded.
    func stop() async -> URL? {
        if let s = stream { try? await s.stopCapture() }
        stream = nil
        return await withCheckedContinuation { c in
            queue.async {
                guard self.started else { c.resume(returning: nil); return }
                // ScreenCaptureKit sends frames only when something changes: extend the video to "now".
                let now = CMClockGetTime(CMClockGetHostTimeClock())
                self.input.markAsFinished()
                self.writer.endSession(atSourceTime: self.lastPTS.isValid ? max(now, self.lastPTS) : now)
                self.writer.finishWriting {
                    c.resume(returning: self.writer.status == .completed ? self.url : nil)
                }
            }
        }
    }
}

/// While recording: red outline (not recorded), a stop pill (not recorded), and click bubbles (recorded).
@MainActor
final class RecordingHUD {
    private let outline: NSPanel
    private let pillWin: NSPanel
    private let pill: TimerPill
    let clicks: NSPanel
    private let clickView = ClickBubblesView()
    private var monitor: Any?
    private var timer: Timer?
    private let t0 = Date()

    var excludedWindows: [NSWindow] { [outline, pillWin] }

    init(screen: NSScreen, rect: CGRect, onStop: @escaping () -> Void) {
        let g = Screens.cocoaRect(rect, on: screen)
        func panel(_ r: CGRect, mouse: Bool) -> NSPanel {
            let p = NSPanel(contentRect: r, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .popUpMenu
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.ignoresMouseEvents = !mouse
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            p.isReleasedWhenClosed = false
            p.animationBehavior = .none
            p.hidesOnDeactivate = false
            return p
        }
        outline = panel(g.insetBy(dx: -4, dy: -4), mouse: false)
        outline.contentView = OutlineView()
        clicks = panel(g, mouse: false)
        clicks.contentView = clickView
        pill = TimerPill(onStop: onStop)
        let size = pill.frame.size
        var origin = CGPoint(x: g.midX - size.width / 2, y: g.minY - size.height - 10)
        if origin.y < screen.frame.minY + 4 { origin.y = g.maxY + 10 }
        if origin.y + size.height > screen.frame.maxY - 4 { origin.y = g.minY + 10 }
        pillWin = panel(CGRect(origin: origin, size: size), mouse: true)
        pillWin.contentView = pill
    }

    func show() {
        for w in [clicks, outline, pillWin] { w.orderFrontRegardless() }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.bubble(at: NSEvent.mouseLocation) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { guard let self else { return }; self.pill.set(seconds: Int(Date().timeIntervalSince(self.t0))) }
        }
    }

    func bubble(at cocoaPoint: CGPoint) {
        let f = clicks.frame
        guard f.insetBy(dx: -30, dy: -30).contains(cocoaPoint) else { return }
        clickView.bubble(at: CGPoint(x: cocoaPoint.x - f.minX, y: cocoaPoint.y - f.minY))
    }

    func close() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        timer?.invalidate()
        timer = nil
        for w in [clicks, outline, pillWin] { w.orderOut(nil) }
    }

    private final class OutlineView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor.systemRed.withAlphaComponent(0.9).setStroke()
            let p = NSBezierPath(rect: bounds.insetBy(dx: 2, dy: 2))
            p.lineWidth = 2
            p.setLineDash([6, 4], count: 2, phase: 0)
            p.stroke()
        }
    }

    private final class TimerPill: NSView {
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
            set(seconds: 5999)   // size for the longest text
            set(seconds: 0)
        }
        required init?(coder: NSCoder) { fatalError() }
        func set(seconds s: Int) {
            let a = NSMutableAttributedString(string: "● ", attributes: [.foregroundColor: NSColor.systemRed])
            a.append(NSAttributedString(string: String(format: "%d:%02d    ■ Стоп", s / 60, s % 60),
                                        attributes: [.foregroundColor: NSColor.white]))
            label.attributedStringValue = a
            label.sizeToFit()
            let sz = label.frame.size
            if frame.width < sz.width + 24 { setFrameSize(NSSize(width: sz.width + 24, height: sz.height + 12)) }
            label.frame.origin = CGPoint(x: (frame.width - sz.width) / 2, y: 6)
        }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { onStop() }
    }
}

/// Soft translucent "bubble pop" where the mouse was clicked.
final class ClickBubblesView: NSView {
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func bubble(at p: CGPoint) {
        guard let root = layer else { return }
        let r: CGFloat = 22
        let l = CAShapeLayer()
        l.frame = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
        l.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 2 * r, height: 2 * r), transform: nil)
        l.fillColor = NSColor(white: 1, alpha: 0.28).cgColor
        l.strokeColor = NSColor(white: 1, alpha: 0.85).cgColor
        l.lineWidth = 1.5
        l.shadowColor = NSColor.black.cgColor
        l.shadowOpacity = 0.35
        l.shadowRadius = 3
        l.shadowOffset = .zero
        l.opacity = 0
        root.addSublayer(l)

        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = [0.25, 1.0, 1.25]
        scale.keyTimes = [0, 0.55, 1]
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0.0, 1.0, 0.0]
        fade.keyTimes = [0, 0.15, 1]
        let ring = CABasicAnimation(keyPath: "lineWidth")
        ring.fromValue = 2.5
        ring.toValue = 0.5
        let g = CAAnimationGroup()
        g.animations = [scale, fade, ring]
        g.duration = 0.55
        g.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { l.removeFromSuperlayer() }
        l.add(g, forKey: "pop")
        CATransaction.commit()
    }
}

/// A small message at the top of the screen that fades away by itself.
@MainActor
enum Toast {
    private static var window: NSPanel?

    static func show(_ text: String) {
        window?.orderOut(nil)
        let label = PillLabel(fontSize: 13)
        label.text = text
        let screen = Screens.underMouse()
        let size = label.frame.size
        let p = NSPanel(contentRect: CGRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - 60,
                                            width: size.width, height: size.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .popUpMenu
        p.isOpaque = false
        p.backgroundColor = .clear
        p.ignoresMouseEvents = true
        p.hasShadow = false
        p.isReleasedWhenClosed = false
        p.contentView = label
        p.orderFrontRegardless()
        window = p
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.4; p.animator().alphaValue = 0 }) {
                p.orderOut(nil)
                if window === p { window = nil }
            }
        }
    }
}
