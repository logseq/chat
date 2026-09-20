#if os(iOS)
import Foundation
import Security
import Testing
@testable import LogseqChatModel

@Suite struct E2EECryptoTests {
    private func derLength(_ count: Int) -> Data {
        if count < 128 { return Data([UInt8(count)]) }
        var value = count
        var bytes: [UInt8] = []
        while value > 0 {
            bytes.insert(UInt8(value & 0xff), at: 0)
            value >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }

    private func der(_ tag: UInt8, _ contents: Data) -> Data {
        Data([tag]) + derLength(contents.count) + contents
    }

    private var rsaAlgorithmIdentifier: Data {
        let rsaEncryptionOID = Data([0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01])
        return der(0x30, rsaEncryptionOID + Data([0x05, 0x00]))
    }

    private func pkcs8(_ pkcs1: Data) -> Data {
        der(0x30, Data([0x02, 0x01, 0x00]) + rsaAlgorithmIdentifier + der(0x04, pkcs1))
    }

    private func request(_ fields: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: fields)
        let json = String(decoding: data, as: UTF8.self)
        let pointer = json.withCString { logseqChatCryptoJSON($0) }
        guard let pointer else { throw TestError.nilResponse }
        defer { free(pointer) }
        let responseData = Data(String(cString: pointer).utf8)
        return try #require(
            JSONSerialization.jsonObject(with: responseData) as? [String: Any]
        )
    }

    private enum TestError: Error {
        case keyGeneration
        case encryption
        case nilResponse
    }

    @Test func accountPrivateKeyDecryptsWebCryptoWrappedGraphKey() throws {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: 4096,
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
              let publicKey = SecKeyCopyPublicKey(privateKey),
              let pkcs1 = SecKeyCopyExternalRepresentation(privateKey, &error) as Data?
        else { throw TestError.keyGeneration }

        let plaintext = Data(repeating: 0x5a, count: 32)
        guard let ciphertext = SecKeyCreateEncryptedData(
            publicKey,
            .rsaEncryptionOAEPSHA256,
            plaintext as CFData,
            &error
        ) as Data? else { throw TestError.encryption }

        let response = try request([
            "operation": "decryptGraphKey",
            "privateKey": pkcs8(pkcs1).map { String(format: "%02x", $0) }.joined(),
            "ciphertext": ciphertext.map { String(format: "%02x", $0) }.joined(),
        ])

        #expect(response["ok"] as? Bool == true)
        #expect(response["value"] as? String == plaintext.map { String(format: "%02x", $0) }.joined())
    }
}
#endif
