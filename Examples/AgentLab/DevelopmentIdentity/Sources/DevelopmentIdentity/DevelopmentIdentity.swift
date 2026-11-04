import Foundation
import Security
import SwiftASN1
import X509

/// Creates a fresh in-memory key and certificate for a single local Testing session.
public enum DevelopmentIdentity {
    public static func make() throws -> SecIdentity {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrIsPermanent as String: false
        ]
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, nil) else {
            throw CocoaError(.featureUnsupported)
        }
        let privateKey = try Certificate.PrivateKey(key)
        let name = try DistinguishedName { CommonName("AgentLab Loopback Testing") }
        let now = Date()
        let certificate = try Certificate(
            version: .v3, serialNumber: .init(),
            publicKey: privateKey.publicKey,
            notValidBefore: now.addingTimeInterval(-60), notValidAfter: now.addingTimeInterval(86_400),
            issuer: name, subject: name,
            extensions: Certificate.Extensions {
                KeyUsage(digitalSignature: true)
                try ExtendedKeyUsage([.serverAuth])
            },
            issuerPrivateKey: privateKey
        )
        var serializer = DER.Serializer()
        try serializer.serialize(certificate)
        guard let leaf = SecCertificateCreateWithData(nil, Data(serializer.serializedBytes) as CFData),
              let identity = SecIdentityCreate(nil, leaf, key)
        else { throw CocoaError(.featureUnsupported) }
        return identity
    }
}
