import XCTest
@testable import PaceCore

final class ChromiumSafeStorageTests: XCTestCase {
    func testOpen_returnsPlaintextJWTUnchanged() {
        let jwt = "header.payload.sig"
        let key = Data(repeating: 1, count: 16)
        XCTAssertEqual(ChromiumSafeStorage.open(jwt, key: key), jwt)
        XCTAssertFalse(ChromiumSafeStorage.isSealed(jwt))
    }

    func testSealAndOpen_roundTripsJWT() {
        let password = Data("peanuts".utf8)
        let key = ChromiumSafeStorage.deriveKey(password: password)
        XCTAssertEqual(key?.count, 16)
        let token = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJhdXRoMHx1c2VyIn0.sig"
        let sealed = ChromiumSafeStorage.sealForTest(token, key: key!)
        XCTAssertTrue(sealed?.hasPrefix("cursor-safe-storage:v1:") == true)
        XCTAssertEqual(ChromiumSafeStorage.open(sealed!, key: key!), token)
    }

    func testOpen_wrongKeyReturnsNil() {
        let key = ChromiumSafeStorage.deriveKey(password: Data("peanuts".utf8))!
        let sealed = ChromiumSafeStorage.sealForTest("token", key: key)!
        let other = ChromiumSafeStorage.deriveKey(password: Data("not-the-key".utf8))!
        XCTAssertNil(ChromiumSafeStorage.open(sealed, key: other))
    }
}
