import Foundation

public struct Command<Input: Codable & Sendable, Output: Codable & Sendable>: Sendable {
    public let method: String
    /// Mutating commands are served only by sessions opened with mutation access, one at a time.
    public let mutating: Bool
    public init(_ method: String, mutating: Bool = false) {
        self.method = method
        self.mutating = mutating
    }
}

public enum AppCommands {
    public static let open = Command<OpenScreen, ScreenState>("navigation.open", mutating: true)
    public static let load = Command<LoadFixture, FixtureState>("fixtures.load", mutating: true)
    public static let snapshot = Command<SnapshotRequest, ScreenState>("state.snapshot")
    public static let prepare = Command<PrepareScenario, ScenarioState>("scenario.prepare", mutating: true)
}

/// App-defined route context. Each route advertises the accepted keys in its `contextSchema`.
public typealias RouteContext = [String: JSONValue]

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
    public let revision: UInt64
    /// App-defined summary of the loaded data, such as the selected entity IDs.
    public let fields: [String: JSONValue]
    public init(fixture: String, revision: UInt64, fields: [String: JSONValue] = [:]) {
        self.fixture = fixture
        self.revision = revision
        self.fields = fields
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

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByFloatLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int64) { self = .integer(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    public init(nilLiteral: ()) { self = .null }

    public var stringValue: String? { if case .string(let value) = self { value } else { nil } }
    public var integerValue: Int64? { if case .integer(let value) = self { value } else { nil } }
    public var boolValue: Bool? { if case .bool(let value) = self { value } else { nil } }
    public var objectValue: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
    public var arrayValue: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
}
