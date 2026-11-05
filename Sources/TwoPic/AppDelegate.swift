import AppKit
import Carbon.HIToolbox
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var loginItem: NSMenuItem?
    private(set) var overlay: OverlayController?
    private(set) var scroller: ScrollCapturer?
    private var recorder: RegionRecorder?
    private var recordHUD: RecordingHUD?
    private var stopItem: NSMenuItem?
    private var busy = false
    private var previousApp: NSRunningApplication?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--unregister-login") {   // used by uninstall.sh
            try? SMAppService.mainApp.unregister()
            NSApp.terminate(nil)
            return
        }
        if SelfTest.start(self) { return }
        setupMenu()
        HotKeys.shared.register(keyCode: kVK_ANSI_9, modifiers: cmdKey | shiftKey) { [weak self] in self?.captureArea() }
        HotKeys.shared.register(keyCode: kVK_ANSI_8, modifiers: cmdKey | shiftKey) { [weak self] in self?.captureScrolling() }
        enableLoginItemOnce()
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
    }

    // MARK: menu

    private func setupMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let img = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "2pic")
        img?.isTemplate = true
        item.button?.image = img
        let menu = NSMenu()
        menu.delegate = self
        let area = NSMenuItem(title: "Снимок области или окна", action: #selector(menuArea), keyEquivalent: "9")
        area.keyEquivalentModifierMask = [.command, .shift]
        let scroll = NSMenuItem(title: "Снимок с прокруткой", action: #selector(menuScroll), keyEquivalent: "8")
        scroll.keyEquivalentModifierMask = [.command, .shift]
        let login = NSMenuItem(title: "Запускать при входе в систему", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem = login
        let stop = NSMenuItem(title: "Остановить запись видео", action: #selector(menuStopRecording), keyEquivalent: "")
        stop.isHidden = true
        stopItem = stop
        for i in [stop, area, scroll, .separator(), login, .separator(),
                  NSMenuItem(title: "Выйти из 2pic", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")] {
            if i.action != #selector(NSApplication.terminate(_:)) { i.target = self }
            menu.addItem(i)
        }
        item.menu = menu
        statusItem = item
    }

    func menuWillOpen(_ menu: NSMenu) {
        loginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
        stopItem?.isHidden = recorder == nil
    }

    @objc private func menuArea() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.captureArea() } }
    @objc private func menuScroll() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.captureScrolling() } }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch {
            alert("Не получилось изменить автозапуск", "\(error.localizedDescription)\n\nПроверьте Системные настройки → Основные → Объекты входа.")
        }
    }

    private func enableLoginItemOnce() {
        let path = Bundle.main.bundlePath
        guard path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/") else { return }
        let key = "loginItemConfigured"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        do {
            try SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: key)
        } catch {
            NSLog("2pic: login item registration failed: %@", "\(error)")
        }
    }

    // MARK: capture flows

    @objc private func menuStopRecording() { stopRecording() }

    func captureArea() {
        if recorder != nil { stopRecording(); return }   // ⌘⇧9 while recording stops it
        if scroller != nil { return }
        startOverlay(mode: .capture)
    }

    func captureScrolling() {
        if let s = scroller { s.stop(); return }   // second ⌘⇧8 stops scrolling
        if recorder != nil { stopRecording(); return }
        guard ensureAccessibility() else { return }
        startOverlay(mode: .scrollSelect)
    }

    private func startOverlay(mode: OverlayMode) {
        guard overlay == nil, !busy, ensureScreenAccess() else { return }
        busy = true
        let screen = Screens.underMouse()
        previousApp = NSWorkspace.shared.frontmostApplication
        Task { @MainActor in
            defer { self.busy = false }
            do {
                let shot = try await Capture.screen(screen)
                let pxPerPt = CGFloat(shot.width) / screen.frame.width
                let windows = WindowList.rects(on: screen, pxPerPt: pxPerPt)
                self.present(OverlayController(screen: screen, base: shot, mode: mode, windows: windows, pxPerPt: pxPerPt))
            } catch {
                self.alert("Не удалось сделать снимок", "\(error.localizedDescription)\n\nЕсли вы только что выдали доступ к записи экрана — перезапустите 2pic.")
            }
        }
    }

    func present(_ ov: OverlayController) {
        ov.onFinish = { [weak self] ov, outcome in self?.finish(ov, outcome) }
        overlay = ov
        ov.show()
    }

    private func finish(_ ov: OverlayController, _ outcome: Outcome) {
        let canvas = ov.canvas
        ov.close()
        overlay = nil
        restoreFocus()
        let pxPerPt = canvas.pxPerPt
        switch outcome {
        case .cancel:
            break
        case .copy:
            DispatchQueue.main.async { if let img = canvas.render() { Output.copy(img, pxPerPt: pxPerPt) } }
        case .save:
            DispatchQueue.main.async { if let img = canvas.render() { Output.save(img, pxPerPt: pxPerPt) } }
        case .scroll(let rect):
            startScroll(screen: ov.screen, rect: rect)
        case .record(let rect):
            startRecording(screen: ov.screen, rect: rect)
        }
    }

    func startScroll(screen: NSScreen, rect: CGRect, completion: ((CGImage?) -> Void)? = nil) {
        let sc = ScrollCapturer(screen: screen, rect: rect)
        sc.log = { DiagLog.write("scroll: " + $0) }
        scroller = sc
        Task { @MainActor in
            let img = await sc.run()
            self.scroller = nil
            if let completion { completion(img); return }
            guard let img else { return }
            self.previousApp = NSWorkspace.shared.frontmostApplication
            self.present(OverlayController(screen: screen, base: img, mode: .editResult, windows: [],
                                           pxPerPt: screen.backingScaleFactor))
        }
    }

    // MARK: video

    func startRecording(screen: NSScreen, rect: CGRect, completion: ((URL?) -> Void)? = nil) {
        guard recorder == nil, recordHUD == nil else { return }
        let hud = RecordingHUD(screen: screen, rect: rect) { [weak self] in self?.stopRecording() }
        recordHUD = hud
        hud.show()
        recordingDone = completion
        Task { @MainActor in
            do {
                self.recorder = try await RegionRecorder(screen: screen, rect: rect, url: Output.desktopURL(ext: "mp4"),
                                                         exclude: hud.excludedWindows)
                self.setStatusIcon(recording: true)
                DiagLog.write("record: started \(rect)")
            } catch {
                hud.close()
                self.recordHUD = nil
                self.alert("Не удалось начать запись", error.localizedDescription)
                completion?(nil)
            }
        }
    }

    private var recordingDone: ((URL?) -> Void)?

    /// Self-test: show a click bubble without actually clicking.
    func debugBubble(at cocoaPoint: CGPoint) { recordHUD?.bubble(at: cocoaPoint) }

    func stopRecording() {
        guard let rec = recorder else { return }
        recorder = nil
        recordHUD?.close()
        recordHUD = nil
        setStatusIcon(recording: false)
        Task { @MainActor in
            let url = await rec.stop()
            DiagLog.write("record: stopped, \(rec.frames) frames → \(url?.path ?? "nil")")
            if let done = self.recordingDone { self.recordingDone = nil; done(url); return }
            guard let url else { return }
            Output.copyFile(url)
            Toast.show("Видео сохранено на рабочий стол и скопировано")
        }
    }

    private func setStatusIcon(recording: Bool) {
        let img = NSImage(systemSymbolName: recording ? "record.circle.fill" : "camera.viewfinder", accessibilityDescription: "2pic")
        img?.isTemplate = !recording
        if recording {
            statusItem?.button?.image = img?.withSymbolConfiguration(.init(paletteColors: [.systemRed]))
        } else {
            statusItem?.button?.image = img
        }
    }

    private func restoreFocus() {
        if let prev = previousApp, prev.processIdentifier != ProcessInfo.processInfo.processIdentifier, !prev.isTerminated {
            prev.activate()
        } else {
            NSApp.hide(nil)
        }
        previousApp = nil
    }

    // MARK: permissions

    private func ensureScreenAccess() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        CGRequestScreenCaptureAccess()
        alert("2pic нужен доступ к записи экрана",
              "Системные настройки → Конфиденциальность и безопасность → Запись экрана и системного звука: включите 2pic. Потом перезапустите 2pic (значок в строке меню → Выйти, и откройте снова).",
              settings: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        return false
    }

    private func ensureAccessibility() -> Bool {
        if CGPreflightPostEventAccess() { return true }
        CGRequestPostEventAccess()
        alert("Для прокрутки 2pic нужен «Универсальный доступ»",
              "Чтобы прокручивать страницу за вас, 2pic посылает события колёсика мыши. Системные настройки → Конфиденциальность и безопасность → Универсальный доступ: включите 2pic.",
              settings: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        return false
    }

    private func alert(_ title: String, _ text: String, settings: String? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        if settings != nil { a.addButton(withTitle: "Открыть настройки"); a.addButton(withTitle: "Позже") }
        if a.runModal() == .alertFirstButtonReturn, let s = settings, let url = URL(string: s) {
            NSWorkspace.shared.open(url)
        }
    }
}
