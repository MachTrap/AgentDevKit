import AgentDevKitCore
import Foundation

/// A small, closed JSON Schema subset. The host validates every parameter object,
/// route context, action input and condition argument against one of these before decoding.
public indirect enum Schema: Sendable, Equatable {
    case string(maxLength: Int = 512, oneOf: [String]? = nil)
    case uuid
    case integer(minimum: Int64? = nil, maximum: Int64? = nil)
    case number
    case boolean
    /// Any JSON value up to the given encoded depth, for comparisons such as `state.field_equals`.
    case value
    case array(Schema, maxItems: Int = 32)
    case object(ObjectSchema)

    public var json: JSONValue {
        switch self {
        case .string(let maxLength, let values):
            var schema: [String: JSONValue] = ["type": "string", "maxLength": .integer(Int64(maxLength))]
            if let values { schema["enum"] = .array(values.map(JSONValue.string)) }
            return .object(schema)
        case .uuid: return ["type": "string", "format": "uuid"]
        case .integer(let minimum, let maximum):
            var schema: [String: JSONValue] = ["type": "integer"]
            if let minimum { schema["minimum"] = .integer(minimum) }
            if let maximum { schema["maximum"] = .integer(maximum) }
            return .object(schema)
        case .number: return ["type": "number"]
        case .boolean: return ["type": "boolean"]
        case .value: return [:]
        case .array(let items, let maxItems): return ["type": "array", "items": items.json, "maxItems": .integer(Int64(maxItems))]
        case .object(let object): return object.json
        }
    }

    func validate(_ value: JSONValue, at path: String) throws {
        func reject(_ reason: String) -> Failure {
            Failure(.invalidParams, "Field \(path) \(reason).", details: ["field": .string(path)])
        }
        switch (self, value) {
        case (.string(let maxLength, let values), .string(let text)):
            guard text.utf8.count <= maxLength else { throw reject("exceeds \(maxLength) UTF-8 bytes") }
            if let values, !values.contains(text) { throw reject("is not an allowed value") }
        case (.uuid, .string(let text)):
            guard UUID(uuidString: text) != nil else { throw reject("must be a UUID") }
        case (.integer(let minimum, let maximum), .integer(let number)):
            if let minimum, number < minimum { throw reject("is below \(minimum)") }
            if let maximum, number > maximum { throw reject("is above \(maximum)") }
        case (.number, .integer), (.number, .number), (.boolean, .bool), (.value, _):
            break
        case (.array(let items, let maxItems), .array(let elements)):
            guard elements.count <= maxItems else { throw reject("exceeds \(maxItems) items") }
            for (index, element) in elements.enumerated() { try items.validate(element, at: "\(path).\(index)") }
        case (.object(let object), .object(let fields)):
            try object.validate(fields, prefix: path + ".")
        default:
            throw reject("has the wrong type")
        }
    }
}

public struct ObjectSchema: Sendable, Equatable {
    public var properties: [String: Schema]
    public var required: Set<String>

    public init(_ properties: [String: Schema] = [:], required: Set<String> = []) {
        precondition(required.isSubset(of: properties.keys), "Required fields must be declared properties.")
        self.properties = properties
        self.required = required
    }

    public static let empty = ObjectSchema()

    public var json: JSONValue {
        .object([
            "type": "object", "additionalProperties": false,
            "properties": .object(properties.mapValues(\.json)),
            "required": .array(required.sorted().map(JSONValue.string))
        ])
    }

    /// Rejects unknown, missing and mistyped fields. An explicit null counts as absent for optional fields.
    public func validate(_ object: [String: JSONValue], prefix: String = "") throws {
        if let unknown = object.keys.filter({ properties[$0] == nil }).sorted().first {
            throw Failure(.invalidParams, "Unexpected parameter field.", details: ["field": .string(prefix + unknown)])
        }
        for name in properties.keys.sorted() {
            let value = object[name] ?? .null
            if value == .null {
                guard !required.contains(name) else {
                    throw Failure(.invalidParams, "Missing required field.", details: ["field": .string(prefix + name)])
                }
                continue
            }
            try properties[name]!.validate(value, at: prefix + name)
        }
    }
}
