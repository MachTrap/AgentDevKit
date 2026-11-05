import Foundation

/// The opt-in launch arguments of a Testing build. The bridge stays off unless `--enable-agentdevkit` is present
/// on this launch; nothing persists the opt-in.
public struct LaunchOptions: Sendable, Equatable {
    public static let enableFlag = "--enable-agentdevkit"
    public static let mutationsFlag = "--allow-agentdevkit-mutations"
    public static let profileFlag = "--agentdevkit-profile"
    public static let fixtureFlag = "--agentdevkit-fixture"

    public enum ParseError: Error, Sendable, Equatable, CustomStringConvertible {
        case unknownFlag(String)
        case missingValue(String)
        case repeatedFlag(String)
        case invalidProfile

        public var description: String {
            switch self {
            case .unknownFlag(let flag): "Unknown AgentDevKit launch argument \(flag)."
            case .missingValue(let flag): "Missing value for \(flag)."
            case .repeatedFlag(let flag): "Repeated launch argument \(flag)."
            case .invalidProfile: "\(LaunchOptions.profileFlag) requires a UUID."
            }
        }
    }

    /// `--enable-agentdevkit` starts the bridge.
    public var enabled: Bool
    /// `--allow-agentdevkit-mutations` requests fixture, navigation and action access. Grant it only once isolated storage opened.
    public var allowMutations: Bool
    /// `--agentdevkit-profile UUID` reopens an isolated Testing profile.
    public var profile: UUID?
    /// `--agentdevkit-fixture ID` seeds a fresh profile before the first screen appears.
    public var fixture: String?

    public init(enabled: Bool = false, allowMutations: Bool = false, profile: UUID? = nil, fixture: String? = nil) {
        self.enabled = enabled
        self.allowMutations = allowMutations
        self.profile = profile
        self.fixture = fixture
    }

    /// Parses `--agentdevkit` arguments. Other arguments are ignored, except unknown flags containing
    /// `agentdevkit`, which are rejected unless listed in `appFlags` (app-owned Testing switches).
    public static func parse(_ arguments: [String] = CommandLine.arguments, appFlags: Set<String> = []) throws(ParseError) -> LaunchOptions {
        var options = LaunchOptions()
        var seen: Set<String> = []
        var index = arguments.startIndex
        if index < arguments.endIndex { index += 1 } // argv[0]
        while index < arguments.endIndex {
            let argument = arguments[index]
            index += 1
            guard argument.hasPrefix("--"), argument.contains("agentdevkit") else { continue }
            guard !appFlags.contains(argument) else { continue }
            guard seen.insert(argument).inserted else { throw .repeatedFlag(argument) }
            switch argument {
            case enableFlag: options.enabled = true
            case mutationsFlag: options.allowMutations = true
            case profileFlag, fixtureFlag:
                guard index < arguments.endIndex, !arguments[index].hasPrefix("--") else { throw .missingValue(argument) }
                let value = arguments[index]
                index += 1
                if argument == profileFlag {
                    guard let profile = UUID(uuidString: value) else { throw .invalidProfile }
                    options.profile = profile
                } else {
                    options.fixture = value
                }
            default:
                throw .unknownFlag(argument)
            }
        }
        return options
    }
}
