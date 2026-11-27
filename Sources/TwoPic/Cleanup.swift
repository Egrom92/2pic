import Foundation

/// Moves old 2pic files (screenshots and videos named "2pic …") from the save folder to the Trash, so the folder
/// doesn't grow forever. Only files 2pic made are touched, never anything else in that folder; from the Trash they
/// can still be put back. The age limit is Settings.cleanupDays (0 = keep everything).
enum Cleanup {
    static let extensions: Set<String> = ["png", "jpg", "jpeg", "mp4", "mov"]
    private static var timer: Timer?

    /// Runs now and then every hour while 2pic is open.
    @MainActor static func start() {
        run()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in run() }
    }

    /// Cleans the current save folder in the background.
    static func run() {
        let days = Settings.cleanupDays
        guard days > 0 else { return }
        let dir = Settings.saveFolder
        DispatchQueue.global(qos: .utility).async {
            let n = trashOld(in: dir, olderThan: TimeInterval(days) * 86_400)
            if n > 0 { Log.info("cleanup", "\(n) file(s) older than \(days) d moved to the Trash from «\(dir.lastPathComponent)»") }
        }
    }

    /// Whether a file looks like one 2pic made.
    static func isOurs(_ url: URL) -> Bool {
        url.lastPathComponent.hasPrefix("2pic ") && extensions.contains(url.pathExtension.lowercased())
    }

    /// Returns how many files went to the Trash.
    @discardableResult
    static func trashOld(in dir: URL, olderThan age: TimeInterval, now: Date = Date()) -> Int {
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey, .isRegularFileKey]
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys,
                                                                       options: [.skipsHiddenFiles]) else { return 0 }
        var n = 0
        for url in items where isOurs(url) {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            // The later of the two: a file copied in recently counts as new.
            let date = [v.creationDate, v.contentModificationDate].compactMap { $0 }.max() ?? now
            guard now.timeIntervalSince(date) > age else { continue }
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                n += 1
            } catch {
                Log.warn("cleanup", "can't move \(url.lastPathComponent) to the Trash: \(error)")
            }
        }
        return n
    }

    /// The 2pic files in a folder (for moving them along when the folder changes).
    static func ourFiles(in dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
            .filter(isOurs)
    }
}
