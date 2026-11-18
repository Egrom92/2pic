import AppKit
import ApplicationServices

/// A window that a click can take: its frame and, for a browser, the page area without tabs, address bar and
/// bookmarks. Image pixels, top-left origin.
struct WindowTarget: Equatable {
    var frame: CGRect
    var page: CGRect? = nil
    var windowID: CGWindowID? = nil   // to take the window on its own, without what lies over it
    var full: CGRect? = nil           // the whole window, also the part off this screen

    /// What the pointer at `p` highlights: the page when it is over the page, otherwise the whole window.
    func target(at p: CGPoint) -> CGRect { page.map { $0.contains(p) ? $0 : frame } ?? frame }
}

/// Finds the page area of browser windows through the Accessibility API: every browser engine (WebKit, Blink,
/// Gecko) shows its page to macOS as an element with the role AXWebArea, so this works in Safari, Chrome, Edge,
/// Firefox, Arc, Brave, Opera, Vivaldi, Yandex and others without knowing how each one draws its toolbars.
/// Needs Accessibility for 2pic; without it windows are taken whole, as before.
enum BrowserPage {
    /// Known browsers plus every app that says it opens https links.
    static let browsers: Set<String> = {
        var ids: Set<String> = [
            "com.apple.Safari", "com.apple.SafariTechnologyPreview",
            "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
            "org.chromium.Chromium", "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev",
            "com.brave.Browser", "company.thebrowser.Browser", "company.thebrowser.dia",
            "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly",
            "com.operasoftware.Opera", "com.operasoftware.OperaGX", "com.vivaldi.Vivaldi",
            "ru.yandex.desktop.yandex-browser", "app.zen-browser.zen", "org.torproject.torbrowser",
            "net.waterfox.waterfox", "com.duckduckgo.macos.browser", "com.kagi.kagimacOS", "com.naver.Whale",
        ]
        if let u = URL(string: "https://example.com") {
            for app in NSWorkspace.shared.urlsForApplications(toOpen: u) {
                if let id = Bundle(url: app)?.bundleIdentifier { ids.insert(id) }
            }
        }
        return ids
    }()

    static func isBrowser(pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier.map(browsers.contains) ?? false
    }

    /// The page area of the window with this frame (global points, top-left origin), or nil: not trusted,
    /// no page found, or the page fills the window anyway (full screen without toolbars).
    static func pageRect(pid: pid_t, window: CGRect) -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        guard let win = (attr(app, kAXWindowsAttribute) as? [AXUIElement])?.first(where: { w in
            frame(w).map { abs($0.minX - window.minX) < 3 && abs($0.minY - window.minY) < 3 &&
                           abs($0.width - window.width) < 3 && abs($0.height - window.height) < 3 } ?? false
        }) else { return nil }

        // Breadth first: the page is shallow, the toolbars come before it. Don't look inside pages (frames,
        // ads, embedded documents are web areas too).
        var queue: [(AXUIElement, Int)] = [(win, 0)], head = 0
        var page: CGRect?, bars: [CGRect] = []
        while head < queue.count && head < 800 {
            let (e, depth) = queue[head]; head += 1
            let role = attr(e, kAXRoleAttribute) as? String ?? ""
            if role == "AXWebArea" {
                if let f = frame(e)?.intersection(window), !f.isNull, f.width * f.height > (page.map { $0.width * $0.height } ?? 0) {
                    page = f
                }
                continue
            }
            // A bar is a strip: Safari's tab group, for one, holds the whole window and is no bar.
            if role == "AXToolbar" || role == "AXTabGroup", let f = frame(e), f.height < window.height * 0.3 { bars.append(f) }
            if depth < 16, let kids = attr(e, kAXChildrenAttribute) as? [AXUIElement] {
                queue += kids.map { ($0, depth + 1) }
            }
        }
        // Chromium browsers (Chrome, Edge, Brave, Opera…) build the page's accessibility tree only for screen
        // readers, so there is no web area to find; their address bar and bookmarks bar are toolbars, though:
        // the page is everything below the lowest toolbar at the top of the window.
        if page == nil {
            let top = bars.filter { $0.minY >= window.minY - 1 && $0.minY < window.minY + window.height * 0.35
                                    && $0.width > window.width / 2 }
                          .map(\.maxY).max()
            if let t = top, t < window.maxY - 100 {
                page = CGRect(x: window.minX, y: t, width: window.width, height: window.maxY - t)
            }
        }
        guard var p = page else { return nil }
        // Some browsers (Safari) let the page run on under a see-through toolbar: start below the bars on top.
        for b in bars where b.minY < p.minY + 200 && b.maxY > p.minY && b.maxY < p.maxY - 100
                        && b.width > p.width / 2 && b.minX < p.maxX && b.maxX > p.minX {
            p = CGRect(x: p.minX, y: b.maxY, width: p.width, height: p.maxY - b.maxY)
        }
        guard p.width >= 150, p.height >= 100, p.width * p.height >= window.width * window.height * 0.2,
              p.minY - window.minY >= 8 else { return nil }
        return p.integral
    }

    /// The window's accessibility tree, a few levels deep: role and frame. For the log when no page is found.
    static func outline(pid: pid_t, window: CGRect, depth maxDepth: Int = 6) -> String {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        guard let win = (attr(app, kAXWindowsAttribute) as? [AXUIElement])?.first(where: { w in
            frame(w).map { abs($0.minX - window.minX) < 3 && abs($0.minY - window.minY) < 3 } ?? false
        }) else { return "no AX window (trusted: \(AXIsProcessTrusted()))" }
        var out: [String] = [], count = 0
        func walk(_ e: AXUIElement, _ d: Int) {
            count += 1
            if count > 150 { return }
            let role = attr(e, kAXRoleAttribute) as? String ?? "?"
            let f = frame(e).map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height))" } ?? "-"
            out.append(String(repeating: "  ", count: d) + role + " " + f)
            guard d < maxDepth, role != "AXWebArea" else { return }
            for c in (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { walk(c, d + 1) }
        }
        walk(win, 0)
        return out.joined(separator: "\n")
    }

    private static func attr(_ e: AXUIElement, _ a: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v : nil
    }

    private static func frame(_ e: AXUIElement) -> CGRect? {
        guard let p = attr(e, kAXPositionAttribute), let s = attr(e, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &pt), AXValueGetValue(s as! AXValue, .cgSize, &sz) else { return nil }
        return CGRect(origin: pt, size: sz)
    }
}
