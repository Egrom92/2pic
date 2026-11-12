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
    private var recordHUD: RecordingHUD?      // set from the moment a recording is starting until it stops
    private var stopWhenStarted = false        // Stop was asked for while the recorder was still starting
    private var recordStarted: Date?
    private var stopItem: NSMenuItem?
    private var busy = false
    private var previousApp: NSRunningApplication?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--unregister-login") {   // used by uninstall.sh
            try? SMAppService.mainApp.unregister()
            NSApp.terminate(nil)
            return
        }
        #if DEBUG || SELFTEST
        if SelfTest.start(self) { return }
        #endif
        Log.migrateOldLog()
        CrashWatch.start()
        Usage.count("app.launch")
        Log.session()
        Telemetry.start()
        setupMenu()
        let area = HotKeys.shared.register(keyCode: kVK_ANSI_9, modifiers: cmdKey | shiftKey) { [weak self] in
            self?.captureArea(via: "hotkey")
        }
        let scroll = HotKeys.shared.register(keyCode: kVK_ANSI_8, modifiers: cmdKey | shiftKey) { [weak self] in
            self?.captureScrolling(via: "hotkey")
        }
        let taken = [(area, "⌘⇧9"), (scroll, "⌘⇧8")].filter { $0.0 == nil }.map(\.1)
        enableLoginItemOnce()
        observeSystem()
        if !CGPreflightScreenCaptureAccess() {
            Log.warn("permission", "no screen recording permission yet: asking")
            CGRequestScreenCaptureAccess()
        }
        if !taken.isEmpty {
            alert("Сочетание \(taken.joined(separator: " и ")) уже занято",
                  "Его перехватывает другая программа, поэтому 2pic его не получит. Снимки можно делать из меню 2pic в строке меню.")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.info("app", "quit")
        Usage.save()
        Telemetry.snapshotStats()   // kept in the queue, sent at the next start
        Log.flush()
        CrashWatch.cleanExit()
    }

    /// Screens, sleep and wake: ScreenCaptureKit problems tend to follow these.
    private func observeSystem() {
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            let s = NSScreen.screens.map { "\(Int($0.frame.width))×\(Int($0.frame.height)) @\(Int($0.backingScaleFactor))x" }
            Log.info("system", "screens changed: \(s.joined(separator: ", "))")
        }
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in Log.info("system", "going to sleep") }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in Log.info("system", "woke up") }
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
        let prefs = NSMenuItem(title: "Настройки…", action: #selector(openSettings), keyEquivalent: ",")
        let diag = NSMenuItem(title: "Диагностика", action: nil, keyEquivalent: "")
        let diagMenu = NSMenu()
        for (title, sel) in [("Статистика использования…", #selector(openStats)), ("Открыть журнал", #selector(openLog)),
                             ("Показать журналы в Finder", #selector(revealLogs))] {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            i.target = self
            diagMenu.addItem(i)
        }
        diag.submenu = diagMenu
        let stop = NSMenuItem(title: "Остановить запись видео", action: #selector(menuStopRecording), keyEquivalent: "")
        stop.isHidden = true
        stopItem = stop
        for i in [stop, area, scroll, .separator(), prefs, login, diag, .separator(),
                  NSMenuItem(title: "Выйти из 2pic", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")] {
            if i.action != #selector(NSApplication.terminate(_:)) && i.action != nil { i.target = self }
            menu.addItem(i)
        }
        item.menu = menu
        statusItem = item
    }

    func menuWillOpen(_ menu: NSMenu) {
        loginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
        stopItem?.isHidden = recordHUD == nil
    }

    @objc private func menuArea() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.captureArea(via: "menu") } }
    @objc private func menuScroll() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.captureScrolling(via: "menu") } }
    @objc private func openSettings() { SettingsController.shared.show() }
    @objc private func openStats() { StatsController.shared.show() }

    @objc private func openLog() {
        Usage.count("log.open")
        Log.flush()
        NSWorkspace.shared.open(Log.fileURL)
    }

    @objc private func revealLogs() {
        Log.flush()
        NSWorkspace.shared.activateFileViewerSelecting([Log.fileURL])
    }

    @objc private func toggleLogin() {
        Usage.count("login.toggle")
        let wasOn = SMAppService.mainApp.status == .enabled
        do {
            if wasOn { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
            Log.info("app", "login item turned \(wasOn ? "off" : "on")")
        } catch {
            Log.error("app", "login item change failed: \(error)")
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
            Log.info("app", "login item turned on (first run)")
        } catch {
            Log.error("app", "login item registration failed: \(error)")
        }
    }

    // MARK: capture flows

    @objc private func menuStopRecording() { stopRecording() }

    func captureArea(via: String = "hotkey") {
        if recordHUD != nil { stopRecording(); return }   // ⌘⇧9 while recording (or starting to) stops it
        if scroller != nil { return }
        Usage.count("start.area.\(via)")
        startOverlay(mode: .capture, via: via)
    }

    func captureScrolling(via: String = "hotkey") {
        if let s = scroller { s.stop(); return }   // second ⌘⇧8 stops scrolling
        if recordHUD != nil { stopRecording(); return }
        Usage.count("start.scroll.\(via)")
        guard ensureAccessibility() else { return }
        startOverlay(mode: .scrollSelect, via: via)
    }

    private func startOverlay(mode: OverlayMode, via: String) {
        guard overlay == nil, !busy else { Log.info("capture", "ignored \(via): a capture is already open"); return }
        guard ensureScreenAccess() else { return }
        busy = true
        let t0 = Date()
        let screen = Screens.underMouse()
        previousApp = NSWorkspace.shared.frontmostApplication
        Task { @MainActor in
            defer { self.busy = false }
            do {
                let shot = try await Capture.screen(screen)
                let pxPerPt = CGFloat(shot.width) / screen.frame.width
                let windows = WindowList.rects(on: screen, pxPerPt: pxPerPt)
                self.present(OverlayController(screen: screen, base: shot, mode: mode, windows: windows, pxPerPt: pxPerPt))
                let ms = Date().timeIntervalSince(t0) * 1000
                Usage.measure("overlay.ms", ms)
                Log.info("capture", String(format: "%@ via %@: screen %d×%d px, %d windows, over %@, shown in %.0f ms",
                                           "\(mode)", via, shot.width, shot.height, windows.count,
                                           self.previousApp?.bundleIdentifier ?? "?", ms))
            } catch {
                Log.error("capture", "screen capture failed: \(error)")
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
            DispatchQueue.main.async {
                guard let img = canvas.render() else {
                    Log.warn("output", "copy: empty selection")
                    Toast.show("Нечего копировать: выделение пустое")
                    return
                }
                Output.copy(img, pxPerPt: pxPerPt)
                Log.info("output", "copied \(img.width)×\(img.height) px")
            }
        case .save:
            DispatchQueue.main.async {
                guard let img = canvas.render() else {
                    Log.warn("output", "save: empty selection")
                    Toast.show("Нечего сохранять: выделение пустое")
                    return
                }
                do {
                    let url = try Output.save(img, pxPerPt: pxPerPt)
                    Usage.count("save.ok")
                    Log.info("output", "saved \(img.width)×\(img.height) px as \(url.lastPathComponent) in «\(Settings.saveFolderName)»")
                    Toast.show("Сохранено в «\(Settings.saveFolderName)»: \(url.lastPathComponent)")
                } catch {
                    Usage.count("save.error")
                    Log.error("output", "save to «\(Settings.saveFolderName)» failed: \(error)")
                    self.alert("Не удалось сохранить снимок",
                               "\(error.localizedDescription)\n\nПроверьте, что у 2pic есть доступ к папке «\(Settings.saveFolderName)»: Системные настройки → Конфиденциальность и безопасность → Файлы и папки. Папку можно сменить в настройках 2pic.")
                }
            }
        case .copyText:
            DispatchQueue.main.async {
                guard let img = canvas.render() else { Toast.show("Нечего распознавать: выделение пустое"); return }
                Toast.show("Распознаю текст…")
                Task { @MainActor in
                    // The rendered picture, not the raw screen: text hidden under a blur stays hidden.
                    let t0 = Date()
                    let text = await TextRecognizer.text(in: img)
                    let ms = Date().timeIntervalSince(t0) * 1000
                    Usage.measure("ocr.ms", ms)
                    // Only sizes are logged, never the text itself.
                    Log.info("ocr", String(format: "%d×%d px → %d characters, %d lines in %.0f ms", img.width, img.height,
                                           text.count, text.isEmpty ? 0 : text.split(separator: "\n").count, ms))
                    if text.isEmpty {
                        Usage.count("ocr.empty")
                        Toast.show("Текст на снимке не найден")
                    } else {
                        Usage.count("ocr.found")
                        Usage.measure("ocr.chars", Double(text.count))
                        Output.copyText(text)
                        Toast.show("Текст скопирован")
                    }
                }
            }
        case .scroll(let rect):
            startScroll(screen: ov.screen, rect: rect)
        case .record(let rect):
            startRecording(screen: ov.screen, rect: rect)
        }
    }

    func startScroll(screen: NSScreen, rect: CGRect, completion: ((CGImage?) -> Void)? = nil) {
        let sc = ScrollCapturer(screen: screen, rect: rect)
        scroller = sc
        Task { @MainActor in
            let img = await sc.run()
            self.scroller = nil
            Usage.count("scroll.\(sc.outcome)")
            Usage.measure("scroll.frames", Double(sc.frames))
            if let completion { completion(img); return }
            guard let img else { return }
            self.previousApp = NSWorkspace.shared.frontmostApplication
            let ov = OverlayController(screen: screen, base: img, mode: .editResult, windows: [],
                                       pxPerPt: screen.backingScaleFactor)
            self.present(ov)
            if let notice = sc.notice { ov.canvas.showNotice(notice) }   // e.g. it stopped before the end
        }
    }

    // MARK: video

    func startRecording(screen: NSScreen, rect: CGRect, completion: ((URL?) -> Void)? = nil) {
        guard recorder == nil, recordHUD == nil else { return }
        let hud = RecordingHUD(screen: screen, rect: rect) { [weak self] in self?.stopRecording() }
        recordHUD = hud
        hud.show()
        recordingDone = completion
        stopWhenStarted = false
        Task { @MainActor in
            do {
                let rec = try await RegionRecorder(
                    screen: screen, rect: rect, url: Output.newFileURL(ext: "mp4"), exclude: hud.excludedWindowIDs,
                    onInterrupt: { [weak self] _ in Task { @MainActor in self?.stopRecording() } })
                self.recorder = rec
                self.recordStarted = Date()
                self.setStatusIcon(recording: true)
                Log.info("record", "started: \(Int(rect.width))×\(Int(rect.height)) pt region")
                if self.stopWhenStarted { self.stopWhenStarted = false; self.stopRecording() }
            } catch {
                hud.close()
                self.recordHUD = nil
                self.stopWhenStarted = false
                self.recordingDone = nil
                Usage.count("video.failed")
                Log.error("record", "could not start: \(error)")
                self.alert("Не удалось начать запись", error.localizedDescription)
                completion?(nil)
            }
        }
    }

    private var recordingDone: ((URL?) -> Void)?

    /// Self-test: show a click bubble without actually clicking.
    func debugBubble(at cocoaPoint: CGPoint) { recordHUD?.bubble(at: cocoaPoint) }

    func stopRecording() {
        guard recordHUD != nil else { return }
        guard let rec = recorder else { stopWhenStarted = true; return }   // still starting: stop as soon as it has
        recorder = nil
        recordHUD?.close()
        recordHUD = nil
        setStatusIcon(recording: false)
        let seconds = recordStarted.map { Date().timeIntervalSince($0) } ?? 0
        recordStarted = nil
        Task { @MainActor in
            let result = await rec.stop()
            let bytes = result.url.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int } ?? 0
            let summary = String(format: "%.1f s, %d frames, %d KB", seconds, rec.frames, bytes / 1024)
            if let done = self.recordingDone { self.recordingDone = nil; done(result.url); return }
            switch (result.url, result.error) {
            case (let url?, nil):
                Usage.count("video.saved")
                Usage.measure("video.seconds", seconds)
                Log.info("record", "saved \(url.lastPathComponent): \(summary)")
                Output.copyFile(url)
                Toast.show("Видео сохранено в «\(Settings.saveFolderName)» и скопировано")
            case (let url?, let error?):
                Usage.count("video.interrupted")
                Usage.measure("video.seconds", seconds)
                Log.error("record", "interrupted, kept \(url.lastPathComponent): \(summary); \(error)")
                Output.copyFile(url)
                self.alert("Запись видео прервалась",
                           "\(error.localizedDescription)\n\nЗаписанная часть сохранена в «\(Settings.saveFolderName)» и скопирована.")
            case (nil, let error?):
                Usage.count("video.failed")
                Log.error("record", "failed: \(summary); \(error)")
                self.alert("Не удалось записать видео", error.localizedDescription)
            case (nil, nil):
                Usage.count("video.tooShort")
                Log.warn("record", "nothing recorded: \(summary)")
                Toast.show("Запись слишком короткая — видео не сохранено")
            }
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
        } else if !SettingsController.shared.isShown {   // don't hide our own settings window
            NSApp.hide(nil)
        }
        previousApp = nil
    }

    // MARK: permissions

    private func ensureScreenAccess() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        Log.error("permission", "screen recording not allowed: capture refused")
        CGRequestScreenCaptureAccess()
        alert("2pic нужен доступ к записи экрана",
              "Системные настройки → Конфиденциальность и безопасность → Запись экрана и системного звука: включите 2pic. Потом перезапустите 2pic (значок в строке меню → Выйти, и откройте снова).",
              settings: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        return false
    }

    private func ensureAccessibility() -> Bool {
        if CGPreflightPostEventAccess() { return true }
        Log.error("permission", "accessibility not allowed: scrolling capture refused")
        CGRequestPostEventAccess()
        alert("Для прокрутки 2pic нужен «Универсальный доступ»",
              "Чтобы прокручивать страницу за вас, 2pic посылает события колёсика мыши. Системные настройки → Конфиденциальность и безопасность → Универсальный доступ: включите 2pic.",
              settings: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        return false
    }

    private func alert(_ title: String, _ text: String, settings: String? = nil) {
        Log.info("ui", "alert: \(title)")
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
