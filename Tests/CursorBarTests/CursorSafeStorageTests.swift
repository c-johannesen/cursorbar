import CommonCrypto
import XCTest
@testable import CursorBar

final class CursorSafeStorageTests: XCTestCase {
    private let password = "fixture-password"
    private let subject = "google-oauth2|user_01TEST"

    func testDecryptRoundTripExtractsUserID() throws {
        let jwt = try jwt(sub: subject)
        let wrapped = try wrap(jwt, password: password)

        let plaintext = try CursorSafeStorage.decrypt(wrapped: wrapped, password: password)
        XCTAssertEqual(plaintext, jwt)

        let userID = try TokenProvider.extractUserID(from: plaintext)
        XCTAssertEqual(userID, "user_01TEST")

        let credentials = try TokenProvider.sessionCredentials(fromAccessToken: plaintext)
        XCTAssertEqual(credentials.cookieValue, "user_01TEST%3A%3A\(jwt)")
        XCTAssertFalse(credentials.cookieValue.contains("cursor-safe-storage"))
    }

    func testPlaintextTokenSkipsKeychain() throws {
        let jwt = try jwt(sub: subject)
        let resolved = try CursorSafeStorage.accessToken(from: jwt)
        XCTAssertEqual(resolved, jwt)
    }

    func testUnknownWrapperVersionThrows() {
        XCTAssertThrowsError(
            try CursorSafeStorage.decrypt(wrapped: "cursor-safe-storage:v2:aaaa", password: password)
        ) { error in
            XCTAssertEqual(error as? TokenProviderError, .decryptFailed)
        }
    }

    func testMalformedWrapperFailsBeforeKeychain() {
        XCTAssertThrowsError(
            try CursorSafeStorage.accessToken(from: "cursor-safe-storage:v2:aaaa")
        ) { error in
            XCTAssertEqual(error as? TokenProviderError, .decryptFailed)
        }
    }

    func testWrongPasswordThrows() throws {
        let wrapped = try wrap(try jwt(sub: subject), password: password)
        XCTAssertThrowsError(
            try CursorSafeStorage.decrypt(wrapped: wrapped, password: "other-password")
        ) { error in
            XCTAssertEqual(error as? TokenProviderError, .decryptFailed)
        }
    }

    private func jwt(sub: String) throws -> String {
        let header = Data(#"{"alg":"none"}"#.utf8)
        let payload = try JSONSerialization.data(withJSONObject: ["sub": sub])
        return "\(base64URL(header)).\(base64URL(payload)).sig"
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Chromium OSCrypt encrypt, independent of `CursorSafeStorage`'s decrypt implementation.
    private func wrap(_ plaintext: String, password: String) throws -> String {
        let key = try deriveKey(password: password)
        let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
        let plain = Data(plaintext.utf8)
        var output = Data(count: plain.count + kCCBlockSizeAES128)
        var written = 0
        let status = plain.withUnsafeBytes { plainBytes in
            key.withUnsafeBytes { keyBytes in
                iv.withUnsafeBytes { ivBytes in
                    output.withUnsafeMutableBytes { outputBytes in
                        CCCrypt(
                            CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            plainBytes.baseAddress,
                            plain.count,
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
        var blob = Data("v10".utf8)
        blob.append(output.prefix(written))
        return "cursor-safe-storage:v1:\(blob.base64EncodedString())"
    }

    private func deriveKey(password: String) throws -> Data {
        let passwordData = Data(password.utf8)
        let salt = Data("saltysalt".utf8)
        var derived = Data(count: 16)
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
                        1003,
                        derivedBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        16
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            throw TokenProviderError.decryptFailed
        }
        return derived
    }
}
