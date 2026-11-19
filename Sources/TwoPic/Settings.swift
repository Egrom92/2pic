import AppKit
import Carbon.HIToolbox
import UniformTypeIdentifiers

enum ImageFormat: String {
    case png, jpeg
    var ext: String { self == .png ? "png" : "jpg" }
    var type: UTType { self == .png ? .png : .jpeg }
}

/// User preferences, kept in UserDefaults.
enum Settings {
    private static var d: UserDefaults { .standard }

    static var desktop: URL {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    /// Where screenshots (⌘S) and videos go. Falls back to the Desktop if the chosen folder is gone
    /// (an unplugged drive, a deleted folder).
    static var saveFolder: URL {
        get {
            var isDir: ObjCBool = false
            if let p = d.string(forKey: "saveFolder"), FileManager.default.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue {
                return URL(fileURLWithPath: p, isDirectory: true)
            }
            return desktop
        }
        set {
            if newValue.standardizedFileURL.path == desktop.standardizedFileURL.path {
                d.removeObject(forKey: "saveFolder")
            } else {
                d.set(newValue.path, forKey: "saveFolder")
            }
        }
    }

    /// "Рабочий стол", "Снимки"… as Finder shows it.
    static var saveFolderName: String { FileManager.default.displayName(atPath: saveFolder.path) }

    static var imageFormat: ImageFormat {
        get { ImageFormat(rawValue: d.string(forKey: "imageFormat") ?? "") ?? .png }
        set { d.set(newValue.rawValue, forKey: "imageFormat") }
    }

    static var areaShortcut: Shortcut {
        get { Shortcut.load("areaShortcut", default: .defaultArea) }
        set { newValue.save("areaShortcut", default: .defaultArea) }
    }
    static var scrollShortcut: Shortcut {
        get { Shortcut.load("scrollShortcut", default: .defaultScroll) }
        set { newValue.save("scrollShortcut", default: .defaultScroll) }
    }

    /// Last used mark color and size (indexes into MarkStyle).
    static var markColor: Int {
        get { min(max(0, d.integer(forKey: "markColor")), MarkStyle.colors.count - 1) }
        set { d.set(newValue, forKey: "markColor") }
    }
    static var markSize: Int {
        get { min(max(0, (d.object(forKey: "markSize") as? Int) ?? 1), MarkStyle.lineWidths.count - 1) }
        set { d.set(newValue, forKey: "markSize") }
    }
}

enum HotkeyKind: String, CaseIterable {
    case area, scroll
    var shortcut: Shortcut {
        get { self == .area ? Settings.areaShortcut : Settings.scrollShortcut }
        nonmutating set { if self == .area { Settings.areaShortcut = newValue } else { Settings.scrollShortcut = newValue } }
    }
    var defaultShortcut: Shortcut { self == .area ? .defaultArea : .defaultScroll }
    var other: HotkeyKind { self == .area ? .scroll : .area }
}

// MARK: - Settings window

final class SettingsWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { close() }   // Esc
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard e.modifierFlags.contains(.command) else { return super.performKeyEquivalent(with: e) }
        if Int(e.keyCode) == kVK_ANSI_W { close(); return true }   // ⌘W, any layout
        // The app has no Edit menu: wire the text-field shortcuts here (pasting the server key needs ⌘V).
        if let ed = firstResponder as? NSTextView {
            switch Int(e.keyCode) {
            case kVK_ANSI_V: ed.pasteAsPlainText(nil); return true
            case kVK_ANSI_C: ed.copy(nil); return true
            case kVK_ANSI_X: ed.cut(nil); return true
            case kVK_ANSI_A: ed.selectAll(nil); return true
            case kVK_ANSI_Z:
                if e.modifierFlags.contains(.shift) { ed.undoManager?.redo() } else { ed.undoManager?.undo() }
                return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: e)
    }
}

@MainActor
final class SettingsController: NSObject {
    static let shared = SettingsController()

    private var window: SettingsWindow?
    private let folderIcon = NSImageView()
    private let folderLabel = NSTextField(labelWithString: "")
    private let resetButton = NSButton(title: "Рабочий стол", target: nil, action: nil)
    private let format = NSSegmentedControl(labels: ["PNG", "JPEG"], trackingMode: .selectOne, target: nil, action: nil)
    private let sendBox = NSButton(checkboxWithTitle: "Отправлять ошибки и статистику на свой сервер", target: nil, action: nil)
    private let urlField = NSTextField(string: "")
    private let tokenField = NSSecureTextField(string: "")
    private let testStatus = NSTextField(wrappingLabelWithString: "")
    private lazy var shortcutFields: [HotkeyKind: ShortcutField] = Dictionary(uniqueKeysWithValues: HotkeyKind.allCases.map { kind in
        let f = ShortcutField(kind.shortcut)
        f.onPick = { [weak self] s in self?.pick(kind, s) }
        f.onRecording = { on in (NSApp.delegate as? AppDelegate)?.suspendHotkeys(on) }
        return (kind, f)
    })
    private let hotkeyStatus = NSTextField(wrappingLabelWithString: "")
    private var grid: NSGridView?
    /// The server rows are for whoever runs their own 2pic server; others never see them.
    /// Shown when a server is already set, or when Settings is opened with ⌥ held.
    private var showServer = false
    private static let serverRows = 8...13

    var isShown: Bool { window?.isVisible == true }

    /// For self-tests: the window, built but not shown.
    func windowForTests() -> NSWindow {
        if window == nil { window = makeWindow() }
        update()
        return window!
    }

    func show() {
        Usage.count("settings.open")
        let first = window == nil
        if first { window = makeWindow() }
        showServer = showServer || NSEvent.modifierFlags.contains(.option) || !Telemetry.endpoint.isEmpty || Telemetry.enabled
        update()
        NSApp.activate(ignoringOtherApps: true)
        if first { window?.center() }
        window?.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> SettingsWindow {
        let w = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 170),
                               styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Настройки 2pic"
        w.isReleasedWhenClosed = false

        folderIcon.imageScaling = .scaleProportionallyUpOrDown
        folderIcon.widthAnchor.constraint(equalToConstant: 16).isActive = true
        folderIcon.heightAnchor.constraint(equalToConstant: 16).isActive = true
        folderLabel.lineBreakMode = .byTruncatingMiddle
        folderLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        let folderRow = NSStackView(views: [folderIcon, folderLabel])
        folderRow.spacing = 6

        let choose = NSButton(title: "Выбрать папку…", target: self, action: #selector(chooseFolder))
        resetButton.target = self
        resetButton.action = #selector(resetFolder)
        resetButton.toolTip = "Снова сохранять на рабочий стол"
        let buttons = NSStackView(views: [choose, resetButton])
        buttons.spacing = 8

        format.target = self
        format.action = #selector(formatChanged)

        func hint(_ s: String) -> NSTextField {
            let h = NSTextField(wrappingLabelWithString: s)
            h.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            h.textColor = .secondaryLabelColor
            h.preferredMaxLayoutWidth = 290
            return h
        }

        sendBox.target = self
        sendBox.action = #selector(telemetryChanged)
        for (f, placeholder) in [(urlField as NSTextField, "https://адрес-сервера/2pic"), (tokenField, "ключ доступа")] {
            f.placeholderString = placeholder
            f.target = self
            f.action = #selector(telemetryChanged)
            f.cell?.sendsActionOnEndEditing = true
            f.cell?.isScrollable = true
            f.cell?.wraps = false
            f.widthAnchor.constraint(equalToConstant: 290).isActive = true
        }
        let test = NSButton(title: "Проверить соединение", target: self, action: #selector(testConnection))
        testStatus.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        testStatus.preferredMaxLayoutWidth = 290

        func shortcutRow(_ kind: HotkeyKind) -> NSStackView {
            let reset = NSButton(image: NSImage(systemSymbolName: "arrow.counterclockwise", accessibilityDescription: "Как было")!,
                                 target: self, action: #selector(resetShortcut(_:)))
            reset.bezelStyle = .rounded
            reset.tag = kind == .area ? 0 : 1
            reset.toolTip = "Вернуть \(kind.defaultShortcut.display)"
            let row = NSStackView(views: [shortcutFields[kind]!, reset])
            row.spacing = 6
            return row
        }
        hotkeyStatus.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hotkeyStatus.preferredMaxLayoutWidth = 290
        hotkey(status: nil)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.shortcutFields.values.forEach { $0.stop() } }
        }

        let grid = NSGridView(views: [
            [label("Снимок области:"), shortcutRow(.area)],
            [label("С прокруткой:"), shortcutRow(.scroll)],
            [NSGridCell.emptyContentView, hotkeyStatus],
            [label("Сохранять в:"), folderRow],
            [NSGridCell.emptyContentView, buttons],
            [NSGridCell.emptyContentView, hint("Сюда сохраняются снимки (⌘S) и видео.")],
            [label("Формат снимков:"), format],
            [NSGridCell.emptyContentView,
             hint("JPEG — файлы меньше, но с небольшой потерей качества. В буфер обмена снимок всегда копируется в PNG.")],
            [label("Сервер:"), sendBox],
            [label("Адрес:"), urlField],
            [label("Ключ:"), tokenField],
            [NSGridCell.emptyContentView, test],
            [NSGridCell.emptyContentView, testStatus],
            [NSGridCell.emptyContentView,
             hint("Уходят: ошибки с последними строками журнала, статистика использования, версии 2pic и macOS. Не уходят: снимки, текст с них, названия окон. Адрес и ключ выдаёт ваш сервер.")],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .none
        for i in 0..<grid.numberOfRows { grid.row(at: i).yPlacement = .center }
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.row(at: 2).bottomPadding = 10   // a gap after the shortcuts
        grid.row(at: 5).bottomPadding = 10   // a gap between the folder and the format groups
        grid.row(at: 7).bottomPadding = 10   // … and before the server group
        grid.translatesAutoresizingMaskIntoConstraints = false
        self.grid = grid

        let content = NSView()
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
        ])
        w.contentView = content
        return w
    }

    private func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.alignment = .right
        return l
    }

    private func update() {
        let url = Settings.saveFolder
        folderIcon.image = NSWorkspace.shared.icon(forFile: url.path)
        folderLabel.stringValue = Settings.saveFolderName
        folderLabel.toolTip = url.path
        resetButton.isHidden = url.standardizedFileURL.path == Settings.desktop.standardizedFileURL.path
        format.selectedSegment = Settings.imageFormat == .png ? 0 : 1
        sendBox.state = Telemetry.enabled ? .on : .off
        urlField.stringValue = Telemetry.endpoint
        tokenField.stringValue = Telemetry.token
        for (kind, f) in shortcutFields { f.shortcut = kind.shortcut }
        if let grid {
            for i in Self.serverRows { grid.row(at: i).isHidden = !showServer }
            grid.row(at: 7).bottomPadding = showServer ? 10 : 0
        }
    }

    // MARK: shortcuts

    private func pick(_ kind: HotkeyKind, _ s: Shortcut) {
        if s == kind.shortcut { hotkey(status: nil); return }
        if s == kind.other.shortcut {
            hotkey(status: "\(s.display) уже стоит на «\(kind.other == .area ? "Снимок области" : "С прокруткой")»", ok: false)
            return
        }
        if let hit = SystemShortcuts.conflict(with: s) {
            askToTurnOff(hit, for: kind, s)
            return
        }
        apply(kind, s)
    }

    private func apply(_ kind: HotkeyKind, _ s: Shortcut) {
        if let err = (NSApp.delegate as? AppDelegate)?.setShortcut(kind, s) {
            hotkey(status: err, ok: false)
        } else {
            hotkey(status: "Готово: \(s.display)", ok: true)
        }
        update()
    }

    /// The combination belongs to macOS (⌘⇧4 and the like): system shortcuts win over apps, so offer to turn it off.
    private func askToTurnOff(_ hit: SystemShortcuts.Hit, for kind: HotkeyKind, _ s: Shortcut) {
        guard let window else { return }
        let a = NSAlert()
        a.messageText = "\(s.display) занято macOS"
        a.informativeText = "Это системное сочетание «\(hit.name)». Пока оно включено, macOS перехватывает его раньше 2pic.\n\nОтключить его в macOS и отдать 2pic? Если позже поставить 2pic другое сочетание, системное включится обратно."
        a.addButton(withTitle: "Отключить в macOS")
        a.addButton(withTitle: "Отмена")
        a.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn else { self.hotkey(status: nil); return }
                guard SystemShortcuts.set(hit.id, enabled: false) else {
                    self.hotkey(status: "Не получилось отключить. Сделайте это вручную: Системные настройки → Клавиатура → Сочетания клавиш.", ok: false)
                    return
                }
                SystemShortcuts.turnedOff.insert(hit.id)
                Usage.count("settings.hotkey.systemOff")
                self.apply(kind, s)
                if SystemShortcuts.conflict(with: s) == nil {
                    self.hotkey(status: "Готово: \(s.display) теперь у 2pic. Если macOS всё ещё перехватывает его — выйдите из системы и войдите снова.", ok: true)
                }
            }
        }
    }

    @objc private func resetShortcut(_ sender: NSButton) {
        let kind: HotkeyKind = sender.tag == 0 ? .area : .scroll
        pick(kind, kind.defaultShortcut)
    }

    private func hotkey(status: String?, ok: Bool? = nil) {
        hotkeyStatus.stringValue = status ?? "Щёлкните по сочетанию и нажмите новое. Если оно занято macOS (например, ⌘⇧4), 2pic предложит отключить системное."
        hotkeyStatus.textColor = ok == nil ? .secondaryLabelColor : (ok! ? .systemGreen : .systemRed)
    }

    /// The switch, the address or the key changed: save them, and start sending if everything is set.
    @objc private func telemetryChanged() {
        let was = Telemetry.isOn
        Telemetry.enabled = sendBox.state == .on
        Telemetry.endpoint = urlField.stringValue
        Telemetry.token = tokenField.stringValue
        if Telemetry.isOn != was {
            Usage.count(Telemetry.isOn ? "telemetry.on" : "telemetry.off")
            Log.info("settings", "sending to the server \(Telemetry.isOn ? "on (\(Telemetry.ingestURL?.host ?? "?"))" : "off")")
            if Telemetry.isOn { Telemetry.start() }
        }
        if Telemetry.enabled && !Telemetry.endpoint.isEmpty && Telemetry.ingestURL == nil {
            show(status: "Адрес должен начинаться с https://", ok: false)
        } else {
            testStatus.stringValue = ""
        }
    }

    @objc private func testConnection() {
        telemetryChanged()   // the button doesn't end typing in a field: take what's there now
        show(status: "Проверяю…", ok: nil)
        Task { @MainActor in
            let r = await Telemetry.test()
            self.show(status: r.text, ok: r.ok)
        }
    }

    private func show(status: String, ok: Bool?) {
        testStatus.stringValue = status
        testStatus.textColor = ok == nil ? .secondaryLabelColor : (ok! ? .systemGreen : .systemRed)
    }

    @objc private func chooseFolder() {
        guard let window else { return }
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.allowsMultipleSelection = false
        p.prompt = "Выбрать"
        p.message = "Куда 2pic будет сохранять снимки и видео"
        p.directoryURL = Settings.saveFolder
        p.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = p.url else { return }
                Settings.saveFolder = url
                Usage.count("settings.folder")
                Log.info("settings", "save folder → «\(Settings.saveFolderName)»")
                self.update()
            }
        }
    }

    @objc private func resetFolder() {
        Settings.saveFolder = Settings.desktop
        Usage.count("settings.folder")
        Log.info("settings", "save folder → Desktop")
        update()
    }

    @objc private func formatChanged() {
        Settings.imageFormat = format.selectedSegment == 1 ? .jpeg : .png
        Usage.count("settings.format.\(Settings.imageFormat.rawValue)")
        Log.info("settings", "image format → \(Settings.imageFormat.rawValue)")
    }
}
