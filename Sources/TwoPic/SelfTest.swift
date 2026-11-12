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
        // Self-tests keep their log and statistics in a temporary folder: the real ones stay untouched.
        DiagPaths.useTemporary(FileManager.default.temporaryDirectory
            .appendingPathComponent("2pic-selftest-\(ProcessInfo.processInfo.processIdentifier)"))
        MainActor.assumeIsolated { Usage.reload() }   // called from applicationDidFinishLaunching, on the main thread
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
            log("bundle \(Bundle.main.bundlePath), login item status \(SMAppService.mainApp.status.rawValue) (1 = enabled), save folder «\(Settings.saveFolderName)», localization \(Bundle.main.preferredLocalizations)")
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
        case "ui":   // ui OUTDIR — offscreen checks of the editor: synthetic screen, synthetic clicks, no real input
            try await UICheck.run(outDir: a[0])
        case "diag":   // diag OUTDIR — log rotation, usage counters and report, crash detection
            try await DiagCheck.run(outDir: a[0])
        case "telemetry":   // telemetry BASEURL KEY — sending to a running server (server/test_server.py --app runs it)
            try await TelemetryCheck.run(base: a[0], key: a[1])
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
/// Editor checks that need neither the screen nor the real mouse: a canvas in an invisible window,
/// a synthetic "screen" with two windows, clicks sent straight to that window.
@MainActor
enum UICheck {
    static let s: CGFloat = 2   // pixels per point
    static var failures = 0

    static func check(_ ok: Bool, _ what: String) {
        SelfTest.log((ok ? "OK    " : "FAIL  ") + what)
        if !ok { failures += 1 }
    }

    static func run(outDir: String) async throws {
        let size = CGSize(width: 900, height: 560)
        let front = CGRect(x: 120 * s, y: 80 * s, width: 420 * s, height: 300 * s)
        let back = CGRect(x: 480 * s, y: 200 * s, width: 360 * s, height: 280 * s)
        let base = syntheticScreen(size, front: front, back: back)
        let canvas = CanvasView(frame: CGRect(origin: .zero, size: size), base: base, pxPerPt: s, mode: .capture,
                                windows: [front, back])
        let win = NSWindow(contentRect: CGRect(origin: CGPoint(x: -30000, y: -30000), size: size),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        win.contentView = canvas

        // Hover right away, front window wins where two overlap; a click without moving takes that window.
        canvas.pointerMoved(to: CGPoint(x: 500, y: 250))
        check(canvas.hover == front, "pointer over two windows highlights the front one")
        canvas.pointerMoved(to: CGPoint(x: 700, y: 400))
        check(canvas.hover == back, "pointer over the back window highlights it")
        canvas.pointerMoved(to: CGPoint(x: 300, y: 200))
        click(win, CGPoint(x: 300, y: 200))
        check(canvas.selection == front, "click without moving selects the window under the cursor")
        check(canvas.tool == .arrow, "arrow is the tool after selecting")

        // Edges and corners resize with a drawing tool active; just inside, the tool still draws.
        drag(win, CGPoint(x: 543, y: 230), CGPoint(x: 600, y: 230))
        check(canvas.selection?.maxX == 600 * s, "right edge drag resizes (arrow tool active)")
        drag(win, CGPoint(x: 120, y: 380), CGPoint(x: 100, y: 420))
        check(canvas.selection?.minX == 100 * s && canvas.selection?.maxY == 420 * s, "bottom-left corner drag resizes")
        let n0 = canvas.annotations.count
        drag(win, CGPoint(x: 110, y: 150), CGPoint(x: 200, y: 110))
        check(canvas.annotations.count == n0 + 1, "a drag starting 10 pt inside the edge draws an arrow")

        canvas.undo()
        check(canvas.annotations.count == n0, "undo removes the arrow")
        canvas.redo()
        check(canvas.annotations.count == n0 + 1, "redo brings it back")

        canvas.setTool(.counter)
        for x in [430, 480, 530] { click(win, CGPoint(x: CGFloat(x), y: 340)) }
        check(canvas.annotations.filter { $0.tool == .counter }.map(\.number) == [1, 2, 3], "numbered marks 1, 2, 3")
        canvas.undo()
        click(win, CGPoint(x: 560, y: 300))
        check(canvas.annotations.filter { $0.tool == .counter }.map(\.number) == [1, 2, 3], "after undo the next number is 3 again")

        // Text: click, type, Enter; click it again to edit, Esc; undo restores the first version.
        canvas.setTool(.text)
        click(win, CGPoint(x: 330, y: 300))
        check(canvas.textField != nil, "text tool: a click opens a text field")
        type(canvas, "Подпись 2pic")
        command(canvas, #selector(NSResponder.insertNewline(_:)))
        check(texts(canvas) == ["Подпись 2pic"] && canvas.textField == nil, "Enter turns the typed text into a mark")
        click(win, CGPoint(x: 340, y: 300))
        check(canvas.textField?.stringValue == "Подпись 2pic", "clicking a text opens it for editing")
        type(canvas, " ✓")
        command(canvas, #selector(NSResponder.cancelOperation(_:)))
        check(texts(canvas) == ["Подпись 2pic ✓"], "Esc finishes editing and keeps the text")
        canvas.undo()
        check(texts(canvas) == ["Подпись 2pic"], "undo returns the text before the edit")

        // Color and thickness from the palette.
        canvas.debugOpenPicker()
        guard let picker = canvas.subviews.compactMap({ $0 as? StylePicker }).first else { throw SelfTest.Failure(description: "no picker") }
        let buttons = picker.subviews.compactMap { $0 as? ToolButton }
        click(win, center(buttons[4], in: canvas))                 // blue
        click(win, center(buttons[MarkStyle.colors.count + 2], in: canvas))   // thick
        canvas.setTool(.rect)
        drag(win, CGPoint(x: 140, y: 250), CGPoint(x: 260, y: 330))
        let r = canvas.annotations.last
        check(r?.tool == .rect && r?.color == MarkStyle.colors[4] && r?.width == MarkStyle.lineWidths[2] * s,
              "the palette sets color (blue) and thickness (thick) for new marks")
        check(Settings.markColor == 4 && Settings.markSize == 2, "the chosen style is remembered")

        // A thin slip of the mouse in selection mode keeps the frame.
        canvas.setTool(nil)
        let kept = canvas.selection
        drag(win, CGPoint(x: 700, y: 520), CGPoint(x: 760, y: 521))
        check(canvas.selection == kept, "a thin accidental drag keeps the selection")

        // Pictures: the exported image, and the editor itself with the palette open and a text being typed.
        guard let out = canvas.render() else { throw SelfTest.Failure(description: "render") }
        try SelfTest.write(out, "\(outDir)/export.png")
        canvas.setTool(.text)
        click(win, CGPoint(x: 150, y: 140))
        let w0 = canvas.textField?.frame.width ?? 0
        type(canvas, "Пишу текст")
        let w1 = canvas.textField?.frame.width ?? 0
        check(w1 > w0 + 60, String(format: "the text field grows while typing (%.0f → %.0f pt)", w0, w1))
        let off = fieldTextOffset()
        SelfTest.log(String(format: "text in the field vs. the finished mark: dx %.2f, dy %.2f pt", off.x, off.y))
        check(abs(off.x) <= 0.75 && abs(off.y) <= 0.75, "typed text and the finished mark line up (no jump on Enter)")
        canvas.debugOpenPicker()
        if let ui = snapshot(canvas) { try SelfTest.write(ui, "\(outDir)/editor.png") }
        canvas.endTextEditing()

        // Text recognition on the clean window.
        if let crop = base.cropping(to: front) {
            let t0 = Date()
            let text = TextRecognizer.recognize(crop)
            SelfTest.log(String(format: "OCR (%.0f ms):\n", Date().timeIntervalSince(t0) * 1000) + text)
            check(text.contains("Привет") && text.contains("2pic"), "text recognition reads Russian and English")
        }
        Settings.markColor = 0
        Settings.markSize = 1

        // The result editor of a scrolling capture that stopped early: the notice above the picture.
        let tall = syntheticScreen(CGSize(width: 420, height: 900), front: CGRect(x: 40, y: 40, width: 760, height: 1700),
                                   back: CGRect(x: 0, y: 0, width: 1, height: 1))
        let ed = CanvasView(frame: CGRect(origin: .zero, size: size), base: tall, pxPerPt: s, mode: .editResult, windows: [])
        let edWin = NSWindow(contentRect: CGRect(origin: CGPoint(x: -30000, y: -30000), size: size),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        edWin.contentView = ed
        ed.showNotice("Прокрутка остановилась раньше конца: страница менялась во время съёмки. Снято до этого места.")
        let notice = ed.subviews.compactMap { $0 as? PillLabel }.last
        check(notice.map { $0.frame.minY >= 0 && $0.frame.maxY <= 36 && $0.frame.minX >= 0 && $0.frame.maxX <= size.width } ?? false,
              "the early-stop notice fits above the picture in the result editor")
        if let ui = snapshot(ed) { try SelfTest.write(ui, "\(outDir)/notice.png") }

        // The settings window, laid out but not shown.
        let sw = SettingsController.shared.windowForTests()
        if let v = sw.contentView {
            v.layoutSubtreeIfNeeded()
            sw.displayIfNeeded()
            v.display()
            CATransaction.flush()
            if let layer = v.layer,
               let ctx = Stitcher.context(Int(v.bounds.width * s), Int(v.bounds.height * s), CGColorSpace(name: CGColorSpace.sRGB)) {
                ctx.setFillColor(NSColor.windowBackgroundColor.cgColor)
                ctx.fill(CGRect(x: 0, y: 0, width: v.bounds.width * s, height: v.bounds.height * s))
                ctx.scaleBy(x: s, y: s)
                layer.render(in: ctx)
                if let img = ctx.makeImage() { try SelfTest.write(img, "\(outDir)/settings.png") }
            }
            for sub in allSubviews(v) where sub is NSTextField || sub is NSButton || sub is NSSegmentedControl {
                SelfTest.log("  settings control \(Swift.type(of: sub)) \(NSStringFromRect(sub.convert(sub.bounds, to: v))) "
                             + ((sub as? NSTextField)?.stringValue ?? (sub as? NSButton)?.title ?? ""))
            }
        }
        // What the clicks above should have counted.
        let expect: [(String, Int)] = [("select.window", 1), ("frame.resize", 2), ("mark.arrow", 1), ("undo", 2), ("redo", 1),
                                       ("mark.counter", 4), ("mark.text", 1), ("text.reedit", 1), ("style.color.4", 1),
                                       ("style.size.2", 1), ("style.picker", 1)]
        let wrong = expect.filter { Usage.value($0.0) < $0.1 }.map { "\($0.0)=\(Usage.value($0.0)) (want ≥ \($0.1))" }
        check(wrong.isEmpty, "usage counters follow the editor actions" + (wrong.isEmpty ? "" : ": " + wrong.joined(separator: ", ")))
        try Usage.report().write(toFile: "\(outDir)/usage-report.txt", atomically: true, encoding: .utf8)
        SelfTest.log(failures == 0 ? "ALL UI CHECKS OK" : "\(failures) UI CHECK(S) FAILED")
    }

    static func allSubviews(_ v: NSView) -> [NSView] { v.subviews + v.subviews.flatMap(allSubviews) }

    static func texts(_ c: CanvasView) -> [String] { c.annotations.filter { $0.tool == .text }.map(\.text) }

    static func type(_ c: CanvasView, _ s: String) {
        if let ed = c.textField?.currentEditor() as? NSTextView {
            ed.insertText(s, replacementRange: NSRange(location: NSNotFound, length: 0))
        } else {
            check(false, "the text field has a field editor")
        }
    }

    static func command(_ c: CanvasView, _ sel: Selector) {
        (c.textField?.currentEditor() as? NSTextView)?.doCommand(by: sel)
    }

    static func center(_ v: NSView, in c: NSView) -> CGPoint {
        let r = v.convert(v.bounds, to: c)
        return CGPoint(x: r.midX, y: r.midY)
    }

    /// `p` in canvas points (top-left origin).
    static func event(_ type: NSEvent.EventType, _ p: CGPoint, _ win: NSWindow) -> NSEvent {
        let h = win.contentView?.bounds.height ?? 0
        return NSEvent.mouseEvent(with: type, location: CGPoint(x: p.x, y: h - p.y), modifierFlags: [],
                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: win.windowNumber,
                                  context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    /// An invisible window doesn't dispatch mouse events, so do what NSWindow does: the view under the point
    /// gets the mouse-down, and the same view gets the drags and the mouse-up.
    static var target: NSView?
    static func send(_ e: NSEvent, _ win: NSWindow) {
        switch e.type {
        case .leftMouseDown:
            let p = win.contentView?.superview?.convert(e.locationInWindow, from: nil) ?? e.locationInWindow
            target = win.contentView?.hitTest(p)
            target?.mouseDown(with: e)
        case .leftMouseDragged: target?.mouseDragged(with: e)
        case .leftMouseUp: target?.mouseUp(with: e); target = nil
        default: break
        }
    }

    static func click(_ win: NSWindow, _ p: CGPoint) {
        send(event(.leftMouseDown, p, win), win)
        send(event(.leftMouseUp, p, win), win)
    }

    static func drag(_ win: NSWindow, _ a: CGPoint, _ b: CGPoint) {
        send(event(.leftMouseDown, a, win), win)
        for i in 1...8 {
            let t = CGFloat(i) / 8
            send(event(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), win), win)
        }
        send(event(.leftMouseUp, b, win), win)
    }

    /// The view's layer tree as an image (Retina).
    static func snapshot(_ v: NSView) -> CGImage? {
        v.layoutSubtreeIfNeeded()
        v.displayIfNeeded()
        CATransaction.flush()
        guard let layer = v.layer,
              let ctx = Stitcher.context(Int(v.bounds.width * s), Int(v.bounds.height * s), CGColorSpace(name: CGColorSpace.sRGB))
        else { return nil }
        ctx.translateBy(x: 0, y: v.bounds.height * s)   // the canvas is flipped: render it upright
        ctx.scaleBy(x: s, y: -s)
        layer.render(in: ctx)
        return ctx.makeImage()
    }

    /// Where a text field (set up like the text tool's) draws its glyphs, minus where the finished mark draws
    /// them, both placed at the same origin. Should be ~0 once `fieldInset` is right.
    static func fieldTextOffset() -> CGPoint {
        let pt: CGFloat = 18, str = "Пишу Hg"
        let f = NSTextField(string: str)
        CanvasView.configureTextField(f)
        f.font = Renderer.textFont(pt)
        f.textColor = .black
        f.sizeToFit()
        let host = FlippedHost(frame: CGRect(x: 0, y: 0, width: 300, height: 80))
        host.addSubview(f)
        f.setFrameOrigin(CGPoint(x: 20 - CanvasView.fieldInsetForTests.x, y: 20 - CanvasView.fieldInsetForTests.y))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return CGPoint(x: 99, y: 99) }
        host.cacheDisplay(in: host.bounds, to: rep)
        let k = CGFloat(rep.pixelsWide) / host.bounds.width
        let field = inkBox(rep.cgImage!).applying(CGAffineTransform(scaleX: 1 / k, y: 1 / k))

        // The mark, at the same origin (20, 20) pt, drawn at 2 px per pt like a Retina screenshot.
        let ctx = Stitcher.context(600, 160, CGColorSpace(name: CGColorSpace.sRGB))!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 600, height: 160))
        ctx.translateBy(x: 0, y: 160)
        ctx.scaleBy(x: 1, y: -1)
        var a = Annotation(tool: .text, start: CGPoint(x: 40, y: 40), end: .zero, width: 4,
                           color: CGColor(gray: 0, alpha: 1))
        a.size = pt * 2
        a.text = str
        Renderer.draw(a, in: ctx, blurred: nil)
        let mark = inkBox(ctx.makeImage()!).applying(CGAffineTransform(scaleX: 0.5, y: 0.5))
        return CGPoint(x: field.minX - mark.minX, y: field.minY - mark.minY)
    }

    final class FlippedHost: NSView {
        override var isFlipped: Bool { true }
        override func draw(_ r: NSRect) { NSColor.white.setFill(); r.fill() }
    }

    /// Bounding box (top-left origin, pixels) of the dark pixels of an image on white.
    static func inkBox(_ img: CGImage) -> CGRect {
        let w = img.width, h = img.height
        var px = [UInt8](repeating: 255, count: w * h)
        px.withUnsafeMutableBytes { b in
            let c = CGContext(data: b.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            c.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        var x0 = w, y0 = h, x1 = -1, y1 = -1
        for y in 0..<h { for x in 0..<w where px[y * w + x] < 110 {
            x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
        } }
        return x1 < 0 ? .null : CGRect(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1)
    }

    /// A desktop with two windows (`back` behind `front`), the front one with some text.
    static func syntheticScreen(_ size: CGSize, front: CGRect, back: CGRect) -> CGImage {
        let w = Int(size.width * s), h = Int(size.height * s)
        let ctx = Stitcher.context(w, h, CGColorSpace(name: CGColorSpace.sRGB))!
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGradient(starting: NSColor(srgbRed: 0.22, green: 0.33, blue: 0.55, alpha: 1),
                   ending: NSColor(srgbRed: 0.55, green: 0.38, blue: 0.6, alpha: 1))!
            .draw(in: NSRect(x: 0, y: 0, width: w, height: h), angle: 90)
        func window(_ r: CGRect, _ lines: [String]) {
            NSColor(white: 0.97, alpha: 1).setFill()
            NSBezierPath(roundedRect: r, xRadius: 20, yRadius: 20).fill()
            NSColor(white: 0.88, alpha: 1).setFill()
            NSBezierPath(rect: CGRect(x: r.minX, y: r.minY + 20, width: r.width, height: 36)).fill()
            for (i, c) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                c.setFill()
                NSBezierPath(ovalIn: CGRect(x: r.minX + 24 + CGFloat(i) * 36, y: r.minY + 20, width: 24, height: 24)).fill()
            }
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 30), .foregroundColor: NSColor(white: 0.15, alpha: 1)]
            for (i, l) in lines.enumerated() {
                NSAttributedString(string: l, attributes: attrs).draw(at: CGPoint(x: r.minX + 40, y: r.minY + 90 + CGFloat(i) * 52))
            }
        }
        window(back, ["Окно позади", "Background window"])
        window(front, ["Привет! Это проверка.", "Screenshot tool 2pic", "Сумма: 1 250,00 ₽"])
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()!
    }
}
/// Diagnostics checks, all in the temporary folder set up by `SelfTest.start`.
@MainActor
enum DiagCheck {
    static func run(outDir: String) async throws {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            SelfTest.log((ok ? "OK    " : "FAIL  ") + what)
            if !ok { failures += 1 }
        }
        let fm = FileManager.default

        // Rotation: a small limit, many lines → the current file plus exactly `keep` older ones.
        Log.maxSize = 4000
        for i in 0..<400 { Log.info("test", "line \(i) " + String(repeating: "x", count: 40)) }
        Log.flush()
        let rotated = (1...Log.keep).map { fm.fileExists(atPath: Log.rotatedURL($0).path) }
        let size = (try? fm.attributesOfItem(atPath: Log.fileURL.path)[.size] as? Int) ?? -1
        check(rotated.allSatisfy { $0 } && !fm.fileExists(atPath: Log.rotatedURL(Log.keep + 1).path) && (0...5000).contains(size),
              "the log rotates: current \(size) bytes + \(Log.keep) older files, no more")
        Log.maxSize = 1_000_000

        // Errors are counted.
        let before = Usage.value("error")
        Log.error("test", "a deliberate test error")
        try await Task.sleep(nanoseconds: 100_000_000)
        check(Usage.value("error") == before + 1, "an error in the log is counted in the statistics")

        // Counters survive a restart.
        Usage.count("finish.copy", 3)
        Usage.count("copy.via.enter", 2)
        Usage.count("copy.via.button")
        Usage.count("mark.arrow", 5)
        Usage.measure("editor.seconds", 4)
        Usage.measure("editor.seconds", 8)
        Usage.save()
        Usage.reload()
        check(Usage.value("finish.copy") == 3 && Usage.value("mark.arrow") == 5, "counters are saved and read back")
        let report = Usage.report()
        check(report.contains("Как копируют") && report.contains("в среднем 6.0 с") && report.contains("Ни разу не использовалось")
              && report.contains("Двойной клик"), "the report has sections, averages and the never-used list")

        // A crash: a run that never quit (its marker is left) and macOS's crash report for it.
        try fm.createDirectory(at: DiagPaths.support, withIntermediateDirectories: true)
        fm.createFile(atPath: CrashWatch.marker.path, contents: Data("1234".utf8))
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: CrashWatch.marker.path)
        try fm.createDirectory(at: DiagPaths.crashReports, withIntermediateDirectories: true)
        let ips = #"{"app_name":"2pic","bug_type":"309"}"# + "\n" + #"""
        {"exception":{"type":"EXC_CRASH","signal":"SIGABRT"},
         "asi":{"CoreFoundation":["*** Terminating app due to uncaught exception 'NSInternalInconsistencyException', reason: 'Cannot call method when status is 3'"]},
         "faultingThread":0,"threads":[{"frames":[{"symbol":"__pthread_kill"},{"symbol":"abort"},{"symbol":"-[AVAssetWriter startWriting]"}]}]}
        """#
        try ips.write(to: DiagPaths.crashReports.appendingPathComponent("2pic-2026-11-13-010203.ips"), atomically: true, encoding: .utf8)
        try "unrelated".write(to: DiagPaths.crashReports.appendingPathComponent("Safari-2026-11-13-010203.ips"), atomically: true, encoding: .utf8)
        let crashesBefore = Usage.value("crash.previous")
        CrashWatch.start()
        Log.flush()
        let log = (try? String(contentsOf: Log.fileURL, encoding: .utf8)) ?? ""
        check(Usage.value("crash.previous") == crashesBefore + 1 && log.contains("ended without quitting normally"),
              "a run that didn't quit normally is noticed at the next start")
        check(log.contains("2pic-2026-11-13-010203.ips: EXC_CRASH SIGABRT") && log.contains("NSInternalInconsistencyException")
              && log.contains("-[AVAssetWriter startWriting]") && !log.contains("Safari"),
              "its crash report is summarized in the log (type, reason, where), other apps' reports are ignored")
        check(fm.fileExists(atPath: CrashWatch.marker.path), "this run is marked as running")
        CrashWatch.cleanExit()
        check(!fm.fileExists(atPath: CrashWatch.marker.path), "a normal quit clears the mark")

        try report.write(toFile: "\(outDir)/usage-report.txt", atomically: true, encoding: .utf8)
        try log.write(toFile: "\(outDir)/log-sample.txt", atomically: true, encoding: .utf8)
        SelfTest.log(failures == 0 ? "ALL DIAG CHECKS OK" : "\(failures) DIAG CHECK(S) FAILED")
    }
}
/// The app side of sending to the server, against a real server started by server/test_server.py.
@MainActor
enum TelemetryCheck {
    static func run(base: String, key: String) async throws {
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            SelfTest.log((ok ? "OK    " : "FAIL  ") + what)
            if !ok { failures += 1 }
        }
        func waitEmpty(_ seconds: Double) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                if Telemetry.queued == 0 { return true }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            return Telemetry.queued == 0
        }
        defer {
            for k in ["telemetryEnabled", "telemetryURL", "telemetryToken", "installID"] { UserDefaults.standard.removeObject(forKey: k) }
        }

        Telemetry.enabled = false
        Telemetry.endpoint = base
        Telemetry.token = key
        Telemetry.reload()
        Log.error("selftest", "an error while sending is off")
        try await Task.sleep(nanoseconds: 300_000_000)
        check(Telemetry.queued == 0, "switched off: nothing is queued")

        Telemetry.endpoint = "http://example.com"
        Telemetry.enabled = true
        check(!Telemetry.isOn, "a plain http:// address (not local) is not accepted")
        Telemetry.endpoint = base

        check(Telemetry.isOn, "switched on with an address and a key")
        Telemetry.start()   // session + statistics
        Usage.count("finish.copy", 2)
        Telemetry.snapshotStats()
        Log.info("scroll", "frame 3: appended")
        Log.error("scroll", "stopped early, frame 4: best offset matched too weakly (selftest)")
        check(await waitEmpty(12), "an error is sent within seconds, with the session and statistics (queue empty)")

        let r = await Telemetry.test()
        check(r.ok, "«Проверить соединение» succeeds: \(r.text)")

        Telemetry.token = "wrong-key-wrong-key-wrong-key"
        let bad = await Telemetry.test()
        check(!bad.ok && bad.text.contains("ключ"), "a wrong key is reported as such: \(bad.text)")
        Log.error("output", "save failed (selftest, kept while the key is wrong)")
        try await Task.sleep(nanoseconds: 300_000_000)
        Telemetry.flush(force: true)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        check(Telemetry.queued >= 1 && FileManager.default.fileExists(atPath: Telemetry.outboxURL.path),
              "refused: the error stays queued on disk (\(Telemetry.queued))")
        Telemetry.token = key
        Telemetry.reload()   // as after a restart: read back from disk
        check(Telemetry.queued >= 1, "the queue survives a restart")
        Telemetry.flush(force: true)
        check(await waitEmpty(8), "with the right key the queued error goes out")
        SelfTest.log(failures == 0 ? "ALL TELEMETRY CHECKS OK" : "\(failures) TELEMETRY CHECK(S) FAILED")
    }
}
#endif
