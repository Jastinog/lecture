import Foundation

/// Versioned, corruption-safe JSON persistence in Application Support.
///
/// Each payload is wrapped in a `Versioned` envelope carrying a `schemaVersion`,
/// so a future model change can migrate old data instead of failing to decode the
/// whole array. Lists decode element by element, so one bad entry costs only
/// itself. On a decode failure the bad file is backed up to
/// `<name>.corrupt-<timestamp>` rather than silently discarded — user data (shelf, history, listening
/// positions) is never quietly wiped, and the backup is a recoverable signal.
enum Store {
    struct Versioned<T: Codable>: Codable {
        var schemaVersion: Int
        var data: T
    }

    private static var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func fileURL(_ name: String) -> URL { dir.appendingPathComponent(name) }

    static func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(name).path)
    }

    /// Loads the payload, or nil if the file is absent. On a decode failure the
    /// file is backed up and nil is returned — the caller keeps its empty state but
    /// the data on disk is preserved for recovery instead of being overwritten.
    static func load<T: Codable>(_ type: T.Type, from name: String) -> T? {
        let file = fileURL(name)
        guard let data = try? Data(contentsOf: file) else { return nil }
        do {
            return try JSONDecoder().decode(Versioned<T>.self, from: data).data
        } catch {
            backup(file)
            return nil
        }
    }

    /// A list loads element by element: entries that fail to decode are skipped
    /// (and the file backed up, since the next save drops them) instead of the
    /// whole list coming back empty and being overwritten.
    static func load<E: Codable>(_ type: [E].Type, from name: String) -> [E]? {
        let file = fileURL(name)
        guard let data = try? Data(contentsOf: file) else { return nil }
        do {
            let items = try JSONDecoder().decode(LossyList<E>.self, from: data).data
            let kept = items.compactMap(\.value)
            if kept.count < items.count { backup(file) }
            return kept
        } catch {
            backup(file)
            return nil
        }
    }

    /// The envelope of a list, each element decoded on its own.
    private struct LossyList<E: Decodable>: Decodable {
        var data: [Lossy<E>]
    }
    private struct Lossy<E: Decodable>: Decodable {
        var value: E?
        init(from decoder: Decoder) throws { value = try? E(from: decoder) }
    }

    /// Encodes now and writes in the background, in order, so playback's
    /// periodic saves never stall the main thread on the disk.
    static func save<T: Codable>(_ value: T, version: Int, to name: String) {
        let env = Versioned(schemaVersion: version, data: value)
        guard let data = try? JSONEncoder().encode(env) else { return }
        let url = fileURL(name)
        writes.async { try? data.write(to: url, options: .atomic) }
    }

    private static let writes = DispatchQueue(label: "Store.writes", qos: .utility)

    /// One-time migration of a legacy UserDefaults JSON blob into a versioned file.
    /// Returns the decoded value (and removes the old key) if it migrated, else nil
    /// — so existing users keep their shelf/history/progress on the first launch of
    /// the new version.
    static func migrateFromDefaults<T: Codable>(_ type: T.Type, key: String,
                                                version: Int, to name: String) -> T? {
        guard !exists(name),
              let data = UserDefaults.standard.data(forKey: key),
              let value = try? JSONDecoder().decode(T.self, from: data) else { return nil }
        save(value, version: version, to: name)
        UserDefaults.standard.removeObject(forKey: key)
        return value
    }

    /// Loads a store's payload: migrate a legacy blob if present, otherwise read the
    /// versioned file, otherwise the supplied default.
    static func loadOrMigrate<T: Codable>(_ type: T.Type, legacyKey: String,
                                          version: Int, file name: String,
                                          default fallback: T) -> T {
        migrateFromDefaults(type, key: legacyKey, version: version, to: name)
            ?? load(type, from: name)
            ?? fallback
    }

    /// The same for a list, read element by element (see `load(_:from:)` above).
    static func loadOrMigrate<E: Codable>(_ type: [E].Type, legacyKey: String,
                                          version: Int, file name: String,
                                          default fallback: [E]) -> [E] {
        migrateFromDefaults(type, key: legacyKey, version: version, to: name)
            ?? load(type, from: name)
            ?? fallback
    }

    /// Timestamped, so a later failure never overwrites an earlier backup.
    private static func backup(_ file: URL) {
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let dest = file.deletingLastPathComponent()
            .appendingPathComponent("\(file.lastPathComponent).corrupt-\(stamp)")
        try? FileManager.default.copyItem(at: file, to: dest)
    }
}
