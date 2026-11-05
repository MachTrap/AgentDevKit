import AgentDevKitCore
import Foundation

/// A checked-in regression scenario: setup, steps, bursts, waits and assertions, run with `agentdevctl recipe run`.
///
/// ```json
/// {"fixture": "sample-home", "repeat": 10,
///  "steps": [
///    {"burst": [{"action": "queue.toggle", "args": {"paths": ["~/Downloads"]}},
///               {"action": "queue.toggle", "args": {"paths": ["~/Desktop"]}}]},
///    {"wait": "work.quiescent"},
///    {"assert": {"field": "queueCount", "equals": 1}}]}
/// ```
public struct Recipe: Codable, Sendable {
    public var name: String?
    /// Loaded before each round, with `route` through `scenario.prepare`.
    public var fixture: String?
    public var fixtureArguments: [String: JSONValue]?
    public var route: String?
    public var context: [String: JSONValue]?
    /// Rounds to run. Each round repeats setup and steps.
    public var `repeat`: Int?
    /// Per-round variables, substituted for `{{name}}` in step strings. Round N uses entry (N-1) modulo the count.
    public var rounds: [[String: JSONValue]]?
    /// `hold`: fail when any invariant is violated during a round.
    public var invariants: String?
    /// Wait for `work.quiescent` after each step that changes the app, outside bursts. Default true.
    public var settle: Bool?
    /// Snapshot scope for field assertions. Default `current-screen`.
    public var scope: String?
    public var steps: [JSONValue]

    public init(name: String? = nil, fixture: String? = nil, route: String? = nil, steps: [JSONValue]) {
        self.name = name
        self.fixture = fixture
        self.route = route
        self.steps = steps
    }

    public static let stepKinds = ["action", "perform", "press", "key", "hover", "scroll", "wait", "assert", "burst", "ask",
                                   "capture", "navigate", "fixture", "sleep", "note"]
    static let mutatingKinds: Set<String> = ["action", "perform", "press", "key", "hover", "scroll", "navigate", "fixture"]

    /// Checks every step's shape before anything runs. Returns the first problem with its step number.
    public func validate() throws {
        guard (1...1_000).contains(self.repeat ?? 1) else {
            throw Failure(.invalidParams, "repeat must be 1…1000.", details: ["field": "repeat"])
        }
        guard !steps.isEmpty else { throw Failure(.invalidParams, "A recipe needs steps.", details: ["field": "steps"]) }
        func check(_ steps: [JSONValue], prefix: String, depth: Int) throws {
            for (index, step) in steps.enumerated() {
                let label = prefix + String(index + 1)
                guard let object = step.objectValue, let kind = Self.kind(of: object) else {
                    throw Failure(.invalidParams, "Step \(label) needs one of: \(Self.stepKinds.joined(separator: ", ")).",
                                  details: ["field": .string("steps.\(label)")])
                }
                if kind == "burst" {
                    guard depth == 0, let inner = object["burst"]?.arrayValue, !inner.isEmpty else {
                        throw Failure(.invalidParams, "Step \(label): burst takes a nonempty list of steps and cannot nest.",
                                      details: ["field": .string("steps.\(label)")])
                    }
                    try check(inner, prefix: label + ".", depth: depth + 1)
                    for (offset, item) in inner.enumerated() {
                        guard let kind = item.objectValue.flatMap(Self.kind), Self.mutatingKinds.contains(kind) || kind == "sleep" else {
                            throw Failure(.invalidParams, "Step \(label).\(offset + 1): a burst holds only steps that change the app.",
                                          details: ["field": .string("steps.\(label).\(offset + 1)")])
                        }
                    }
                }
                if kind == "ask", let branches = object["then"]?.objectValue {
                    for (answer, steps) in branches {
                        guard let steps = steps.arrayValue else {
                            throw Failure(.invalidParams, "Step \(label): then.\(answer) must be a list of steps.", details: ["field": .string("steps.\(label)")])
                        }
                        try check(steps, prefix: label + ".\(answer).", depth: depth)
                    }
                }
            }
        }
        try check(steps, prefix: "", depth: 0)
    }

    static func kind(of step: [String: JSONValue]) -> String? {
        let kinds = stepKinds.filter { step[$0] != nil }
        return kinds.count == 1 ? kinds[0] : nil
    }
}

public struct RecipeReport: Codable, Sendable {
    public struct Failure: Codable, Sendable {
        public let round: Int
        /// The step number, such as `3` or `2.1` inside a burst.
        public let step: String
        public let kind: String
        public let message: String
        public let expected: JSONValue?
        public let observed: JSONValue?
        public let revision: UInt64?
        /// A folder with the capture, tree and state at the failure.
        public let snapshot: String?
    }

    public struct Burst: Codable, Sendable {
        public let round: Int
        public let step: String
        public let steps: Int
        /// Milliseconds between one request's reply and the next request, for each pair. Near zero: back to back.
        public let gapsMs: [Double]
        public let revisionBefore: UInt64?
        public let revisionAfter: UInt64?
    }

    public let name: String
    public let passed: Bool
    public let rounds: Int
    public let stepsRun: Int
    public let durationMs: Int
    public let failure: Failure?
    public let bursts: [Burst]
    public let answers: [String]
    public let notes: [String]
}

/// Runs recipes against a live session.
public struct RecipeRunner: Sendable {
    public let client: AgentClient
    /// Where failure snapshots are written.
    public let output: URL
    let log: @Sendable (String) -> Void

    public init(client: AgentClient, output: URL, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.client = client
        self.output = output
        self.log = log
    }

    private struct StepFailure: Error {
        let kind: String
        let message: String
        var expected: JSONValue? = nil
        var observed: JSONValue? = nil
        var revision: UInt64? = nil
    }

    private final class State: @unchecked Sendable {
        var stepsRun = 0
        var bursts: [RecipeReport.Burst] = []
        var answers: [String] = []
        var notes: [String] = []
        var revision: UInt64?
    }

    private func operation(_ tool: String) -> AgentOperation {
        AgentOperation.all.first { $0.tool == tool }!
    }

    @discardableResult
    private func call(_ tool: String, _ values: [String: JSONValue], timeoutMs: Int? = nil) async throws -> JSONValue {
        let response = try await operation(tool).run(client, values, timeoutMs: timeoutMs)
        return response.objectValue?["result"] ?? .null
    }

    public func run(_ recipe: Recipe, repeat override: Int? = nil) async -> RecipeReport {
        let clock = ContinuousClock()
        let started = clock.now
        let state = State()
        let name = recipe.name ?? "recipe"
        let rounds = override ?? recipe.repeat ?? 1
        var completed = 0
        var failure: RecipeReport.Failure?
        do { try recipe.validate() } catch let error as AgentDevKitCore.Failure {
            failure = .init(round: 0, step: error.details?["field"]?.stringValue ?? "-", kind: "invalid", message: error.message,
                            expected: nil, observed: nil, revision: nil, snapshot: nil)
        } catch {}
        roundLoop: for round in 1...max(1, rounds) where failure == nil {
            let variables = recipe.rounds.flatMap { $0.isEmpty ? nil : $0[(round - 1) % $0.count] } ?? [:]
            var context = variables
            context["round"] = .integer(Int64(round))
            do {
                try await setup(recipe, context: context)
                let start = try await revision(recipe.scope)
                try await steps(recipe.steps, prefix: "", round: round, recipe: recipe, context: context, state: state, inBurst: false)
                if recipe.invariants == "hold" { try await invariantsHeld(since: start) }
                completed = round
                log("round \(round)/\(rounds) passed")
            } catch let error as StepFailureAt {
                failure = await report(error, round: round, name: name)
                break roundLoop
            } catch let error as AgentDevKitCore.Failure {
                failure = await report(StepFailureAt(step: "setup", failure: StepFailure(kind: "setup", message: "\(error.code.rawValue): \(error.message)")),
                                       round: round, name: name)
                break roundLoop
            } catch {
                failure = .init(round: round, step: "-", kind: "error", message: "\(error)", expected: nil, observed: nil, revision: nil, snapshot: nil)
                break roundLoop
            }
        }
        let elapsed = started.duration(to: clock.now).components
        return RecipeReport(name: name, passed: failure == nil, rounds: completed, stepsRun: state.stepsRun,
                            durationMs: Int(elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000),
                            failure: failure, bursts: state.bursts, answers: state.answers, notes: state.notes)
    }

    private struct StepFailureAt: Error {
        let step: String
        let failure: StepFailure
    }

    private func setup(_ recipe: Recipe, context: [String: JSONValue]) async throws {
        if let fixture = recipe.fixture, let route = recipe.route {
            var values: [String: JSONValue] = ["fixture": .string(fixture), "route": .string(route), "wait": true]
            if let arguments = recipe.fixtureArguments { values["fixtureArguments"] = substitute(.object(arguments), context) }
            if let routeContext = recipe.context { values["context"] = substitute(.object(routeContext), context) }
            try await call("prepare", values)
        } else if let fixture = recipe.fixture {
            var values: [String: JSONValue] = ["fixture": .string(fixture), "wait": true]
            if let arguments = recipe.fixtureArguments { values["arguments"] = substitute(.object(arguments), context) }
            try await call("fixtures", values)
        } else if let route = recipe.route {
            var values: [String: JSONValue] = ["route": .string(route)]
            if let routeContext = recipe.context { values["context"] = substitute(.object(routeContext), context) }
            try await call("navigate", values)
        }
    }

    private func revision(_ scope: String?) async throws -> UInt64 {
        let state = try await call("state", ["scope": .string(scope ?? "current-screen")])
        return UInt64(state.objectValue?["revision"]?.integerValue ?? 0)
    }

    private func invariantsHeld(since revision: UInt64) async throws {
        let report = try await call("invariants", [:])
        let violations = (report.objectValue?["violations"]?.arrayValue ?? []).filter {
            UInt64($0.objectValue?["revision"]?.integerValue ?? 0) > revision
        }
        if let first = violations.first?.objectValue {
            throw StepFailureAt(step: "invariants", failure: StepFailure(
                kind: "invariant", message: "Invariant \(first["id"]?.stringValue ?? "?") was violated during the round.",
                expected: "holds", observed: first["details"], revision: first["revision"]?.integerValue.map(UInt64.init)))
        }
    }

    private func steps(_ steps: [JSONValue], prefix: String, round: Int, recipe: Recipe, context: [String: JSONValue],
                       state: State, inBurst: Bool) async throws {
        for (index, raw) in steps.enumerated() {
            let label = prefix + String(index + 1)
            guard case .object(let step)? = Optional(substitute(raw, context)), let kind = Recipe.kind(of: step) else { continue }
            do {
                try await run(kind, step, label: label, round: round, recipe: recipe, context: context, state: state, inBurst: inBurst)
                state.stepsRun += 1
            } catch let failure as StepFailure {
                throw StepFailureAt(step: label, failure: failure)
            } catch let failure as AgentDevKitCore.Failure {
                var message = "\(failure.code.rawValue): \(failure.message)"
                if let example = failure.details?["example"]?.stringValue { message += " Try: \(example)" }
                throw StepFailureAt(step: label, failure: StepFailure(kind: kind, message: message, observed: failure.details.map(JSONValue.object)))
            }
        }
    }

    private func locator(_ value: JSONValue?) -> [String: JSONValue] {
        if let identifier = value?.stringValue { return ["identifier": .string(identifier)] }
        var result: [String: JSONValue] = [:]
        for (key, field) in [("id", "identifier"), ("identifier", "identifier"), ("path", "path"), ("role", "role"),
                             ("label", "label"), ("index", "index"), ("window", "windowId"), ("windowId", "windowId")] {
            if let item = value?.objectValue?[key] { result[field] = item }
        }
        return result
    }

    private func run(_ kind: String, _ step: [String: JSONValue], label: String, round: Int, recipe: Recipe,
                     context: [String: JSONValue], state: State, inBurst: Bool) async throws {
        switch kind {
        case "action":
            guard let id = step["action"]?.stringValue else { throw StepFailure(kind: kind, message: "action must be an action ID.") }
            var values: [String: JSONValue] = ["actionId": .string(id), "arguments": step["args"] ?? step["arguments"] ?? [:]]
            if !inBurst { values["wait"] = true }
            try await call("invoke", values)
        case "perform":
            guard let operation = step["perform"]?.stringValue else { throw StepFailure(kind: kind, message: "perform names an operation, such as set.") }
            var values = locator(.object(step))
            values["operation"] = .string(operation)
            if let value = step["value"] { values["value"] = value }
            if let item = step["item"] { values["item"] = item }
            try await call("ui_perform", values)
        case "press":
            try await call("press", locator(step["press"]))
        case "key":
            var values: [String: JSONValue] = ["keys": step["key"] ?? ""]
            if let modifiers = step["modifiers"] { values["modifiers"] = modifiers }
            if let window = step["window"] { values["windowId"] = window }
            try await call("ui_key", values)
        case "hover":
            var values = locator(step["hover"])
            for key in ["x", "y"] { if let value = step["hover"]?.objectValue?[key] { values[key] = value } }
            try await call("ui_hover", values)
        case "scroll":
            var values = locator(step["scroll"])
            values["dy"] = step["dy"] ?? step["scroll"]?.objectValue?["dy"] ?? 0
            if let dx = step["dx"] { values["dx"] = dx }
            try await call("ui_scroll", values)
        case "navigate":
            var values: [String: JSONValue] = ["route": step["navigate"] ?? ""]
            if let routeContext = step["context"] { values["context"] = routeContext }
            try await call("navigate", values)
        case "fixture":
            var values: [String: JSONValue] = ["fixture": step["fixture"] ?? "", "wait": .bool(!inBurst)]
            if let arguments = step["arguments"] ?? step["args"] { values["arguments"] = arguments }
            try await call("fixtures", values)
        case "sleep":
            let ms = min(10_000, max(0, Int(step["sleep"]?.integerValue ?? 0)))
            try await Task.sleep(for: .milliseconds(ms))
        case "note":
            state.notes.append(step["note"]?.stringValue ?? "")
        case "wait":
            var values: [String: JSONValue] = ["until": step["wait"] ?? ""]
            if let scope = step["scope"] ?? recipe.scope.map(JSONValue.string) { values["scope"] = scope }
            let timeout = Int(step["timeoutMs"]?.integerValue ?? 10_000)
            do { try await call("wait", values, timeoutMs: min(AgentOperation.maxWaitMs, max(100, timeout))) }
            catch let failure as AgentDevKitCore.Failure where failure.code == .timeout {
                throw StepFailure(kind: kind, message: "\(step["wait"]?.stringValue ?? "condition") did not hold within \(timeout) ms.",
                                  expected: step["wait"], observed: failure.details?["blockers"])
            }
        case "assert":
            try await assertion(step["assert"] ?? .null, recipe: recipe)
        case "burst":
            let inner = step["burst"]?.arrayValue ?? []
            let before = try? await revision(recipe.scope)
            var gaps: [Double] = []
            var lastReply: ContinuousClock.Instant?
            let clock = ContinuousClock()
            for (offset, item) in inner.enumerated() {
                guard case .object(let object) = item, let innerKind = Recipe.kind(of: object) else { continue }
                if let lastReply {
                    let gap = lastReply.duration(to: clock.now).components
                    gaps.append((Double(gap.seconds) * 1_000 + Double(gap.attoseconds) / 1e15 * 1_000 / 1_000).rounded(toPlaces: 2))
                }
                do {
                    try await run(innerKind, object, label: "\(label).\(offset + 1)", round: round, recipe: recipe, context: context,
                                  state: state, inBurst: true)
                } catch let failure as AgentDevKitCore.Failure {
                    throw StepFailureAt(step: "\(label).\(offset + 1)", failure: StepFailure(kind: innerKind, message: "\(failure.code.rawValue): \(failure.message)"))
                }
                lastReply = clock.now
                state.stepsRun += 1
            }
            let after = try? await revision(recipe.scope)
            state.bursts.append(.init(round: round, step: label, steps: inner.count, gapsMs: gaps, revisionBefore: before, revisionAfter: after))
        case "ask":
            var values: [String: JSONValue] = ["wait": true]
            let ask = step["ask"]
            values["question"] = ask?.stringValue.map(JSONValue.string) ?? ask?.objectValue?["question"] ?? ""
            for key in ["options", "allowNotes", "answerTimeoutMs"] { if let value = ask?.objectValue?[key] { values[key] = value } }
            let answer = try await call("operator_ask", values)
            let status = answer.objectValue?["status"]?.stringValue ?? "unanswered"
            let chosen = answer.objectValue?["answer"]?.stringValue
            state.answers.append("\(label): \(chosen ?? status)")
            let branch = chosen.flatMap { step["then"]?.objectValue?[$0]?.arrayValue } ?? (chosen == nil ? step["unanswered"]?.arrayValue : nil)
            if let branch {
                try await steps(branch, prefix: "\(label).\(chosen ?? "unanswered").", round: round, recipe: recipe, context: context,
                                state: state, inBurst: false)
            } else if chosen == nil, step["unanswered"] == nil {
                throw StepFailure(kind: kind, message: "The question was not answered.", expected: "an answer", observed: .string(status))
            }
        case "capture":
            let options = step["capture"]?.objectValue ?? [:]
            var values: [String: JSONValue] = [:]
            for key in ["mode", "windowId", "surfaceId", "maxDimension"] { if let value = options[key] { values[key] = value } }
            values["format"] = "png"
            let capture = try await call("capture", values)
            guard let data = capture.objectValue?["data"]?.stringValue.flatMap({ Data(base64Encoded: $0) }) else {
                throw StepFailure(kind: kind, message: "The capture returned no image.")
            }
            guard let template = options["baseline"]?.stringValue else { break }
            let path = VisualDiff.baselinePath(template, locale: capture.objectValue?["locale"]?.stringValue,
                                               appearance: capture.objectValue?["appearance"]?.stringValue)
            let url = URL(filePath: path)
            guard let baseline = try? Data(contentsOf: url) else {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                state.notes.append("\(label): baseline created at \(url.path)")
                break
            }
            let (result, diff) = try VisualDiff.compare(data, baseline: baseline, threshold: options["threshold"]?.doubleValue ?? 0.01)
            guard result.matched else {
                let diffURL = url.deletingPathExtension().appendingPathExtension("diff.png")
                try? diff?.write(to: diffURL, options: .atomic)
                throw StepFailure(kind: kind, message: "The capture differs from \(url.path); diff at \(diffURL.path).",
                                  expected: .number(result.threshold), observed: .number(result.fraction))
            }
        default:
            throw StepFailure(kind: kind, message: "Unknown step.")
        }
        if !inBurst, Recipe.mutatingKinds.contains(kind), recipe.settle != false {
            _ = try? await call("wait", ["condition": "work.quiescent", "failOnTimeout": false], timeoutMs: 5_000)
        }
    }

    private func assertion(_ spec: JSONValue, recipe: Recipe) async throws {
        guard let spec = spec.objectValue else { throw StepFailure(kind: "assert", message: "assert takes an object.") }
        if spec["invariants"] != nil {
            let report = try await call("invariants", [:])
            let failing = (report.objectValue?["invariants"]?.arrayValue ?? []).filter { $0.objectValue?["holds"]?.boolValue == false }
            guard failing.isEmpty else {
                throw StepFailure(kind: "assert", message: "Invariants do not hold.", expected: "hold",
                                  observed: .array(failing.compactMap { $0.objectValue?["id"] }),
                                  revision: report.objectValue?["revision"]?.integerValue.map(UInt64.init))
            }
            return
        }
        if let element = spec["element"] {
            let wanted = locator(element)
            let tree = try await call("ui_tree", ["windowId": wanted["windowId"] ?? .null].filter { $0.value != .null }.merging(["limit": 3_000]) { a, _ in a })
            let elements = tree.objectValue?["elements"]?.arrayValue ?? []
            let match = elements.first { item in
                let object = item.objectValue ?? [:]
                if let identifier = wanted["identifier"], object["identifier"] != identifier { return false }
                if let path = wanted["path"]?.stringValue, object["path"]?.stringValue != path { return false }
                if let label = wanted["label"], object["label"] != label { return false }
                return true
            }
            let exists = spec["exists"]?.boolValue ?? true
            guard (match != nil) == exists else {
                throw StepFailure(kind: "assert", message: exists ? "No element matches." : "The element exists.", expected: .bool(exists),
                                  observed: .bool(match != nil), revision: tree.objectValue?["revision"]?.integerValue.map(UInt64.init))
            }
            if let match = match?.objectValue {
                for key in ["value", "enabled", "selected", "numericValue", "valueDescription"] {
                    if let expected = spec[key], !Self.equal(match[key] ?? .null, expected) {
                        throw StepFailure(kind: "assert", message: "Element \(key) differs.", expected: expected, observed: match[key] ?? .null,
                                          revision: tree.objectValue?["revision"]?.integerValue.map(UInt64.init))
                    }
                }
            }
            return
        }
        guard let field = spec["field"]?.stringValue else {
            throw StepFailure(kind: "assert", message: "assert needs field, element or invariants.")
        }
        let scope = spec["scope"]?.stringValue ?? recipe.scope ?? "current-screen"
        let response = try await operation("state").run(client, ["scope": .string(scope)])
        let observed = operation("state").field(field, in: response)
        let revision = response.objectValue?["result"]?.objectValue?["revision"]?.integerValue.map(UInt64.init)
        func fail(_ message: String, _ expected: JSONValue) -> StepFailure {
            StepFailure(kind: "assert", message: "\(field) \(message)", expected: expected, observed: observed ?? .null, revision: revision)
        }
        if let exists = spec["exists"]?.boolValue, (observed != nil) != exists { throw fail(exists ? "is absent." : "is present.", .bool(exists)) }
        if let expected = spec["equals"], !Self.equal(observed ?? .null, expected) { throw fail("differs.", expected) }
        if let expected = spec["notEquals"], Self.equal(observed ?? .null, expected) { throw fail("should differ.", expected) }
        if let expected = spec["contains"], !Self.contains(observed, expected) { throw fail("does not contain the value.", expected) }
        if let expected = spec["notContains"], Self.contains(observed, expected) { throw fail("contains the value.", expected) }
        for (key, test) in [("greaterThan", { (a: Double, b: Double) in a > b }), ("lessThan", { $0 < $1 }),
                            ("atLeast", { $0 >= $1 }), ("atMost", { $0 <= $1 })] {
            guard let expected = spec[key] else { continue }
            guard let a = observed?.doubleValue ?? observed?.arrayValue.map({ Double($0.count) }), let b = expected.doubleValue, test(a, b) else {
                throw fail("is not \(key) the value.", expected)
            }
        }
    }

    /// Numbers compare by value, so 1 equals 1.0.
    static func equal(_ a: JSONValue, _ b: JSONValue) -> Bool {
        if let x = a.doubleValue, let y = b.doubleValue { return x == y }
        return a == b
    }

    static func contains(_ container: JSONValue?, _ value: JSONValue) -> Bool {
        switch container {
        case .array(let items)?: items.contains { equal($0, value) }
        case .string(let text)?: value.stringValue.map(text.contains) ?? false
        case .object(let object)?: value.stringValue.map { object[$0] != nil } ?? false
        default: false
        }
    }

    /// Replaces `{{name}}` in strings. A string that is exactly `{{name}}` becomes the variable's JSON value.
    func substitute(_ value: JSONValue, _ variables: [String: JSONValue]) -> JSONValue {
        switch value {
        case .string(let text):
            guard text.contains("{{") else { return value }
            for (name, replacement) in variables where text == "{{\(name)}}" { return replacement }
            var result = text
            for (name, replacement) in variables {
                result = result.replacingOccurrences(of: "{{\(name)}}", with: AgentOperation.raw(replacement))
            }
            return .string(result)
        case .array(let items): return .array(items.map { substitute($0, variables) })
        case .object(let object): return .object(object.mapValues { substitute($0, variables) })
        default: return value
        }
    }

    private func report(_ error: StepFailureAt, round: Int, name: String) async -> RecipeReport.Failure {
        var revision = error.failure.revision
        if revision == nil { revision = try? await self.revision(nil) }
        let folder = await snapshot(name: name, round: round, step: error.step)
        return .init(round: round, step: error.step, kind: error.failure.kind, message: error.failure.message,
                     expected: error.failure.expected, observed: error.failure.observed, revision: revision, snapshot: folder)
    }

    /// Writes `capture.png`, `tree.json` and `state.json` for the failure. Returns the folder, or nil when nothing could be captured.
    private func snapshot(name: String, round: Int, step: String) async -> String? {
        let stamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "")
        let safe = name.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
        let folder = output.appendingPathComponent("\(String(safe))-\(stamp)-r\(round)-s\(step)", isDirectory: true)
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) } catch { return nil }
        var wrote = false
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let snapshot = try? await call("ui_snapshot", ["limit": 1_500]), case .object(var object) = snapshot {
            if case .object(var capture)? = object["capture"], let data = capture["data"]?.stringValue.flatMap({ Data(base64Encoded: $0) }) {
                let file = folder.appendingPathComponent(capture["format"]?.stringValue == "jpeg" ? "capture.jpg" : "capture.png")
                try? data.write(to: file)
                capture["data"] = nil
                object["capture"] = .object(capture)
            }
            try? encoder.encode(JSONValue.object(object)).write(to: folder.appendingPathComponent("tree.json"))
            wrote = true
        }
        if let state = try? await call("state", ["scope": "current-screen"]) {
            try? encoder.encode(state).write(to: folder.appendingPathComponent("state.json"))
            wrote = true
        }
        if !wrote { try? FileManager.default.removeItem(at: folder) }
        return wrote ? folder.path : nil
    }
}

extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10, Double(places))
        return (self * factor).rounded() / factor
    }
}
