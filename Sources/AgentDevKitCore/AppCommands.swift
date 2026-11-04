import Foundation

public struct Command<Input: Codable & Sendable, Output: Codable & Sendable>: Sendable {
    public let method: String
    public init(_ method: String) { self.method = method }
}

public enum AppCommands {
    public static let open = Command<OpenScreen, ScreenState>("navigation.open")
    public static let load = Command<LoadFixture, FixtureState>("fixtures.load")
    public static let snapshot = Command<SnapshotRequest, ScreenState>("state.snapshot")
    public static let prepare = Command<PrepareScenario, ScenarioState>("scenario.prepare")
}

public struct RouteContext: Codable, Sendable {
    public let projectId: String?
    public let nodeId: String?
    public init(projectId: String? = nil, nodeId: String? = nil) {
        self.projectId = projectId
        self.nodeId = nodeId
    }

    public init(from decoder: any Decoder) throws {
        try validateKeys(in: decoder, allowed: ["projectId", "nodeId"])
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        self.init(projectId: try fields.decodeIfPresent(String.self, forKey: .projectId),
                  nodeId: try fields.decodeIfPresent(String.self, forKey: .nodeId))
    }

    private enum CodingKeys: String, CodingKey { case projectId, nodeId }
}

public struct OpenScreen: Codable, Sendable {
    public let route: String
    public let context: RouteContext?
    public let waitForReady: Bool?
    public init(route: String, context: RouteContext? = nil, waitForReady: Bool? = nil) {
        self.route = route
        self.context = context
        self.waitForReady = waitForReady
    }
}

public struct LoadFixture: Codable, Sendable {
    public let fixture: String
    public init(fixture: String) { self.fixture = fixture }
}

public struct SnapshotRequest: Codable, Sendable {
    public let scope: String
    public init(scope: String) { self.scope = scope }
}

public struct PrepareScenario: Codable, Sendable {
    public let fixture: String
    public let route: String
    public let context: RouteContext?
    public let waitForReady: Bool?
    public init(fixture: String, route: String, context: RouteContext? = nil, waitForReady: Bool? = nil) {
        self.fixture = fixture
        self.route = route
        self.context = context
        self.waitForReady = waitForReady
    }
}

public struct ScreenState: Codable, Sendable {
    public let screenId: String
    public let windowId: String
    public let ready: Bool
    public let revision: UInt64
    public let scope: String
    public let fields: [String: JSONValue]
    public let operationId: UUID?
    public let blockers: [String]?

    public init(
        screenId: String, windowId: String, ready: Bool, revision: UInt64,
        scope: String, fields: [String: JSONValue] = [:], operationId: UUID? = nil, blockers: [String]? = nil
    ) {
        self.screenId = screenId
        self.windowId = windowId
        self.ready = ready
        self.revision = revision
        self.scope = scope
        self.fields = fields
        self.operationId = operationId
        self.blockers = blockers
    }
}

public struct FixtureState: Codable, Sendable {
    public let fixture: String
    public let projectId: String?
    public let nodeId: String?
    public let revision: UInt64
    public init(fixture: String, projectId: String?, nodeId: String?, revision: UInt64) {
        self.fixture = fixture
        self.projectId = projectId
        self.nodeId = nodeId
        self.revision = revision
    }
}

public struct ScenarioState: Codable, Sendable {
    public let fixture: FixtureState
    public let screen: ScreenState
    public init(fixture: FixtureState, screen: ScreenState) {
        self.fixture = fixture
        self.screen = screen
    }
}

public enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else if let integer = try? value.decode(Int64.self) { self = .integer(integer) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let array = try? value.decode([JSONValue].self) { self = .array(array) }
        else { self = .object(try value.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .bool(let bool): try value.encode(bool)
        case .integer(let integer): try value.encode(integer)
        case .number(let number): try value.encode(number)
        case .string(let string): try value.encode(string)
        case .array(let array): try value.encode(array)
        case .object(let object): try value.encode(object)
        }
    }
}

package func validateKeys(in decoder: any Decoder, allowed: Set<String>) throws {
    let fields = try decoder.container(keyedBy: AnyKey.self)
    guard fields.allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown object field."))
    }
}

private struct AnyKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
