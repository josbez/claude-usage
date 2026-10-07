import CryptoKit
import Foundation
import XCTest
@testable import UsageCore

/// Taak 47: signing moves from scripts/sign-release.py to the app itself.
final class SignReleaseTests: XCTestCase {
    /// A PKCS#8 PEM the way pycryptodome writes one, for a throwaway key.
    func pem(_ key: Curve25519.Signing.PrivateKey) -> String {
        let der = Data([0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70,
                        0x04, 0x22, 0x04, 0x20]) + key.rawRepresentation
        return "-----BEGIN PRIVATE KEY-----\n\(der.base64EncodedString())\n-----END PRIVATE KEY-----\n"
    }
    func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    func testSignsVerifiably() throws {
        let key = Curve25519.Signing.PrivateKey()
        let pub = hex(key.publicKey.rawRepresentation)
        let data = Data("een dmg".utf8)
        let sig = try signRelease(data, pem: pem(key), publicKeyHex: pub)
        XCTAssertTrue(verifyReleaseSignature(data, sig, publicKeyHex: pub))
        XCTAssertFalse(verifyReleaseSignature(Data("iets anders".utf8), sig, publicKeyHex: pub))
    }

    func testSeedRoundTrip() {
        let key = Curve25519.Signing.PrivateKey()
        XCTAssertEqual(ed25519Seed(fromPEM: pem(key)), key.rawRepresentation)
    }

    func testRefusesAKeyInstalledAppsDontKnow() {
        let key = Curve25519.Signing.PrivateKey()
        XCTAssertThrowsError(try signRelease(Data("x".utf8), pem: pem(key))) { error in
            guard case SignReleaseError.wrongKey = error else { return XCTFail("\(error)") }
        }
    }

    func testRejectsOtherKeyFormats() {
        XCTAssertNil(ed25519Seed(fromPEM: ""))
        XCTAssertNil(ed25519Seed(fromPEM: "-----BEGIN EC PRIVATE KEY-----\nAAAA\n-----END EC PRIVATE KEY-----"))
        XCTAssertNil(ed25519Seed(fromPEM: "-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----"))
        XCTAssertThrowsError(try signRelease(Data(), pem: "geen sleutel"))
    }
}
