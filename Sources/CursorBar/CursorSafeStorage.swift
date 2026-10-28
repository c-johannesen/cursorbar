import CommonCrypto
import Foundation
import Security

/// Unwraps Cursor's `cursor-safe-storage:v1:` access tokens.
///
/// Cursor encrypts `cursorAuth/accessToken` with Electron `safeStorage`, which on macOS is
/// Chromium OSCrypt: PBKDF2-HMAC-SHA1 (salt `saltysalt`, 1003 rounds, 16-byte key) and
/// AES-128-CBC with an IV of 16 spaces. The keychain item is `Cursor Safe Storage` / `Cursor Key`.
enum CursorSafeStorage {
    private static let wrapperPrefix = "cursor-safe-storage:"
    private static let keychainService = "Cursor Safe Storage"
    private static let keychainAccount = "Cursor Key"
    private static let salt = Data("saltysalt".utf8)
    private static let iterations: UInt32 = 1003
    private static let keyLength = 16
    private static let versionPrefix = Data("v10".utf8)

    static func accessToken(from stored: String) throws -> String {
        guard stored.hasPrefix(wrapperPrefix) else {
            return stored
        }
        // Validate the envelope before touching the keychain so a corrupt value
        // cannot raise the macOS password prompt.
        let ciphertext = try ciphertext(from: stored)
        let password = try keychainPassword()
        return try plaintext(ciphertext: ciphertext, password: password)
    }

    static func decrypt(wrapped: String, password: String) throws -> String {
        let ciphertext = try ciphertext(from: wrapped)
        return try plaintext(ciphertext: ciphertext, password: password)
    }

    private static func ciphertext(from wrapped: String) throws -> Data {
        guard wrapped.hasPrefix(wrapperPrefix) else {
            throw TokenProviderError.decryptFailed
        }

        let remainder = wrapped.dropFirst(wrapperPrefix.count)
        guard let separator = remainder.firstIndex(of: ":") else {
            throw TokenProviderError.decryptFailed
        }
        let version = remainder[..<separator]
        let encoded = remainder[remainder.index(after: separator)...]
        guard version == "v1", let blob = decodeBase64(String(encoded)) else {
            throw TokenProviderError.decryptFailed
        }
        guard blob.count > versionPrefix.count, blob.prefix(versionPrefix.count) == versionPrefix else {
            throw TokenProviderError.decryptFailed
        }
        return Data(blob.dropFirst(versionPrefix.count))
    }

    private static func plaintext(ciphertext: Data, password: String) throws -> String {
        let key = try deriveKey(password: password)
        let decrypted = try decryptAES128CBC(ciphertext: ciphertext, key: key)
        guard let token = String(data: decrypted, encoding: .utf8), !token.isEmpty else {
            throw TokenProviderError.decryptFailed
        }
        return token
    }

    private static func keychainPassword() throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let password = String(data: data, encoding: .utf8),
              !password.isEmpty
        else {
            throw TokenProviderError.keychainAccessDenied
        }
        return password
    }

    private static func deriveKey(password: String) throws -> Data {
        let passwordData = Data(password.utf8)
        var derived = Data(count: keyLength)
        let status = derived.withUnsafeMutableBytes { derivedBytes in
            passwordData.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                        passwordData.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        iterations,
                        derivedBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        keyLength
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw TokenProviderError.decryptFailed
        }
        return derived
    }

    private static func decryptAES128CBC(ciphertext: Data, key: Data) throws -> Data {
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        var output = Data(count: ciphertext.count + kCCBlockSizeAES128)
        var written = 0
        let status = ciphertext.withUnsafeBytes { cipherBytes in
            key.withUnsafeBytes { keyBytes in
                iv.withUnsafeBytes { ivBytes in
                    output.withUnsafeMutableBytes { outputBytes in
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
                            outputBytes.count,
                            &written
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw TokenProviderError.decryptFailed
        }
        return output.prefix(written)
    }

    private static func decodeBase64(_ encoded: String) -> Data? {
        var value = encoded.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
        let remainder = value.count % 4
        if remainder > 0 {
            value += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: value)
    }
}
