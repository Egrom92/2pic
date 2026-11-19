import AppKit
import Carbon.HIToolbox

// MARK: - A keyboard shortcut (key code + modifiers), as the user picked it

struct Shortcut: Equatable {
    var keyCode: Int
    var carbon: Int   // cmdKey | shiftKey | optionKey | controlKey

    static let defaultArea = Shortcut(keyCode: kVK_ANSI_9, carbon: cmdKey | shiftKey)
    static let defaultScroll = Shortcut(keyCode: kVK_ANSI_8, carbon: cmdKey | shiftKey)

    init(keyCode: Int, carbon: Int) { self.keyCode = keyCode; self.carbon = carbon }

    init(event e: NSEvent) {
        keyCode = Int(e.keyCode)
        let f = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var m = 0
        if f.contains(.command) { m |= cmdKey }
        if f.contains(.shift) { m |= shiftKey }
        if f.contains(.option) { m |= optionKey }
        if f.contains(.control) { m |= controlKey }
        carbon = m
    }

    var cocoa: NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        if carbon & cmdKey != 0 { f.insert(.command) }
        if carbon & shiftKey != 0 { f.insert(.shift) }
        if carbon & optionKey != 0 { f.insert(.option) }
        if carbon & controlKey != 0 { f.insert(.control) }
        return f
    }

    /// Function keys may be used alone; any other key needs ⌘, ⌃ or ⌥ (Shift alone would eat capitals).
    var isUsable: Bool {
        Shortcut.functionKeys[keyCode] != nil || carbon & (cmdKey | controlKey | optionKey) != 0
    }

    /// "⌃⌥⇧⌘9" — the order macOS menus use.
    var display: String {
        var s = ""
        if carbon & controlKey != 0 { s += "⌃" }
        if carbon & optionKey != 0 { s += "⌥" }
        if carbon & shiftKey != 0 { s += "⇧" }
        if carbon & cmdKey != 0 { s += "⌘" }
        return s + keyName
    }

    /// For menus: the key equivalent character, when the key has one.
    var menuKey: String {
        if let f = Shortcut.functionKeys[keyCode] { return f.menu }
        if keyCode == kVK_Space { return " " }
        if Shortcut.named[keyCode] != nil { return "" }
        return Shortcut.character(for: keyCode)?.lowercased() ?? ""
    }

    var keyName: String {
        if let f = Shortcut.functionKeys[keyCode] { return f.name }
        if let n = Shortcut.named[keyCode] { return n }
        return Shortcut.character(for: keyCode)?.uppercased() ?? "#\(keyCode)"
    }

    private static func fn(_ n: Int) -> String { String(UnicodeScalar(UInt32(NSF1FunctionKey + n - 1))!) }
    private static let functionKeys: [Int: (name: String, menu: String)] = [
        kVK_F1: ("F1", fn(1)), kVK_F2: ("F2", fn(2)), kVK_F3: ("F3", fn(3)), kVK_F4: ("F4", fn(4)),
        kVK_F5: ("F5", fn(5)), kVK_F6: ("F6", fn(6)), kVK_F7: ("F7", fn(7)), kVK_F8: ("F8", fn(8)),
        kVK_F9: ("F9", fn(9)), kVK_F10: ("F10", fn(10)), kVK_F11: ("F11", fn(11)), kVK_F12: ("F12", fn(12)),
        kVK_F13: ("F13", fn(13)), kVK_F14: ("F14", fn(14)), kVK_F15: ("F15", fn(15)),
    ]
    private static let named: [Int: String] = [
        kVK_Space: "Пробел", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
    ]

    /// The character the key prints in the current Latin layout (so "9", "S", "[" — not "Ы").
    static func character(for keyCode: Int) -> String? {
        if let n = named[keyCode] { return n }
        guard let src = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> String? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var dead: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var len = 0
            let st = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                    OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &len, &chars)
            guard st == noErr, len > 0 else { return nil }
            let s = String(utf16CodeUnits: chars, count: len).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.controlCharacters))
            return s.isEmpty ? nil : s
        }
    }

    // UserDefaults: "areaShortcut" = [keyCode, carbon]
    static func load(_ key: String, default def: Shortcut) -> Shortcut {
        guard let a = UserDefaults.standard.array(forKey: key) as? [Int], a.count == 2 else { return def }
        let s = Shortcut(keyCode: a[0], carbon: a[1])
        return s.isUsable ? s : def
    }

    func save(_ key: String, default def: Shortcut) {
        if self == def { UserDefaults.standard.removeObject(forKey: key) }
        else { UserDefaults.standard.set([keyCode, carbon], forKey: key) }
    }
}

// MARK: - macOS's own shortcuts (System Settings → Keyboard → Keyboard Shortcuts)

/// Reads and switches the system shortcuts kept in com.apple.symbolichotkeys. A system shortcut wins over
/// any app's hotkey, so if the user picks e.g. ⌘⇧4 for 2pic, the system one has to be turned off.
enum SystemShortcuts {
    private static let domain = "com.apple.symbolichotkeys" as CFString
    private static let key = "AppleSymbolicHotKeys" as CFString
    private static let cmd = 1 << 20, shift = 1 << 17, opt = 1 << 19, ctrl = 1 << 18
    private static let modMask = cmd | shift | opt | ctrl

    /// Names for the ones people are likely to hit; anything else is shown as a generic system shortcut.
    private static let names: [Int: String] = [
        28: "Снимок экрана — сохранить в файл", 29: "Снимок экрана — скопировать",
        30: "Снимок области — сохранить в файл", 31: "Снимок области — скопировать",
        184: "Снимок экрана и запись — параметры", 181: "Снимок панели Touch Bar",
        64: "Поиск Spotlight", 65: "Окно поиска Finder", 60: "Предыдущий источник ввода", 61: "Следующий источник ввода",
        32: "Mission Control", 33: "Окна программы", 36: "Показать рабочий стол",
        79: "Переход на пространство слева", 81: "Переход на пространство справа",
        162: "Универсальный доступ — панель", 163: "Центр уведомлений", 175: "Не беспокоить",
    ]
    /// macOS defaults for the screenshot shortcuts, used when the plist has no entry yet (never changed).
    private static let defaults: [Int: (Int, Int, Int)] = [
        28: (51, kVK_ANSI_3, cmd | shift), 29: (51, kVK_ANSI_3, cmd | shift | ctrl),
        30: (52, kVK_ANSI_4, cmd | shift), 31: (52, kVK_ANSI_4, cmd | shift | ctrl),
        184: (53, kVK_ANSI_5, cmd | shift),
    ]

    struct Hit { let id: Int; let name: String }

    private static func all() -> [String: Any] {
        (CFPreferencesCopyAppValue(key, domain) as? [String: Any]) ?? [:]
    }

    private static func flags(_ s: Shortcut) -> Int {
        var f = 0
        if s.carbon & cmdKey != 0 { f |= cmd }
        if s.carbon & shiftKey != 0 { f |= shift }
        if s.carbon & optionKey != 0 { f |= opt }
        if s.carbon & controlKey != 0 { f |= ctrl }
        return f
    }

    /// The enabled system shortcut that is the same key combination, if any.
    static func conflict(with s: Shortcut) -> Hit? {
        let want = flags(s)
        let dict = all()
        var seen = Set<Int>()
        for (k, v) in dict {
            guard let id = Int(k), let e = v as? [String: Any] else { continue }
            seen.insert(id)
            let enabled = (e["enabled"] as? Bool) ?? ((e["enabled"] as? Int) ?? 0 != 0)
            guard enabled, let value = e["value"] as? [String: Any], let p = value["parameters"] as? [Int], p.count >= 3 else { continue }
            if p[1] == s.keyCode && (p[2] & modMask) == want {
                return Hit(id: id, name: names[id] ?? "Системное сочетание macOS")
            }
        }
        for (id, d) in defaults where !seen.contains(id) && d.1 == s.keyCode && d.2 == want {
            return Hit(id: id, name: names[id] ?? "Системное сочетание macOS")
        }
        return nil
    }

    /// Turns a system shortcut on or off and asks macOS to apply it at once. Returns false if it could not write.
    @discardableResult
    static func set(_ id: Int, enabled: Bool) -> Bool {
        var dict = all()
        var entry = (dict[String(id)] as? [String: Any]) ?? [:]
        if entry["value"] == nil, let d = defaults[id] {
            entry["value"] = ["parameters": [d.0, d.1, d.2], "type": "standard"] as [String: Any]
        }
        entry["enabled"] = enabled
        dict[String(id)] = entry
        CFPreferencesSetAppValue(key, dict as CFDictionary, domain)
        guard CFPreferencesAppSynchronize(domain) else {
            Log.error("hotkey", "could not write system shortcut \(id)")
            return false
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings")
        p.arguments = ["-u"]
        try? p.run()
        p.waitUntilExit()
        Log.info("hotkey", "system shortcut \(id) turned \(enabled ? "on" : "off")")
        return true
    }

    // The ones 2pic turned off, so they can be turned back on when no longer needed (or on uninstall).
    static var turnedOff: Set<Int> {
        get { Set(UserDefaults.standard.array(forKey: "systemShortcutsTurnedOff") as? [Int] ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: "systemShortcutsTurnedOff") }
    }

    /// Turns back on every system shortcut 2pic turned off that none of `inUse` needs any more.
    static func restoreUnused(inUse: [Shortcut]) {
        for id in turnedOff {
            let stillNeeded = inUse.contains { s in
                guard let d = defaultsOrCurrent(id) else { return false }
                return d.keyCode == s.keyCode && d.flags == flags(s)
            }
            if !stillNeeded {
                set(id, enabled: true)
                turnedOff.remove(id)
            }
        }
    }

    private static func defaultsOrCurrent(_ id: Int) -> (keyCode: Int, flags: Int)? {
        if let e = all()[String(id)] as? [String: Any], let v = e["value"] as? [String: Any],
           let p = v["parameters"] as? [Int], p.count >= 3 { return (p[1], p[2] & modMask) }
        if let d = defaults[id] { return (d.1, d.2) }
        return nil
    }
}

// MARK: - Shortcut field for the settings window: click, then press the new combination

@MainActor
final class ShortcutField: NSButton {
    var shortcut: Shortcut { didSet { refresh() } }
    /// Called with the pressed combination; return an error text to reject it (shown under the field).
    var onPick: (Shortcut) -> Void = { _ in }
    /// Recording started / ended: the app suspends its global hotkeys meanwhile.
    var onRecording: (Bool) -> Void = { _ in }

    private var monitor: Any?
    private(set) var recording = false

    init(_ s: Shortcut) {
        shortcut = s
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(toggle)
        widthAnchor.constraint(equalToConstant: 150).isActive = true
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func refresh() {
        title = recording ? "Нажмите сочетание…" : shortcut.display
        toolTip = recording ? "Esc — отмена" : "Щёлкните и нажмите новое сочетание"
    }

    @objc private func toggle() { recording ? stop() : start() }

    func start() {
        guard !recording else { return }
        recording = true
        onRecording(true)
        refresh()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] e in
            MainActor.assumeIsolated {
                guard let self else { return e }
                if e.type == .leftMouseDown {
                    if e.window != self.window || !self.frame.contains(self.convert(e.locationInWindow, from: nil)) { self.stop() }
                    return e
                }
                if Int(e.keyCode) == kVK_Escape && e.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
                    self.stop(); return nil
                }
                let s = Shortcut(event: e)
                guard s.isUsable else { NSSound.beep(); return nil }   // e.g. a bare letter
                self.stop()
                self.onPick(s)
                return nil
            }
        }
    }

    func stop() {
        guard recording else { return }
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        refresh()
        onRecording(false)
    }
}
