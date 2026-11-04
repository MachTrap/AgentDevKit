import AgentDevKitCore
import Foundation
import Testing

@Test func headerAndEmptyParametersRoundTrip() throws {
    let request = Request(sessionId: UUID(), auth: "test", method: .hello, params: EmptyParameters())
    let data = try JSONEncoder().encode(request)
    let header = try JSONDecoder().decode(RequestHeader.self, from: data)
    #expect(header.requestId == request.requestId)
    #expect(header.sessionId == request.sessionId)
    #expect(header.version == Wire.version)
    #expect(header.method == SystemMethod.hello.rawValue)
    _ = try JSONDecoder().decode(Request<EmptyParameters>.self, from: data)
}

@Test(arguments: ["[]", "null", "{\"extra\":true}"])
func emptyParametersRejectOtherShapes(_ input: String) {
    #expect(throws: DecodingError.self) {
        _ = try JSONDecoder().decode(EmptyParameters.self, from: Data(input.utf8))
    }
}
