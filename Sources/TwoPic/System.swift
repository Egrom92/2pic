import AppKit
import Carbon.HIToolbox
import ScreenCaptureKit
import UniformTypeIdentifiers

// MARK: - Global hotkeys (Carbon): no event tap, no keystroke monitoring, zero idle CPU.

final class HotKeys {
    static let shared = HotKeys()
    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var nextID: UInt32 = 1
    private var installed = false

    @discardableResult
    func register(keyCode: Int, modifiers: Int, _ handler: @escaping () -> Void) -> UInt32? {
        install()
        let id = nextID; nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers),
                                         EventHotKeyID(signature: 0x32504943 /* 2PIC */, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            NSLog("2pic: hotkey %d registration failed (%d)", keyCode, status)
            return nil
        }
        refs[id] = ref
        handlers[id] = handler
        return id
    }

    func unregister(_ id: UInt32?) {
        guard let id, let ref = refs.removeValue(forKey: id) else { return }
        UnregisterEventHotKey(ref)
        handlers[id] = nil
    }

    private func install() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { HotKeys.shared.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

// MARK: - Screens

enum Screens {
    static func displayID(_ s: NSScreen) -> CGDirectDisplayID {
        (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }

    static func underMouse() -> NSScreen {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// Converts a rect in screen-local top-left points to Cocoa global coordinates.
    static func cocoaRect(_ r: CGRect, on s: NSScreen) -> CGRect {
        CGRect(x: s.frame.minX + r.minX, y: s.frame.maxY - r.maxY, width: r.width, height: r.height)
    }

    /// Converts a screen-local top-left point to Quartz global (top-left of the main display).
    static func quartzPoint(_ p: CGPoint, on s: NSScreen) -> CGPoint {
        let b = CGDisplayBounds(displayID(s))
        return CGPoint(x: b.minX + p.x, y: b.minY + p.y)
    }
}

// MARK: - Capture (ScreenCaptureKit)

enum CaptureError: Error { case noDisplay }

enum Capture {
    static func content() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    static func display(for screen: NSScreen, in content: SCShareableContent) throws -> SCDisplay {
        let id = Screens.displayID(screen)
        guard let d = content.displays.first(where: { $0.displayID == id }) ?? content.displays.first else {
            throw CaptureError.noDisplay
        }
        return d
    }

    static func config(rect: CGRect, scale: CGFloat, cursor: Bool = false) -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        c.sourceRect = rect
        c.width = Int((rect.width * scale).rounded())
        c.height = Int((rect.height * scale).rounded())
        c.showsCursor = cursor
        c.captureResolution = .best
        return c
    }

    /// Full-resolution image of the whole screen (Retina pixels).
    static func screen(_ s: NSScreen, cursor: Bool = false) async throws -> CGImage {
        let content = try await content()
        let filter = SCContentFilter(display: try display(for: s, in: content), excludingWindows: [])
        let cfg = config(rect: CGRect(origin: .zero, size: s.frame.size), scale: s.backingScaleFactor, cursor: cursor)
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
    }
}

/// Repeatedly grabs one region of the screen, leaving out 2pic's own windows.
final class RegionGrabber {
    private let filter: SCContentFilter
    private let cfg: SCStreamConfiguration

    init(screen: NSScreen, rect: CGRect) async throws {
        let content = try await Capture.content()
        let me = ProcessInfo.processInfo.processIdentifier
        let mine = content.windows.filter { $0.owningApplication?.processID == me }
        filter = SCContentFilter(display: try Capture.display(for: screen, in: content), excludingWindows: mine)
        cfg = Capture.config(rect: rect, scale: screen.backingScaleFactor)
    }

    func grab() async throws -> CGImage {
        try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
    }
}

// MARK: - Window rectangles for "click a window" selection

enum WindowList {
    /// Frames of normal app windows on `screen`, front to back, in image pixels (top-left origin).
    static func rects(on screen: NSScreen, pxPerPt: CGFloat) -> [CGRect] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let disp = CGDisplayBounds(Screens.displayID(screen))
        let local = CGRect(origin: .zero, size: disp.size)
        let me = ProcessInfo.processInfo.processIdentifier
        var out: [CGRect] = []
        for w in info {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? Int32, pid != me,
                  let bd = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: bd) else { continue }
            if let a = w[kCGWindowAlpha as String] as? Double, a < 0.05 { continue }
            if r.width < 40 || r.height < 40 { continue }
            let l = r.offsetBy(dx: -disp.minX, dy: -disp.minY).intersection(local)
            if l.isNull || l.width < 20 || l.height < 20 { continue }
            out.append(CGRect(x: l.minX * pxPerPt, y: l.minY * pxPerPt,
                              width: l.width * pxPerPt, height: l.height * pxPerPt).integral)
        }
        return out
    }
}

// MARK: - Output: clipboard and file

enum Output {
    static func encode(_ img: CGImage, type: UTType, dpi: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        let props: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    private static var tiffProvider: TIFFProvider?

    /// PNG goes on the clipboard right away; TIFF (for old apps) is produced only if someone asks.
    static func copy(_ img: CGImage, pxPerPt: CGFloat) {
        guard let png = encode(img, type: .png, dpi: 72 * pxPerPt) else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        let provider = TIFFProvider(image: img, dpi: 72 * pxPerPt)
        item.setDataProvider(provider, forTypes: [.tiff])
        tiffProvider = provider
        pb.writeObjects([item])
    }

    /// A fresh "2pic <date>.<ext>" path on the Desktop.
    static func desktopURL(ext: String) -> URL {
        let desk = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'в' HH.mm.ss"
        let base = "2pic \(f.string(from: Date()))"
        var url = desk.appendingPathComponent("\(base).\(ext)")
        var i = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = desk.appendingPathComponent("\(base) (\(i)).\(ext)"); i += 1
        }
        return url
    }

    @discardableResult
    static func save(_ img: CGImage, pxPerPt: CGFloat) -> URL? {
        guard let png = encode(img, type: .png, dpi: 72 * pxPerPt) else { return nil }
        let url = desktopURL(ext: "png")
        do { try png.write(to: url); return url } catch { NSLog("2pic: save failed: %@", "\(error)"); return nil }
    }

    /// Puts a file on the clipboard (⌘V in a messenger attaches it).
    static func copyFile(_ url: URL) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([url as NSURL])
    }

    final class TIFFProvider: NSObject, NSPasteboardItemDataProvider {
        let image: CGImage, dpi: CGFloat
        init(image: CGImage, dpi: CGFloat) { self.image = image; self.dpi = dpi }
        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
            if let d = Output.encode(image, type: .tiff, dpi: dpi) { item.setData(d, forType: type) }
        }
        func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
            if Output.tiffProvider === self { Output.tiffProvider = nil }
        }
    }
}

// MARK: - Synthetic scrolling and input (needs Accessibility)

enum Input {
    /// Positive = scroll the content down (towards the end of the page), negative = back up.
    static func scroll(points: CGFloat, at p: CGPoint) {
        let sign: Int32 = points < 0 ? 1 : -1
        var remaining = Int32(abs(points).rounded())
        while remaining > 0 {
            let d = min(remaining, 40)
            if let ev = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: sign * d, wheel2: 0, wheel3: 0) {
                ev.location = p
                ev.post(tap: .cghidEventTap)
            }
            remaining -= d
        }
    }
}

// MARK: - Small diagnostic log (~/Library/Logs/2pic.log), used for scrolling capture

enum DiagLog {
    static let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/2pic.log")
    static func write(_ s: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
        } else {
            try? line.data(using: .utf8)!.write(to: url)
        }
    }
}
