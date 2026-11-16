import CommonCrypto
import Foundation
import Security
import SQLite3

enum TokenProviderError: Error, LocalizedError {
    case databaseNotFound
    case tokenNotFound
    case invalidToken
    case keychainUnavailable
    case unsupportedEncryption
    case decryptionFailed

    var errorDescription: String? {
        switch self {
        case .databaseNotFound:
            "Cursor database not found. Is Cursor installed and logged in?"
        case .tokenNotFound:
            "No auth token found. Please log in to Cursor."
        case .invalidToken:
            "Could not parse auth token."
        case .keychainUnavailable:
            "Could not unlock Cursor Safe Storage. Allow Keychain access for CursorBar, or sign in to Cursor again."
        case .unsupportedEncryption:
            "Unsupported encrypted Cursor token format."
        case .decryptionFailed:
            "Could not decrypt Cursor auth token."
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

        let accessToken = try CursorSafeStorage.resolveAccessToken(String(cString: cString))
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
}

/// Decrypts Cursor's `cursor-safe-storage:v1:` Electron safeStorage blobs via
/// Chromium OSCrypt (Keychain password → PBKDF2 → AES-128-CBC).
private enum CursorSafeStorage {
    static let storagePrefix = "cursor-safe-storage:v1:"
    private static let service = "Cursor Safe Storage"
    /// Current Electron naming uses "Cursor Key"; older builds may use "Cursor".
    private static let accounts = ["Cursor Key", "Cursor"]
    private static let versionPrefix = Data("v10".utf8)
    private static let pbkdfSalt = Array("saltysalt".utf8)
    private static let pbkdfIterations: UInt32 = 1003
    private static let derivedKeyLength = 16
    private static let aesIV = Data(repeating: UInt8(ascii: " "), count: kCCBlockSizeAES128)

    private static let cacheLock = NSLock()
    // Protected by cacheLock; nonisolated(unsafe) satisfies Swift 6 global mutability rules.
    nonisolated(unsafe) private static var cachedDerivedKey: Data?

    static func resolveAccessToken(_ raw: String) throws -> String {
        guard raw.hasPrefix(storagePrefix) else {
            return raw
        }

        let encoded = String(raw.dropFirst(storagePrefix.count))
        guard let blob = Data(base64Encoded: encoded) else {
            throw TokenProviderError.unsupportedEncryption
        }
        guard blob.starts(with: versionPrefix), blob.count > versionPrefix.count else {
            throw TokenProviderError.unsupportedEncryption
        }

        let ciphertext = Data(blob.dropFirst(versionPrefix.count))
        guard ciphertext.count.isMultiple(of: kCCBlockSizeAES128) else {
            throw TokenProviderError.unsupportedEncryption
        }

        let key = try derivedKey()
        guard let plaintext = aesDecrypt(ciphertext, key: key),
              let token = String(data: plaintext, encoding: .utf8)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty
        else {
            throw TokenProviderError.decryptionFailed
        }
        return token
    }

    private static func derivedKey() throws -> Data {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        if let cachedDerivedKey {
            return cachedDerivedKey
        }

        var lastError = TokenProviderError.keychainUnavailable
        for account in accounts {
            do {
                let password = try readKeychainPassword(account: account)
                let key = try deriveKey(from: password)
                cachedDerivedKey = key
                return key
            } catch let error as TokenProviderError {
                lastError = error
            }
        }

        // Last resort: match by service only (account naming varies across Electron builds).
        do {
            let password = try readKeychainPassword(account: nil)
            let key = try deriveKey(from: password)
            cachedDerivedKey = key
            return key
        } catch let error as TokenProviderError {
            lastError = error
        }

        throw lastError
    }

    private static func readKeychainPassword(account: String?) throws -> Data {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                throw TokenProviderError.keychainUnavailable
            }
            if status == errSecUserCanceled || status == errSecAuthFailed {
                throw TokenProviderError.keychainUnavailable
            }
            throw TokenProviderError.keychainUnavailable
        }

        guard let data = item as? Data, !data.isEmpty else {
            throw TokenProviderError.keychainUnavailable
        }
        return data
    }

    private static func deriveKey(from password: Data) throws -> Data {
        var derived = Data(count: derivedKeyLength)
        let status = derived.withUnsafeMutableBytes { derivedBytes in
            password.withUnsafeBytes { passwordBytes in
                pbkdfSalt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.bindMemory(to: Int8.self).baseAddress,
                        password.count,
                        saltBytes.bindMemory(to: UInt8.self).baseAddress,
                        pbkdfSalt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        pbkdfIterations,
                        derivedBytes.bindMemory(to: UInt8.self).baseAddress,
                        derivedKeyLength
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw TokenProviderError.decryptionFailed
        }
        return derived
    }

    private static func aesDecrypt(_ ciphertext: Data, key: Data) -> Data? {
        var output = Data(count: ciphertext.count + kCCBlockSizeAES128)
        let outputCapacity = output.count
        var moved = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            ciphertext.withUnsafeBytes { cipherBytes in
                key.withUnsafeBytes { keyBytes in
                    aesIV.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            cipherBytes.baseAddress,
                            ciphertext.count,
                            outputBytes.baseAddress,
                            outputCapacity,
                            &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            return nil
        }
        output.removeSubrange(moved..<output.count)
        return output
    }
}
