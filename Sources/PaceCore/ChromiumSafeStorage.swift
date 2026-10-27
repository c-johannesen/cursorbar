import CommonCrypto
import Foundation

/// Cursor seals `cursorAuth/accessToken` with Electron safeStorage.
/// The cell is `cursor-safe-storage:v1:` plus standard base64 of a Chromium
/// `v10`/`v11` AES-128-CBC blob. The key comes from the login keychain.
public enum ChromiumSafeStorage {
    public static func isSealed(_ stored: String) -> Bool {
        stored.hasPrefix("cursor-safe-storage:")
    }

    /// Unwrap a stored cell. A plaintext JWT is returned as-is.
    public static func open(_ stored: String, key: Data) -> String? {
        guard isSealed(stored) else { return stored }
        guard let blob = ciphertext(in: stored) else { return nil }
        return decrypt(blob, key: key)
    }

    public static func deriveKey(password: Data) -> Data? {
        guard !password.isEmpty else { return nil }
        let salt = Array("saltysalt".utf8)
        var derived = Data(count: 16)
        let status: Int32 = salt.withUnsafeBufferPointer { saltBuf in
            derived.withUnsafeMutableBytes { derivedBuf in
                password.withUnsafeBytes { passwordBuf in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBuf.baseAddress?.assumingMemoryBound(to: Int8.self),
                        password.count,
                        saltBuf.baseAddress,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        1003,
                        derivedBuf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        16
                    )
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return derived
    }

    /// Test helper. Production only decrypts what Cursor already wrote.
    static func sealForTest(_ plaintext: String, key: Data) -> String? {
        guard let encrypted = encrypt(Data(plaintext.utf8), key: key) else { return nil }
        return "cursor-safe-storage:v1:" + encrypted.base64EncodedString()
    }

    private static func ciphertext(in stored: String) -> Data? {
        let marker = "cursor-safe-storage:"
        guard stored.hasPrefix(marker) else { return nil }
        var rest = stored.dropFirst(marker.count)
        if rest.first == "v" {
            let digits = rest.dropFirst().prefix(while: \.isNumber)
            if !digits.isEmpty {
                let afterDigits = rest.index(rest.startIndex, offsetBy: 1 + digits.count)
                if afterDigits < rest.endIndex, rest[afterDigits] == ":" {
                    rest = rest[rest.index(after: afterDigits)...]
                }
            }
        }
        var encoded = String(rest).trimmingCharacters(in: .whitespacesAndNewlines)
        let remainder = encoded.count % 4
        if remainder > 0 {
            encoded += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: encoded)
    }

    private static func decrypt(_ blob: Data, key: Data) -> String? {
        guard blob.count > 3 + kCCBlockSizeAES128 else { return nil }
        let version = blob.prefix(3)
        guard version == Data("v10".utf8) || version == Data("v11".utf8) else { return nil }
        let ciphertext = Data(blob.dropFirst(3))
        guard ciphertext.count.isMultiple(of: kCCBlockSizeAES128) else { return nil }
        return crypt(ciphertext, key: key, operation: CCOperation(kCCDecrypt)).flatMap {
            String(data: $0, encoding: .utf8)
        }
    }

    private static func encrypt(_ plaintext: Data, key: Data) -> Data? {
        guard let ciphertext = crypt(plaintext, key: key, operation: CCOperation(kCCEncrypt)) else {
            return nil
        }
        return Data("v10".utf8) + ciphertext
    }

    private static func crypt(_ input: Data, key: Data, operation: CCOperation) -> Data? {
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        let outputCapacity = input.count + kCCBlockSizeAES128
        var output = Data(count: outputCapacity)
        var written = 0
        let status: CCCryptorStatus = output.withUnsafeMutableBytes { outputBuf in
            input.withUnsafeBytes { inputBuf in
                key.withUnsafeBytes { keyBuf in
                    iv.withUnsafeBytes { ivBuf in
                        CCCrypt(
                            operation,
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBuf.baseAddress,
                            key.count,
                            ivBuf.baseAddress,
                            inputBuf.baseAddress,
                            input.count,
                            outputBuf.baseAddress,
                            outputCapacity,
                            &written
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return output.prefix(written)
    }
}
