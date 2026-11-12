import AppKit

/// Sends errors and usage statistics to the user's own server (see server/ in the repository).
/// Off by default: nothing is even queued until it is switched on in Settings with an address and a key.
///
/// What goes out: errors and warnings with the last lines of the log before them, the usage statistics,
/// the app and macOS versions, the Mac model, an anonymous install id. Never: screenshots, recognized text,
/// window titles, full file paths (the log doesn't hold them in the first place).
///
/// Protocol: POST <address>/v1/ingest, `Authorization: Bearer <key>`, JSON `Envelope`; any 2xx = accepted.
/// Events carry ids, so a batch re-sent after a lost reply is not stored twice.
@MainActor
enum Telemetry {
    struct Event: Codable {
        var id = UUID().uuidString
        var kind: String              // session, error, warning, stats, test
        var time = Date()
        var level: String?
        var category: String?
        var message: String?
        var context: [String]?        // the log lines just before an error
        var info: [String: String]?   // session details
        var stats: Usage.Store?       // statistics snapshot
    }

    struct Envelope: Encodable {
        var schema = 1
        let install: String
        let app: [String: String]
        let system: [String: String]
        let sentAt: Date
        let events: [Event]
        enum CodingKeys: String, CodingKey { case schema, install, app, system, sentAt = "sent_at", events }
    }

    // MARK: settings

    private static var d: UserDefaults { .standard }
    static var enabled: Bool {
        get { d.bool(forKey: "telemetryEnabled") }
        set { d.set(newValue, forKey: "telemetryEnabled") }
    }
    static var endpoint: String {
        get { d.string(forKey: "telemetryURL") ?? "" }
        set { d.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "telemetryURL") }
    }
    static var token: String {
        get { d.string(forKey: "telemetryToken") ?? "" }
        set { d.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "telemetryToken") }
    }
    /// Anonymous id of this installation, so the server can tell Macs apart.
    static var installID: String {
        if let id = d.string(forKey: "installID") { return id }
        let id = UUID().uuidString
        d.set(id, forKey: "installID")
        return id
    }

    /// https only (local addresses may use http, for testing).
    static var ingestURL: URL? {
        guard var base = URL(string: endpoint), let scheme = base.scheme?.lowercased(), let host = base.host?.lowercased() else { return nil }
        let local = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard scheme == "https" || (scheme == "http" && local) else { return nil }
        if base.path.hasSuffix("/v1/ingest") { return base }
        base.appendPathComponent("v1/ingest")
        return base
    }

    static var isOn: Bool { enabled && ingestURL != nil && !token.isEmpty }

    // MARK: queue

    static let maxEvents = 2000
    static let batchSize = 200
    static var outboxURL: URL { DiagPaths.support.appendingPathComponent("outbox.json") }
    private static var outbox: [Event] = loadOutbox()
    private static var sending = false
    private static var retryDelay: TimeInterval = 60
    private static var nextTry = Date.distantPast
    private static var pendingFlush: DispatchWorkItem?
    private static var timer: Timer?
    private static var lastStats = Date.distantPast

    static var queued: Int { outbox.count }

    /// At launch: what's running and the statistics so far; then a flush every 10 minutes.
    static func start() {
        if isOn {
            record(Event(kind: "session", info: sessionInfo()))
            snapshotStats()
            Log.info("telemetry", "sending to \(ingestURL?.host ?? "?"), \(outbox.count) events queued")
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { _ in
            MainActor.assumeIsolated {
                if Date().timeIntervalSince(lastStats) > 6 * 3600 { snapshotStats() }
                flush()
            }
        }
        scheduleFlush(after: 10)
    }

    /// Called by the log for every error and warning.
    static func logged(level: String, category: String, message: String) {
        guard isOn, category != "telemetry" else { return }   // its own failures would only feed a loop
        let error = level.hasPrefix("ERROR")
        record(Event(kind: error ? "error" : "warning", level: level.trimmingCharacters(in: .whitespaces),
                     category: category, message: String(message.prefix(4000)), context: Log.recentLines()))
        if error { scheduleFlush(after: 5) }   // errors go out within seconds
    }

    /// The statistics as they are now (an older unsent snapshot is replaced).
    static func snapshotStats() {
        guard isOn else { return }
        lastStats = Date()
        outbox.removeAll { $0.kind == "stats" }
        record(Event(kind: "stats", stats: Usage.snapshot()))
    }

    private static func record(_ e: Event) {
        outbox.append(e)
        if outbox.count > maxEvents { outbox.removeFirst(outbox.count - maxEvents) }   // offline for long: keep the newest
        saveOutbox()
    }

    static func scheduleFlush(after seconds: TimeInterval) {
        pendingFlush?.cancel()
        let w = DispatchWorkItem { MainActor.assumeIsolated { flush() } }
        pendingFlush = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    /// Sends what is queued, in batches. A failure keeps the events and waits longer each time (1 min … 1 h).
    static func flush(force: Bool = false) {
        guard isOn, !sending, !outbox.isEmpty, force || Date() >= nextTry else { return }
        let batch = Array(outbox.prefix(batchSize))
        sending = true
        Task { @MainActor in
            let result = await send(batch)
            sending = false
            let ids = Set(batch.map(\.id))
            switch result {
            case .success:
                outbox.removeAll { ids.contains($0.id) }
                saveOutbox()
                retryDelay = 60
                nextTry = .distantPast
                if !outbox.isEmpty { scheduleFlush(after: 1) }
            case .failure(.http(let code, let body)) where code == 400 || code == 413 || code == 422:
                // The server will never take this batch: drop it rather than retry forever.
                outbox.removeAll { ids.contains($0.id) }
                saveOutbox()
                Log.warn("telemetry", "server refused \(batch.count) events with \(code): \(body); dropped")
            case .failure(let e):
                nextTry = Date().addingTimeInterval(retryDelay)
                Log.warn("telemetry", "sending \(batch.count) events failed (\(e)); next try in \(Int(retryDelay)) s")
                retryDelay = min(retryDelay * 2, 3600)
            }
        }
    }

    enum SendError: Error, CustomStringConvertible {
        case notConfigured, encode, http(Int, String), transport(String)
        var description: String {
            switch self {
            case .notConfigured: return "not configured"
            case .encode: return "could not encode"
            case .http(let c, let b): return "HTTP \(c) \(b)"
            case .transport(let m): return m
            }
        }
    }

    static func send(_ events: [Event]) async -> Result<Void, SendError> {
        guard let url = ingestURL, !token.isEmpty else { return .failure(.notConfigured) }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let info = Bundle.main.infoDictionary ?? [:]
        let envelope = Envelope(
            install: installID,
            app: ["version": info["CFBundleShortVersionString"] as? String ?? "?", "build": info["TwoPicBuild"] as? String ?? "dev build"],
            system: ["macos": ProcessInfo.processInfo.operatingSystemVersionString, "model": Log.hardwareModel(),
                     "locale": Locale.preferredLanguages.first ?? "?"],
            sentAt: Date(), events: events)
        guard let body = try? enc.encode(envelope) else { return .failure(.encode) }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("2pic/\(info["CFBundleShortVersionString"] as? String ?? "?")", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else {
                return .failure(.http(code, String(decoding: data.prefix(300), as: UTF8.self)))
            }
            return .success(())
        } catch {
            return .failure(.transport(error.localizedDescription))
        }
    }

    /// Settings → «Проверить соединение»: a test event, sent right away. The server answers it with a
    /// message in the bot, so the whole chain is checked.
    static func test() async -> (ok: Bool, text: String) {
        guard enabled else { return (false, "Сначала включите отправку") }
        guard ingestURL != nil else { return (false, "Адрес должен начинаться с https://") }
        guard !token.isEmpty else { return (false, "Укажите ключ доступа") }
        let r = await send([Event(kind: "test", message: "Проверка соединения из настроек 2pic", info: sessionInfo())])
        switch r {
        case .success:
            Log.info("telemetry", "connection test passed")
            flush(force: true)
            return (true, "Работает: сервер принял тестовое событие, в боте должно прийти сообщение")
        case .failure(let e):
            Log.warn("telemetry", "connection test failed: \(e)")
            switch e {
            case .http(401, _), .http(403, _): return (false, "Сервер не принял ключ (\(e.code))")
            case .http(404, _): return (false, "По этому адресу нет приёмника 2pic (404)")
            case .http(let c, _): return (false, "Сервер ответил ошибкой \(c)")
            case .transport(let m): return (false, "Сервер недоступен: \(m)")
            default: return (false, "Не удалось: \(e)")
            }
        }
    }

    // MARK: details

    static func sessionInfo() -> [String: String] {
        [
            "screens": NSScreen.screens.map { "\(Int($0.frame.width))×\(Int($0.frame.height)) @\(Int($0.backingScaleFactor))x" }
                .joined(separator: ", "),
            "screen_recording": CGPreflightScreenCaptureAccess() ? "yes" : "no",
            "accessibility": CGPreflightPostEventAccess() ? "yes" : "no",
            "save_format": Settings.imageFormat.rawValue,
        ]
    }

    private static func loadOutbox() -> [Event] {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let d = try? Data(contentsOf: outboxURL), let e = try? dec.decode([Event].self, from: d) else { return [] }
        return e
    }

    private static func saveOutbox() {
        try? FileManager.default.createDirectory(at: DiagPaths.support, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if outbox.isEmpty { try? FileManager.default.removeItem(at: outboxURL); return }
        if let d = try? enc.encode(outbox) { try? d.write(to: outboxURL, options: .atomic) }
    }

    /// For self-tests after DiagPaths has been redirected.
    static func reload() {
        outbox = loadOutbox()
        retryDelay = 60
        nextTry = .distantPast
    }
}

extension Telemetry.SendError {
    var code: Int { if case .http(let c, _) = self { return c }; return 0 }
}
