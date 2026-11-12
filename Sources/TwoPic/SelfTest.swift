// Only in debug builds or in an explicit test build (`SELFTEST=1 ./scripts/build.sh`). Never in the build that
// gets installed for daily use: these commands would let any local program take screenshots, record video and post
// mouse/keyboard events through 2pic's Screen Recording and Accessibility permissions.
#if DEBUG || SELFTEST
import AppKit
import Carbon.HIToolbox
import AVFoundation
import Stitch
import ServiceManagement

/// Command-line self-tests, run as a separate instance of a test build:
///   open -n build/2pic.app --args --selftest <kind> ...
/// Kinds:
///   export OUT                     capture the screen, burn in sample marks, write OUT and copy to clipboard
///   overlay OUT                    show the overlay with a sample selection, screenshot it to OUT
///   scroll X Y W H OUT             scrolling capture of a region (screen points), write OUT
///   e2e-area X1 Y1 X2 Y2 OUT       press ⌘⇧9 in the running 2pic, drag, ⌘C, save the clipboard to OUT
///   e2e-window X Y OUT             press ⌘⇧9, click a window, ⌘C, save the clipboard to OUT
///   e2e-scroll X1 Y1 X2 Y2 OUT     press ⌘⇧8, drag, wait for the result, ⌘C, save the clipboard to OUT
enum SelfTest {
    static func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

    static func start(_ app: AppDelegate) -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--selftest"), i + 1 < args.count else { return false }
        let kind = args[i + 1]
        let rest = Array(args[(i + 2)...])
        Task { @MainActor in
            do { try await run(kind, rest, app) } catch { log("ERROR: \(error)") }
            NSApp.terminate(nil)
        }
        return true
    }

    struct Failure: Error, CustomStringConvertible { let description: String }

    static func write(_ img: CGImage, _ path: String) throws {
        guard let d = Output.encode(img, type: .png, dpi: 144) else { throw Failure(description: "encode") }
        try d.write(to: URL(fileURLWithPath: path))
        log("wrote \(path) \(img.width)x\(img.height)")
    }

    @MainActor
    static func run(_ kind: String, _ a: [String], _ app: AppDelegate) async throws {
        let screen = Screens.underMouse()
        log("post-event access: \(CGPreflightPostEventAccess()), screen access: \(CGPreflightScreenCaptureAccess())")
        let num = { (i: Int) -> CGFloat in CGFloat(Double(a[i]) ?? 0) }
        switch kind {
        case "export":
            let t0 = Date()
            let shot = try await Capture.screen(screen)
            log(String(format: "screen %dx%d in %.0f ms", shot.width, shot.height, Date().timeIntervalSince(t0) * 1000))
            let s = CGFloat(shot.width) / screen.frame.width
            let sel = CGRect(x: shot.width / 4, y: shot.height / 4, width: shot.width / 2, height: shot.height / 2)
            let marks = sampleMarks(sel, s)
            let blurred = Renderer.blurred(shot, sigma: 6 * s)
            let t1 = Date()
            guard let img = Renderer.export(base: shot, selection: sel, annotations: marks, blurred: blurred) else {
                throw Failure(description: "export")
            }
            Output.copy(img, pxPerPt: s)
            log(String(format: "render+copy %.0f ms", Date().timeIntervalSince(t1) * 1000))
            try write(img, a[0])
        case "overlay":
            let shot = try await Capture.screen(screen)
            let s = CGFloat(shot.width) / screen.frame.width
            let ov = OverlayController(screen: screen, base: shot, mode: .capture,
                                       windows: WindowList.rects(on: screen, pxPerPt: s), pxPerPt: s)
            app.present(ov)
            let sel = CGRect(x: shot.width / 5, y: shot.height / 6, width: shot.width * 3 / 5, height: shot.height / 2)
            ov.canvas.debugSet(selection: sel, annotations: sampleMarks(sel, s), tool: nil)
            try await Task.sleep(nanoseconds: 700_000_000)
            let ui = try await Capture.screen(screen, cursor: true)
            for (x, y) in [(100, 100), (3500, 2200), (1800, 1000), (3400, 600)] {
                log("pixel \(x),\(y): frozen \(luma(shot, x, y)) overlay \(luma(ui, x, y))")
            }
            ov.close()
            try write(ui, a[0])
        case "scroll":
            let rect = CGRect(x: num(0), y: num(1), width: num(2), height: num(3))
            ScrollCapturer.debugFrameDir = (a[4] as NSString).deletingLastPathComponent
            if a.count > 5 {   // optional 6th arg: scroll up this many points first
                let c = Screens.quartzPoint(CGPoint(x: rect.midX, y: rect.midY), on: screen)
                CGWarpMouseCursorPosition(c)
                try await Task.sleep(nanoseconds: 200_000_000)
                Input.scroll(points: -num(5), at: c)
                try await Task.sleep(nanoseconds: 2_500_000_000)
            }
            let img: CGImage? = await withCheckedContinuation { c in
                app.startScroll(screen: screen, rect: rect) { c.resume(returning: $0) }
            }
            guard let img else { throw Failure(description: "no scroll image") }
            try write(img, a[4])
        case "e2e-area", "e2e-scroll":
            let p1 = CGPoint(x: num(0), y: num(1)), p2 = CGPoint(x: num(2), y: num(3))
            let before = NSPasteboard.general.changeCount
            key(kind == "e2e-area" ? kVK_ANSI_9 : kVK_ANSI_8, [.maskCommand, .maskShift])
            try await waitOverlayTimed()
            try await dragMouse(p1, p2)
            if kind == "e2e-area" {
                try await Task.sleep(nanoseconds: 300_000_000)
                // Drag inside the selection without choosing a tool: the default tool should draw an arrow.
                try await dragMouse(CGPoint(x: p1.x + 40, y: p2.y - 40), CGPoint(x: p2.x - 60, y: p1.y + 50))
                try await Task.sleep(nanoseconds: 300_000_000)
            } else {
                log("waiting for scrolling to finish…")
                let t0 = Date()
                while try await waitForOtherOverlay(timeout: 0.05), Date().timeIntervalSince(t0) < 5 {}   // selection overlay closes
                guard try await waitForOtherOverlay(timeout: 90) else { throw Failure(description: "no result overlay") }
                log(String(format: "result shown %.1f s after selecting", Date().timeIntervalSince(t0)))
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            key(kVK_ANSI_C, [.maskCommand])
            try await saveClipboard(after: before, to: a[4])
        case "shot":
            try write(try await Capture.screen(screen, cursor: true), a[0])
        case "wheel":   // wheel X Y POINTS OUT — post wheel events at a point (no HUD), then screenshot
            let p = Screens.quartzPoint(CGPoint(x: num(0), y: num(1)), on: screen)
            CGWarpMouseCursorPosition(p)
            try await Task.sleep(nanoseconds: 300_000_000)
            Input.scroll(points: num(2), at: p)
            try await Task.sleep(nanoseconds: 500_000_000)
            try write(try await Capture.screen(screen, cursor: true), a[3])
        case "editresult":   // editresult IN.png OUT.png — open a tall image in the result editor, screenshot it
            guard let img = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: a[0])))?.cgImage else {
                throw Failure(description: "read \(a[0])")
            }
            let ov = OverlayController(screen: screen, base: img, mode: .editResult, windows: [], pxPerPt: screen.backingScaleFactor)
            app.present(ov)
            let sel = CGRect(x: 0, y: 0, width: img.width, height: img.height)
            let marks = [Annotation(tool: .arrow, start: CGPoint(x: 1500, y: 900), end: CGPoint(x: 900, y: 400), width: 6),
                         Annotation(tool: .blur, start: CGPoint(x: 700, y: 150), end: CGPoint(x: 1500, y: 260), width: 6)]
            ov.canvas.debugSet(selection: sel, annotations: marks, tool: .rect)
            try await Task.sleep(nanoseconds: 700_000_000)
            let ui = try await Capture.screen(screen, cursor: false)
            ov.close()
            try write(ui, a[1])
        case "status":
            log("bundle \(Bundle.main.bundlePath), login item status \(SMAppService.mainApp.status.rawValue) (1 = enabled)")
        case "record":   // record X Y W H OUTDIR — 3 s video with cursor moves and two bubbles, then frames
            let rect = CGRect(x: num(0), y: num(1), width: num(2), height: num(3))
            let out = a[4]
            let done: URL? = try await withCheckedThrowingContinuation { c in
                app.startRecording(screen: screen, rect: rect) { c.resume(returning: $0) }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    for i in 0...30 {   // sweep the cursor across the region
                        let t = CGFloat(i) / 30
                        mouse(.mouseMoved, Screens.quartzPoint(CGPoint(x: rect.minX + rect.width * (0.1 + 0.8 * t),
                                                                       y: rect.minY + rect.height * (0.3 + 0.4 * t)), on: screen))
                        try? await Task.sleep(nanoseconds: 33_000_000)
                    }
                    let c1 = Screens.cocoaRect(CGRect(x: rect.midX, y: rect.midY, width: 0, height: 0), on: screen).origin
                    app.debugBubble(at: c1)
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    app.debugBubble(at: CGPoint(x: c1.x - 120, y: c1.y + 60))
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    app.stopRecording()
                }
            }
            guard let src = done else { throw Failure(description: "no video") }
            let dst = URL(fileURLWithPath: out).appendingPathComponent("rec.mp4")
            try? FileManager.default.removeItem(at: dst)
            try FileManager.default.moveItem(at: src, to: dst)
            let asset = AVURLAsset(url: dst)
            let dur = try await asset.load(.duration)
            let track = try await asset.loadTracks(withMediaType: .video).first
            let size = try await track?.load(.naturalSize) ?? .zero
            let fps = try await track?.load(.nominalFrameRate) ?? 0
            log(String(format: "video %.0fx%.0f, %.2f s, ~%.0f fps, %d KB", size.width, size.height, dur.seconds, fps,
                       ((try? FileManager.default.attributesOfItem(atPath: dst.path)[.size] as? Int) ?? 0) / 1024))
            let gen = AVAssetImageGenerator(asset: asset)
            gen.requestedTimeToleranceBefore = .zero
            gen.requestedTimeToleranceAfter = .zero
            // Contact sheet: 16 frames, 0.1 s apart, around the two bubbles (centre crop of each frame).
            let cell = CGSize(width: 350, height: 225)
            let sheet = Stitcher.context(Int(cell.width) * 4, Int(cell.height) * 4, CGColorSpace(name: CGColorSpace.sRGB))!
            for i in 0..<16 {
                let t = min(1.4 + Double(i) * 0.1, dur.seconds - 0.05)
                let img = try await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
                let crop = img.cropping(to: CGRect(x: img.width / 2 - 350, y: img.height / 2 - 225, width: 700, height: 450))!
                sheet.draw(crop, in: CGRect(x: CGFloat(i % 4) * cell.width, y: CGFloat(3 - i / 4) * cell.height,
                                            width: cell.width, height: cell.height))
            }
            try write(sheet.makeImage()!, "\(out)/sheet.png")
        case "copy":
            let before = NSPasteboard.general.changeCount
            key(kVK_ANSI_C, [.maskCommand])
            try await saveClipboard(after: before, to: a[0])
        case "e2e-window":
            let p = CGPoint(x: num(0), y: num(1))
            let before = NSPasteboard.general.changeCount
            key(kVK_ANSI_9, [.maskCommand, .maskShift])
            try await waitOverlayTimed()
            mouse(.mouseMoved, p)
            try await Task.sleep(nanoseconds: 150_000_000)
            mouse(.leftMouseDown, p)
            mouse(.leftMouseUp, p)
            try await Task.sleep(nanoseconds: 400_000_000)
            key(kVK_ANSI_C, [.maskCommand])
            try await saveClipboard(after: before, to: a[2])
        default:
            throw Failure(description: "unknown self-test \(kind)")
        }
    }

    static func luma(_ img: CGImage, _ x: Int, _ y: Int) -> Int {
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.draw(img, in: CGRect(x: -x, y: -(img.height - 1 - y), width: img.width, height: img.height))
        return (Int(px[0]) + Int(px[1]) + Int(px[2])) / 3
    }

    static func sampleMarks(_ sel: CGRect, _ s: CGFloat) -> [Annotation] {
        let w = 3 * s
        func p(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint { CGPoint(x: sel.minX + sel.width * fx, y: sel.minY + sel.height * fy) }
        return [
            Annotation(tool: .blur, start: p(0.05, 0.08), end: p(0.45, 0.35), width: w),
            Annotation(tool: .arrow, start: p(0.15, 0.85), end: p(0.42, 0.5), width: w),
            Annotation(tool: .rect, start: p(0.55, 0.1), end: p(0.95, 0.45), width: w),
            Annotation(tool: .line, start: p(0.55, 0.7), end: p(0.95, 0.9), width: w),
        ]
    }

    // MARK: synthetic input (needs Accessibility for 2pic)

    static func key(_ code: Int, _ flags: CGEventFlags) {
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
    }

    static func mouse(_ type: CGEventType, _ p: CGPoint) {
        let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
        e?.flags = []   // otherwise a preceding synthetic ⌘⇧ can leak in as Shift (45° snapping)
        e?.post(tap: .cghidEventTap)
    }

    static func dragMouse(_ a: CGPoint, _ b: CGPoint) async throws {
        mouse(.mouseMoved, a)
        try await Task.sleep(nanoseconds: 100_000_000)
        mouse(.leftMouseDown, a)
        for i in 1...12 {
            let t = CGFloat(i) / 12
            mouse(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            try await Task.sleep(nanoseconds: 16_000_000)
        }
        mouse(.leftMouseUp, b)
    }

    static func waitOverlayTimed() async throws {
        let t0 = Date()
        guard try await waitForOtherOverlay(timeout: 5, poll: 20_000_000) else { throw Failure(description: "overlay did not appear") }
        log(String(format: "overlay appeared %.0f ms after the hotkey", Date().timeIntervalSince(t0) * 1000))
        try await Task.sleep(nanoseconds: 200_000_000)
    }

    static func waitForOtherOverlay(timeout: TimeInterval, poll: UInt64 = 250_000_000) async throws -> Bool {
        let me = ProcessInfo.processInfo.processIdentifier
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            let info = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
            let found = info.contains { w in
                (w[kCGWindowOwnerName as String] as? String) == "2pic" &&
                (w[kCGWindowOwnerPID as String] as? Int32) != me &&
                ((w[kCGWindowLayer as String] as? Int) ?? 0) == Int(CGWindowLevelForKey(.overlayWindow))
            }
            if found { return true }
            try await Task.sleep(nanoseconds: poll)
        }
        return false
    }

    static func saveClipboard(after count: Int, to path: String) async throws {
        for _ in 0..<40 {
            if NSPasteboard.general.changeCount != count, let d = NSPasteboard.general.data(forType: .png) {
                try d.write(to: URL(fileURLWithPath: path))
                if let rep = NSBitmapImageRep(data: d) {
                    var red = 0
                    for y in stride(from: 0, to: rep.pixelsHigh, by: 2) { for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                        if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                           c.redComponent > 0.8, c.greenComponent < 0.4, c.blueComponent < 0.4 { red += 1 }
                    } }
                    log("clipboard PNG \(rep.pixelsWide)x\(rep.pixelsHigh), annotation-red pixels: \(red) → \(path)")
                }
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw Failure(description: "clipboard did not change")
    }
}
#endif
