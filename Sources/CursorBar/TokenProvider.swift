import Foundation
import PaceCore
import Security
import SQLite3

enum TokenProviderError: Error, LocalizedError {
    case databaseNotFound
    case tokenNotFound
    case invalidToken
    case keychainDenied
    case keychainMissing

    var errorDescription: String? {
        switch self {
        case .databaseNotFound:
            "Cursor database not found. Is Cursor installed and logged in?"
        case .tokenNotFound:
            "No auth token found. Please log in to Cursor."
        case .invalidToken:
            "Could not parse auth token."
        case .keychainDenied:
            "macOS did not allow CursorBar to read the Cursor keychain item. Click Allow on the prompt, then refresh."
        case .keychainMissing:
            "Cursor keychain item “Cursor Safe Storage” was not found."
        }
    }
}

struct SessionCredentials: Sendable {
    let cookieValue: String
}

enum TokenProvider {
    static let databasePath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")

    static func loadSessionCredentials() throws -> SessionCredentials {
        guard FileManager.default.fileExists(atPath: databasePath.path) else {
            throw TokenProviderError.databaseNotFound
        }

        var database: OpaquePointer?
        guard sqlite3_open_v2(databasePath.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw TokenProviderError.databaseNotFound
        }
        defer { sqlite3_close(database) }

        let query = "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken'"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else {
            throw TokenProviderError.tokenNotFound
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW,
              let cString = sqlite3_column_text(statement, 0)
        else {
            throw TokenProviderError.tokenNotFound
        }

        let stored = String(cString: cString)
        let accessToken = try unseal(stored)
        let userID = try extractUserID(from: accessToken)
        let cookieValue = "\(userID)%3A%3A\(accessToken)"
        return SessionCredentials(cookieValue: cookieValue)
    }

    private static func extractUserID(from jwt: String) throws -> String {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else {
            throw TokenProviderError.invalidToken
        }

        var payload = String(parts[1])
        let padding = payload.count % 4
        if padding > 0 {
            payload += String(repeating: "=", count: 4 - padding)
        }
        payload = payload
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subject = json["sub"] as? String
        else {
            throw TokenProviderError.invalidToken
        }

        if let separatorIndex = subject.lastIndex(of: "|") {
            return String(subject[subject.index(after: separatorIndex)...])
        }
        return subject
    }

    /// Cursor now writes `cursor-safe-storage:v1:` instead of a plaintext JWT.
    /// The AES key is derived once per process so a 5-minute refresh does not
    /// raise the keychain prompt again.
    private static let keyCache = SafeStorageKeyCache()

    private static func unseal(_ stored: String) throws -> String {
        guard ChromiumSafeStorage.isSealed(stored) else { return stored }

        if let cached = keyCache.get(),
           let token = ChromiumSafeStorage.open(stored, key: cached) {
            return token
        }

        keyCache.clear()
        let password = try CursorKeychain.password()
        guard let key = ChromiumSafeStorage.deriveKey(password: password),
              let token = ChromiumSafeStorage.open(stored, key: key)
        else {
            throw TokenProviderError.invalidToken
        }
        keyCache.set(key)
        return token
    }
}

private final class SafeStorageKeyCache: @unchecked Sendable {
    private let lock = NSLock()
    private var key: Data?

    func get() -> Data? { lock.withLock { key } }
    func set(_ key: Data) { lock.withLock { self.key = key } }
    func clear() { lock.withLock { key = nil } }
}

private enum CursorKeychain {
    static let service = "Cursor Safe Storage"
    static let accounts = ["Cursor Key", "Cursor"]

    static func password() throws -> Data {
        var sawMissing = false
        for account in accounts {
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query(account: account), &item)
            switch status {
            case errSecSuccess:
                guard let data = item as? Data, !data.isEmpty else {
                    throw TokenProviderError.invalidToken
                }
                return data
            case errSecItemNotFound:
                sawMissing = true
            case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
                throw TokenProviderError.keychainDenied
            default:
                throw TokenProviderError.keychainDenied
            }
        }
        if sawMissing {
            throw TokenProviderError.keychainMissing
        }
        throw TokenProviderError.keychainDenied
    }

    private static func query(account: String) -> CFDictionary {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ] as CFDictionary
    }
}
