import AppKit
import OSLog
import ServiceManagement

// Everything here stays on this Mac: nothing is sent anywhere. The log and the counters never hold
// screen contents, recognized text, window titles or full file paths.

/// Where diagnostics live. Self-tests point them at a temporary folder so real data is left alone.
enum DiagPaths {
    static var logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/2pic", isDirectory: true)
    static var support = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/2pic", isDirectory: true)
    static var crashReports = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)

    static func useTemporary(_ dir: URL) {
        logs = dir.appendingPathComponent("Logs", isDirectory: true)
        support = dir.appendingPathComponent("Support", isDirectory: true)
        crashReports = dir.appendingPathComponent("DiagnosticReports", isDirectory: true)
    }
}

// MARK: - Log

/// The app's log: ~/Library/Logs/2pic/2pic.log (rotated: 2pic.1.log … 2pic.3.log, 1 MB each), and the same
/// lines in the system log (Console.app, subsystem "local.2pic"). Safe to call from any thread.
enum Log {
    static var fileURL: URL { DiagPaths.logs.appendingPathComponent("2pic.log") }
    static var maxSize = 1_000_000
    static let keep = 3   // rotated files kept besides the current one

    private static let queue = DispatchQueue(label: "2pic.log")
    private static var handle: FileHandle?
    private static var size = 0
    private static var recent: [String] = []   // the last lines, sent along with an error (on `queue`)
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func info(_ category: String, _ message: String) { write("INFO ", category, message) }
    static func warn(_ category: String, _ message: String) {
        write("WARN ", category, message)
        Task { @MainActor in Telemetry.logged(level: "WARN", category: category, message: message) }
    }
    /// Errors are also counted in the usage statistics.
    static func error(_ category: String, _ message: String) {
        write("ERROR", category, message)
        Task { @MainActor in
            Usage.count("error")
            Telemetry.logged(level: "ERROR", category: category, message: message)
        }
    }

    private static func write(_ level: String, _ category: String, _ message: String) {
        let logger = Logger(subsystem: "local.2pic", category: category)
        switch level {
        case "ERROR": logger.error("\(message, privacy: .public)")
        case "WARN ": logger.warning("\(message, privacy: .public)")
        default: logger.info("\(message, privacy: .public)")
        }
        let line = "\(stamp.string(from: Date())) \(level) [\(category)] \(message)\n"
        queue.async { append(line) }
    }

    /// Writes at once, bypassing the queue: for the last words of a crashing app.
    static func writeNow(_ category: String, _ message: String) {
        let line = "\(stamp.string(from: Date())) FATAL [\(category)] \(message)\n"
        try? FileManager.default.createDirectory(at: DiagPaths.logs, withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: fileURL) {
            _ = try? h.seekToEnd()
            h.write(Data(line.utf8))
            try? h.close()
        }
    }

    /// Waits until everything queued so far is on disk (tests, quitting).
    static func flush() { queue.sync { try? handle?.synchronize() } }

    /// The last 40 lines written, oldest first.
    static func recentLines() -> [String] { queue.sync { recent } }

    private static func append(_ line: String) {   // on `queue`
        recent.append(String(line.dropLast()))
        if recent.count > 40 { recent.removeFirst(recent.count - 40) }
        if handle == nil { open() }
        guard let h = handle else { return }
        let d = Data(line.utf8)
        h.write(d)
        size += d.count
        if size > maxSize { rotate() }
    }

    private static func open() {
        let fm = FileManager.default
        try? fm.createDirectory(at: DiagPaths.logs, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: fileURL.path) { fm.createFile(atPath: fileURL.path, contents: nil) }
        handle = try? FileHandle(forWritingTo: fileURL)
        size = Int((try? handle?.seekToEnd()) ?? 0)
    }

    static func rotatedURL(_ i: Int) -> URL { DiagPaths.logs.appendingPathComponent("2pic.\(i).log") }

    private static func rotate() {
        try? handle?.close()
        handle = nil
        let fm = FileManager.default
        try? fm.removeItem(at: rotatedURL(keep))
        for i in stride(from: keep - 1, through: 1, by: -1) { try? fm.moveItem(at: rotatedURL(i), to: rotatedURL(i + 1)) }
        try? fm.moveItem(at: fileURL, to: rotatedURL(1))
        open()
    }

    /// The old single log file (~/Library/Logs/2pic.log) moves into the folder once.
    static func migrateOldLog() {
        let old = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/2pic.log")
        let dest = DiagPaths.logs.appendingPathComponent("2pic-before-1.1.log")
        guard FileManager.default.fileExists(atPath: old.path), !FileManager.default.fileExists(atPath: dest.path) else { return }
        try? FileManager.default.createDirectory(at: DiagPaths.logs, withIntermediateDirectories: true)
        try? FileManager.default.moveItem(at: old, to: dest)
    }

    /// First lines of a run: version, system, screens, permissions, settings.
    @MainActor static func session() {
        let plist = Bundle.main.infoDictionary ?? [:]
        let version = plist["CFBundleShortVersionString"] as? String ?? "?"
        let build = plist["TwoPicBuild"] as? String ?? "dev build"
        let screens = NSScreen.screens.map { "\(Int($0.frame.width))×\(Int($0.frame.height)) @\(Int($0.backingScaleFactor))x" }
            .joined(separator: ", ")
        info("app", "start: 2pic \(version) (\(build)), macOS \(ProcessInfo.processInfo.operatingSystemVersionString), "
             + "\(hardwareModel()), \(Locale.preferredLanguages.first ?? "?"), screens: \(screens)")
        info("app", "permissions: screen recording \(CGPreflightScreenCaptureAccess() ? "yes" : "NO"), "
             + "accessibility \(CGPreflightPostEventAccess() ? "yes" : "NO"); saving to «\(Settings.saveFolderName)» as "
             + "\(Settings.imageFormat.rawValue); login item \(SMAppService.mainApp.status == .enabled ? "on" : "off")")
    }

    static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "?" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return String(cString: buf)
    }
}

// MARK: - Crashes

/// Notices crashes: the last words of an Objective-C exception go to the log, and on the next start a run
/// that never ended normally is reported together with macOS's crash report for it.
enum CrashWatch {
    static var marker: URL { DiagPaths.support.appendingPathComponent("running") }
    private static var ownsMarker = false
    private static var termSource: DispatchSourceSignal?

    @MainActor static func start() {
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: marker.path), let since = attrs[.modificationDate] as? Date {
            Log.error("app", "the previous run (started \(Log.describe(since))) ended without quitting normally: crash, hang or force quit")
            Usage.count("crash.previous")
            for r in reports(since: since) { Log.error("crash", "\(r.name): \(r.summary)") }
        }
        try? fm.createDirectory(at: DiagPaths.support, withIntermediateDirectories: true)
        fm.createFile(atPath: marker.path, contents: Data("\(ProcessInfo.processInfo.processIdentifier)".utf8))
        ownsMarker = true

        NSSetUncaughtExceptionHandler { e in
            Log.writeNow("crash", "uncaught exception \(e.name.rawValue): \(e.reason ?? "")\n    "
                         + e.callStackSymbols.prefix(25).joined(separator: "\n    "))
        }
        // `pkill` / `kill` (the installer uses them) quit like the Quit menu item, not like a crash.
        signal(SIGTERM, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        src.setEventHandler {
            Log.info("app", "SIGTERM: quitting")
            NSApp.terminate(nil)
        }
        src.resume()
        termSource = src
    }

    static func cleanExit() {
        guard ownsMarker else { return }
        try? FileManager.default.removeItem(at: marker)
    }

    /// macOS crash reports for 2pic written after `since`, each summarized in one line.
    static func reports(since: Date) -> [(name: String, summary: String)] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: DiagPaths.crashReports.path) else { return [] }
        return names.filter { $0.hasPrefix("2pic") && ($0.hasSuffix(".ips") || $0.hasSuffix(".crash")) }.compactMap { n in
            let url = DiagPaths.crashReports.appendingPathComponent(n)
            guard let d = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date, d >= since.addingTimeInterval(-5) else {
                return nil
            }
            return (n, summarize(url))
        }.sorted { $0.name < $1.name }
    }

    /// Exception type, the reason AppKit/Foundation gave, and the top of the crashed thread.
    static func summarize(_ url: URL) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "unreadable" }
        let parts = text.split(separator: "\n", maxSplits: 1)   // .ips: a JSON header line, then a JSON body
        guard parts.count == 2, let body = try? JSONSerialization.jsonObject(with: Data(parts[1].utf8)) as? [String: Any] else {
            return text.split(separator: "\n").filter { $0.contains("Exception") || $0.contains("Termination") }
                .prefix(4).joined(separator: "; ")
        }
        let exc = body["exception"] as? [String: Any]
        var s = "\(exc?["type"] as? String ?? "?") \(exc?["signal"] as? String ?? "")"
        if let asi = body["asi"] as? [String: [String]] {
            let reason = asi.values.flatMap { $0 }.joined(separator: " | ")
            if !reason.isEmpty { s += "; \(reason)" }
        }
        if let threads = body["threads"] as? [[String: Any]], let ft = body["faultingThread"] as? Int, ft < threads.count,
           let frames = threads[ft]["frames"] as? [[String: Any]] {
            let top = frames.prefix(8).compactMap { $0["symbol"] as? String }
            if !top.isEmpty { s += "; at " + top.joined(separator: " ← ") }
        }
        return s
    }
}

extension Log {
    static func describe(_ d: Date) -> String { stamp.string(from: d) }
}

// MARK: - Usage counters

/// How the app is used, counted on this Mac only (~/Library/Application Support/2pic/usage.json):
/// which features, how they are reached (shortcut, button, menu), how captures end. Shown in
/// 2pic → Диагностика → Статистика использования.
@MainActor
enum Usage {
    struct Stat: Codable { var count = 0; var sum = 0.0; var max = 0.0 }
    struct Store: Codable {
        var since = Date()
        var counts: [String: Int] = [:]
        var months: [String: [String: Int]] = [:]
        var stats: [String: Stat] = [:]
    }

    static var fileURL: URL { DiagPaths.support.appendingPathComponent("usage.json") }
    private static var store: Store = load()
    private static var pendingSave: DispatchWorkItem?

    static func count(_ key: String, _ n: Int = 1) {
        store.counts[key, default: 0] += n
        store.months[month(), default: [:]][key, default: 0] += n
        scheduleSave()
    }

    /// A measured value (seconds, milliseconds, a number of marks…): average and maximum are reported.
    static func measure(_ key: String, _ value: Double) {
        var s = store.stats[key] ?? Stat()
        s.count += 1
        s.sum += value
        s.max = Swift.max(s.max, value)
        store.stats[key] = s
        scheduleSave()
    }

    static func value(_ key: String) -> Int { store.counts[key] ?? 0 }
    static func snapshot() -> Store { store }

    static func save() {
        pendingSave?.cancel()
        pendingSave = nil
        try? FileManager.default.createDirectory(at: DiagPaths.support, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        if let d = try? enc.encode(store) { try? d.write(to: fileURL, options: .atomic) }
    }

    static func reset() {
        store = Store()
        save()
        Log.info("app", "usage statistics reset")
    }

    /// For self-tests after DiagPaths has been redirected.
    static func reload() { store = load() }

    private static func load() -> Store {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let d = try? Data(contentsOf: fileURL), let s = try? dec.decode(Store.self, from: d) else { return Store() }
        return s
    }

    private static func scheduleSave() {
        pendingSave?.cancel()
        let w = DispatchWorkItem { MainActor.assumeIsolated { save() } }
        pendingSave = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: w)
    }

    private static func month(_ d: Date = Date()) -> String {
        let c = Calendar.current.dateComponents([.year, .month], from: d)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    // MARK: report

    private static let sections: [(title: String, items: [(String, String)])] = [
        ("Как начинают снимок", [
            ("start.area.hotkey", "⌘⇧9 — горячей клавишей"), ("start.area.menu", "Снимок — из меню"),
            ("start.scroll.hotkey", "⌘⇧8 прокрутка — горячей клавишей"), ("start.scroll.menu", "Прокрутка — из меню")]),
        ("Что выделяют", [
            ("select.window", "Окно (клик по окну)"), ("select.drag", "Область (протянуть мышью)"),
            ("select.screen", "Весь экран (клик мимо окон)"), ("select.enter", "Сразу Enter/⌘C, без выделения")]),
        ("Чем заканчивают", [
            ("finish.copy", "Скопировать"), ("finish.save", "Сохранить"), ("finish.copyText", "Скопировать текст с картинки"),
            ("finish.record", "Записать видео"), ("finish.scroll", "Начать прокрутку"), ("finish.cancel", "Закрыть без действий")]),
        ("Как копируют", [
            ("copy.via.enter", "Enter"), ("copy.via.cmdC", "⌘C"), ("copy.via.button", "Кнопка на панели"),
            ("copy.via.doubleClick", "Двойной клик")]),
        ("Как закрывают", [("cancel.via.esc", "Esc"), ("cancel.via.button", "Кнопка ✕"), ("cancel.via.rightClick", "Правый клик")]),
        ("Нарисовано пометок", [
            ("mark.arrow", "Стрелка"), ("mark.line", "Линия"), ("mark.rect", "Рамка"), ("mark.text", "Текст"),
            ("mark.counter", "Нумерация"), ("mark.blur", "Размытие")]),
        ("Как выбирают инструмент", [("toolvia.key", "Клавишей (A, L, R, T, N, B, C)"), ("toolvia.button", "Кнопкой на панели")]),
        ("Правка", [
            ("undo", "Отменить"), ("redo", "Повторить"), ("text.reedit", "Исправить готовый текст"),
            ("frame.resize", "Потянуть край или угол рамки"), ("frame.move", "Сдвинуть рамку"),
            ("frame.reselect", "Выделить заново"), ("tool.select", "Режим выделения (C)")]),
        ("Цвет и толщина", [("style.picker", "Открыть палитру")]
            + MarkStyle.colorNames.enumerated().map { ("style.color.\($0.offset)", "Цвет: \($0.element)") }
            + MarkStyle.sizeNames.enumerated().map { ("style.size.\($0.offset)", "Толщина: \($0.element)") }),
        ("Снимок с прокруткой", [
            ("scroll.end", "Дошёл до конца"), ("scroll.userStopped", "Остановлен вручную"),
            ("scroll.stoppedEarly", "Оборвался: не склеилось"), ("scroll.full", "Упёрся в предел длины"),
            ("scroll.noCapture", "Не удалось начать")]),
        ("Видео", [
            ("video.saved", "Сохранено"), ("video.interrupted", "Прервалось, часть сохранена"),
            ("video.failed", "Не удалось записать"), ("video.tooShort", "Слишком короткое")]),
        ("Текст с картинки", [("ocr.found", "Текст найден и скопирован"), ("ocr.empty", "Текста не нашлось")]),
        ("Сохранение", [("save.ok", "Сохранено"), ("save.error", "Ошибка сохранения")]),
        ("Меню и настройки", [
            ("settings.open", "Открыть настройки"), ("settings.folder", "Сменить папку"),
            ("settings.format.jpeg", "Выбрать JPEG"), ("settings.format.png", "Выбрать PNG"),
            ("login.toggle", "Переключить автозапуск"), ("stats.open", "Открыть статистику"), ("log.open", "Открыть журнал"),
            ("telemetry.on", "Включить отправку на сервер"), ("telemetry.off", "Выключить отправку на сервер")]),
    ]
    private static let measures: [(String, String, String)] = [
        ("overlay.ms", "От нажатия до появления затемнения", "мс"),
        ("editor.seconds", "Время в редакторе до действия", "с"),
        ("marks.perShot", "Пометок на один снимок", ""),
        ("scroll.frames", "Кадров на снимок с прокруткой", ""),
        ("video.seconds", "Длительность видео", "с"),
        ("ocr.ms", "Время распознавания текста", "мс"),
        ("ocr.chars", "Символов распознано", ""),
    ]

    /// A readable report: counts by section with shares, averages, problems, and what was never used.
    static func report() -> String {
        let c = store.counts
        let shots = ["finish.copy", "finish.save", "finish.copyText", "finish.record", "finish.scroll"].reduce(0) { $0 + (c[$1] ?? 0) }
        var out = "Статистика 2pic с \(DateFormatter.localizedString(from: store.since, dateStyle: .long, timeStyle: .none))\n"
        out += "Запусков: \(c["app.launch"] ?? 0) · снимков доведено до действия: \(shots) · закрыто без действий: \(c["finish.cancel"] ?? 0)\n"
        out += "Ошибок в журнале: \(c["error"] ?? 0) · аварийных завершений: \(c["crash.previous"] ?? 0)\n"
        // Shares compare like with like: keys of one family ("style.color.*", "copy.via.*", "frame.*").
        func family(_ key: String) -> String {
            let parts = key.split(separator: ".")
            return parts.count > 1 ? parts.dropLast().joined(separator: ".") : key
        }
        for s in sections {
            out += "\n\(s.title)\n"
            for (key, name) in s.items {
                let n = c[key] ?? 0
                let kin = s.items.filter { family($0.0) == family(key) }
                let total = kin.reduce(0) { $0 + (c[$1.0] ?? 0) }
                let share = total > 0 && kin.count > 1 ? String(format: "%3.0f %%", Double(n) * 100 / Double(total)) : ""
                out += "  " + name.padding(toLength: 44, withPad: " ", startingAt: 0) + String(format: "%6d  ", n) + share + "\n"
            }
        }
        out += "\nВремя и объёмы\n"
        for (key, name, unit) in measures {
            guard let s = store.stats[key], s.count > 0 else {
                out += "  " + name.padding(toLength: 44, withPad: " ", startingAt: 0) + "     —\n"
                continue
            }
            let avg = s.sum / Double(s.count)
            let fmt = { (v: Double) in v >= 100 ? String(format: "%.0f", v) : String(format: "%.1f", v) }
            out += "  " + name.padding(toLength: 44, withPad: " ", startingAt: 0)
                + "в среднем \(fmt(avg))\(unit.isEmpty ? "" : " \(unit)"), максимум \(fmt(s.max)) (раз: \(s.count))\n"
        }
        let unused = sections.flatMap { $0.items }.filter { (c[$0.0] ?? 0) == 0 && !$0.0.hasPrefix("style.") && !$0.0.hasPrefix("scroll.")
            && !$0.0.hasPrefix("video.") && !$0.0.hasSuffix(".error") && $0.0 != "ocr.empty" }
        out += "\nНи разу не использовалось\n"
        out += unused.isEmpty ? "  — всё хоть раз пригодилось\n" : unused.map { "  · \($0.1)" }.joined(separator: "\n") + "\n"
        let months = store.months.keys.sorted().suffix(6)
        if !months.isEmpty {
            out += "\nПо месяцам (снимков доведено до действия)\n"
            for m in months {
                let mc = store.months[m] ?? [:]
                let n = ["finish.copy", "finish.save", "finish.copyText", "finish.record", "finish.scroll"].reduce(0) { $0 + (mc[$1] ?? 0) }
                out += "  \(m)  \(n)\n"
            }
        }
        return out
    }
}

// MARK: - Statistics window

@MainActor
final class StatsController: NSObject {
    static let shared = StatsController()
    private var window: SettingsWindow?
    private let text = NSTextView()

    func show() {
        Usage.count("stats.open")
        if window == nil { window = makeWindow() }
        text.string = Usage.report()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> SettingsWindow {
        let w = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 620),
                               styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Статистика использования 2pic"
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 520, height: 360)

        text.isEditable = false
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.textContainerInset = NSSize(width: 10, height: 10)
        text.autoresizingMask = [.width]
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = text
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let note = NSTextField(wrappingLabelWithString: "Считается только на этом Mac, никуда не отправляется.")
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        let copy = NSButton(title: "Скопировать", target: self, action: #selector(copyReport))
        let reset = NSButton(title: "Сбросить…", target: self, action: #selector(resetStats))
        let bar = NSStackView(views: [note, NSView(), reset, copy])
        bar.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(scroll)
        content.addSubview(bar)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
        w.contentView = content
        return w
    }

    @objc private func copyReport() { Output.copyText(Usage.report()) }

    @objc private func resetStats() {
        let a = NSAlert()
        a.messageText = "Сбросить статистику использования?"
        a.informativeText = "Все счётчики начнутся с нуля. Журнал ошибок не изменится."
        a.addButton(withTitle: "Сбросить")
        a.addButton(withTitle: "Отмена")
        guard let window, a.runModal() == .alertFirstButtonReturn else { return }
        Usage.reset()
        text.string = Usage.report()
        window.makeKeyAndOrderFront(nil)
    }
}
