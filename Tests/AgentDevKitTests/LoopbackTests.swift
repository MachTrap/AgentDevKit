import AgentDevKitClient
import AgentDevKitCore
import AgentDevKitHost
import AgentDevKitTransport
import Foundation
import Security
import Testing

@Suite struct LoopbackTests {
    @Test func pairedLoopbackServesPinnedClientAndRejectsChangedPin() async throws {
        let folder = URL(fileURLWithPath: "/tmp/adk-pair-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let bundleId = "dev.agentdevkit.tests.loopback." + UUID().uuidString
        let host = AgentHost(configuration: .init(identity: .fixed(bundleId: bundleId, buildFingerprint: "loopback-test")))
        try await host.start(at: .pairingDirectory(folder), loopbackIdentity: TestIdentity.make)

        let source = SessionLocation.pairingDirectory(folder)
        let hello = try await AgentClient(session: bundleId, at: source).hello()
        #expect(hello.result?.bundleId == bundleId)

        let descriptor = try #require(SessionDirectory.discover(source).first)
        let port = try #require(descriptor.port)
        let request = Request(sessionId: descriptor.identity.sessionId, auth: descriptor.auth,
                              method: .hello, params: EmptyParameters())
        let payload = try JSONEncoder().encode(request)
        await #expect(throws: (any Error).self) {
            _ = try await Loopback.exchange(payload, port: port, pin: Data(repeating: 0, count: 32), timeoutMs: 1_000)
        }
        // A changed pin must not consume the credentialed request.
        let response = try await Loopback.exchange(payload, port: port, pin: try #require(descriptor.certificatePin), timeoutMs: 1_000)
        #expect(try JSONDecoder().decode(Response<SessionIdentity>.self, from: response).ok)

        await host.stop()
        #expect(try SessionDirectory.discover(source).isEmpty)
    }

    @Test func invalidPairingFolderReportsTypedStartError() async throws {
        let folder = URL(fileURLWithPath: "/tmp/adk-pair-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o755])
        defer { try? FileManager.default.removeItem(at: folder) }
        let host = AgentHost(configuration: .init(identity: .fixed(bundleId: "dev.agentdevkit.tests.invalid", buildFingerprint: "x")))
        await #expect(throws: AgentHostStartError.pairingFolderInvalid) {
            try await host.start(at: .pairingDirectory(folder), loopbackIdentity: TestIdentity.make)
        }
        #expect(await host.state == .failed(.pairingFolderInvalid))
    }
}

/// A minimal self-signed P-256 certificate, so the root package stays free of dependencies.
enum TestIdentity {
    static func make() throws -> SecIdentity {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrIsPermanent as String: false
        ]
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, nil),
              let publicKey = SecKeyCopyPublicKey(key),
              let point = SecKeyCopyExternalRepresentation(publicKey, nil) as Data?
        else { throw TestFailure() }

        let ecdsaSHA256 = der(0x30, der(0x06, [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02]))
        let name = der(0x30, der(0x31, der(0x30, der(0x06, [0x55, 0x04, 0x03]) + der(0x0C, Array("ADK Test".utf8)))))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyMMddHHmmss'Z'"
        let validity = der(0x30, der(0x17, Array(formatter.string(from: Date().addingTimeInterval(-60)).utf8))
                            + der(0x17, Array(formatter.string(from: Date().addingTimeInterval(3_600)).utf8)))
        let algorithm = der(0x30, der(0x06, [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01])
                             + der(0x06, [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07]))
        let subjectKey = der(0x30, algorithm + der(0x03, [0] + Array(point)))
        let tbs = der(0x30, der(0xA0, der(0x02, [2])) + der(0x02, [1]) + ecdsaSHA256 + name + validity + name + subjectKey)
        guard let signature = SecKeyCreateSignature(key, .ecdsaSignatureMessageX962SHA256, Data(tbs) as CFData, nil) as Data?
        else { throw TestFailure() }
        let certificate = der(0x30, tbs + ecdsaSHA256 + der(0x03, [0] + Array(signature)))
        guard let leaf = SecCertificateCreateWithData(nil, Data(certificate) as CFData),
              let identity = SecIdentityCreate(nil, leaf, key)
        else { throw TestFailure() }
        return identity
    }

    private static func der(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        let count = content.count
        let length: [UInt8] = count < 0x80 ? [UInt8(count)]
            : count < 0x100 ? [0x81, UInt8(count)] : [0x82, UInt8(count >> 8), UInt8(count & 0xFF)]
        return [tag] + length + content
    }
}
