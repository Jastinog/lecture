import Foundation
import Security
import os

/// The listener this phone is on the server (`apps/listeners`). No sign-up:
/// the app makes up an id on first launch and registers it for a token, which
/// every request then carries. Both live in the Keychain, synced through
/// iCloud Keychain, so they outlast a reinstall and follow the listener to
/// their other devices.
@MainActor
final class Account {
    nonisolated static let shared = Account()

    struct Credentials: Codable, Equatable {
        /// A name, not a secret: the server won't hand out a token for an id
        /// it already knows.
        var id: UUID
        /// Nil until the server has registered the id.
        var token: String?
    }

    private static let log = Logger(subsystem: "com.personal.lecture", category: "account")
    /// Waits between failed registrations, doubling up to this.
    private static let maxRetryDelay: Duration = .seconds(300)

    private var credentials: Credentials?
    private var registering: Task<Void, Never>?
    /// The token, readable off the main actor by `RemoteLibrary`.
    private nonisolated let current = OSAllocatedUnfairLock<String?>(initialState: nil)

    nonisolated var token: String? { current.withLock { $0 } }

    nonisolated private init() {}

    /// Registers this phone unless it already is, retrying until the server
    /// answers. Called at launch; does nothing while a registration runs.
    func start() {
        guard registering == nil else { return }
        guard let credentials = loadOrCreate() else { return }
        guard credentials.token == nil else { return }
        registering = Task {
            await register()
            registering = nil
        }
    }

    /// The server didn't know `token` (the listener was deleted): starts over
    /// as a new listener. Ignored for a token already replaced.
    func tokenRejected(_ token: String) {
        guard credentials?.token == token else { return }
        Self.log.notice("Token rejected; registering a new listener")
        save(Credentials(id: UUID(), token: nil))
        start()
    }

    private func register() async {
        var delay: Duration = .seconds(2)
        while let credentials, credentials.token == nil, !Task.isCancelled {
            do {
                let token = try await API.library.register(
                    listener: credentials.id, platform: "ios", appVersion: Self.appVersion)
                save(Credentials(id: credentials.id, token: token))
                return
            } catch APIError.http(status: 409) {
                // The id is taken, and its token isn't here (a registration
                // whose answer was lost). One just synced from another device
                // would do; otherwise a new id.
                if case .found(let synced) = Self.read(), synced.token != nil {
                    save(synced)
                } else {
                    save(Credentials(id: UUID(), token: nil))
                }
            } catch {
                Self.log.error("Couldn't register: \(String(describing: error), privacy: .public)")
                try? await Task.sleep(for: delay)
                delay = min(delay * 2, Self.maxRetryDelay)
            }
        }
    }

    /// The saved credentials, or new ones on first launch. Nil while the
    /// Keychain can't be read (before the first unlock): making up an id then
    /// would replace the real one.
    private func loadOrCreate() -> Credentials? {
        if let credentials { return credentials }
        switch Self.read() {
        case .found(let saved):
            credentials = saved
            current.withLock { $0 = saved.token }
        case .missing:
            save(Credentials(id: UUID(), token: nil))
        case .unavailable:
            return nil
        }
        return credentials
    }

    private func save(_ new: Credentials) {
        credentials = new
        current.withLock { $0 = new.token }
        guard let data = try? JSONEncoder().encode(new) else { return }
        Keychain.write(data, account: Self.keychainAccount)
    }

    private static let keychainAccount = "listener"

    private enum Saved { case found(Credentials), missing, unavailable }

    private static func read() -> Saved {
        switch Keychain.read(account: keychainAccount) {
        case .success(let data?):
            // Unreadable data is as good as none.
            return (try? JSONDecoder().decode(Credentials.self, from: data)).map(Saved.found) ?? .missing
        case .success(nil): return .missing
        case .failure: return .unavailable
        }
    }

    /// "1.0 (7)".
    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}

/// Generic passwords of this app, synced through iCloud Keychain and readable
/// after the first unlock, so playback in the background can use them.
enum Keychain {
    struct Failure: Error { let status: OSStatus }

    private static let service = "com.personal.lecture"

    private static func query(_ account: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword,
         kSecAttrService: service,
         kSecAttrAccount: account,
         kSecAttrSynchronizable: true]
    }

    /// The item's data, nil when there's none, or a failure (a locked phone).
    static func read(account: String) -> Result<Data?, Failure> {
        var query = query(account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return .success(result as? Data)
        case errSecItemNotFound: return .success(nil)
        default: return .failure(Failure(status: status))
        }
    }

    @discardableResult
    static func write(_ data: Data, account: String) -> Bool {
        let attributes: [CFString: Any] = [kSecValueData: data,
                                           kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock]
        var status = SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query(account).merging(attributes) { $1 } as CFDictionary, nil)
        }
        return status == errSecSuccess
    }
}
