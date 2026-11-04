import AgentDevKitCore
import AgentDevKitHost
import Foundation

@MainActor
struct LabCommands {
    let model: LabModel
    let runtime: LabRuntime
    let allowMutations: Bool
    static let scopes = ["app", "current-screen", "window:main"]

    var definitions: [AppCommand] {
        [
            AppCommand(AppCommands.snapshot, parameterKeys: ["scope"]) { input, _ in
                try snapshot(input.scope)
            },
            AppCommand(AppCommands.open, mutating: true, parameterKeys: ["route", "context", "waitForReady"],
                       accepted: { !$0.ready }) { input, command in
                let destination = try resolve(input.route, context: input.context, in: model.workspace)
                return try await open(destination, wait: input.waitForReady ?? true, command: command)
            },
            AppCommand(AppCommands.load, mutating: true, parameterKeys: ["fixture"]) { input, command in
                let fixture = try findFixture(input.fixture)
                try command.checkDeadline()
                return try apply(fixture, requestId: command.requestId)
            },
            AppCommand(AppCommands.observe, parameterKeys: ["scope", "sinceRevision", "limit"]) { input, _ in
                try StateObservation(screen: snapshot(input.scope), journal: runtime.journal, request: input)
            },
            AppCommand(AppCommands.wait, parameterKeys: ["condition", "scope", "operationId", "field", "value"]) { input, command in
                try await wait(input, command: command)
            },
            AppCommand(AppCommands.events, parameterKeys: ["revision", "limit"]) { input, _ in
                try runtime.journal.since(input.revision, limit: input.limit ?? RevisionJournal.maxPageSize)
            },
            AppCommand(AppCommands.diagnostics, parameterKeys: ["severity", "category", "limit"]) { input, _ in
                try runtime.recent(input)
            },
            AppCommand(AppCommands.actions, parameterKeys: []) { _, _ in
                allowMutations ? actions : []
            },
            AppCommand(AppCommands.invoke, mutating: true, parameterKeys: ["actionId", "arguments", "expectedRevision"]) { input, command in
                try invoke(input, command: command)
            },
            AppCommand(AppCommands.prepare, mutating: true,
                       parameterKeys: ["fixture", "route", "context", "waitForReady"],
                       accepted: { !$0.screen.ready }) { input, command in
                try await prepare(input, command: command)
            }
        ]
    }

    static var routes: [Capabilities.RouteCapability] {
        LabRoute.allCases.map { route in
            let keys = switch route {
            case .inspector: ["projectId", "nodeId"]
            case .editor: ["projectId"]
            default: [String]()
            }
            var gates = ["screen.appearance"]
            if route.requiresProject { gates.append("document.load") }
            return .init(id: route.rawValue, contextKeys: keys, windowId: LabRoute.windowID,
                         accessibilityId: route.accessibilityID, readinessGates: gates)
        }
    }

    static func lifecycleCapabilities(allowMutations: Bool) -> [LifecycleCapability] {
        var entries = LabRoute.allCases.map { LifecycleCapability(kind: .screen, name: $0.rawValue) }
        entries.append(.init(kind: .work, name: "document.load"))
        entries.append(.init(kind: .work, name: "workspace.save"))
        entries.append(.init(kind: .screen, name: "projects.form"))
        if allowMutations { entries.append(.init(kind: .scenario, name: "scenario.prepare")) }
        return entries
    }

    private func prepare(_ input: PrepareScenario, command: CommandContext) async throws -> ScenarioState {
        let span = runtime.beginScenario(command.requestId)
        let result: ScenarioState
        do {
            result = try await runScenario(input, command: command, scenarioId: span?.id)
        } catch {
            let cancelled = Task.isCancelled || (error as? Failure)?.code == .cancelled
            runtime.endScenario(span, outcome: cancelled ? .cancelled : .failed)
            throw error
        }
        runtime.endScenario(span, outcome: result.screen.ready ? .completed : .accepted)
        return ScenarioState(fixture: result.fixture, screen: try snapshot("current-screen"))
    }

    private func runScenario(
        _ input: PrepareScenario, command: CommandContext, scenarioId: UUID?
    ) async throws -> ScenarioState {
        let fixture: Fixture
        let destination: Destination
        do { fixture = try findFixture(input.fixture) }
        catch { throw phaseError(error, phase: "fixture") }
        do { destination = try resolve(input.route, context: input.context, in: fixture.workspace) }
        catch { throw phaseError(error, phase: "navigation") }
        let loaded: FixtureState
        do {
            try command.checkDeadline()
            loaded = try apply(fixture, requestId: command.requestId)
        } catch {
            throw phaseError(error, phase: "fixture")
        }
        do {
            let screen = try await open(destination, wait: input.waitForReady ?? true, command: command, scenarioId: scenarioId)
            return ScenarioState(fixture: loaded, screen: screen)
        } catch {
            throw phaseError(error, phase: "navigation")
        }
    }

    private func phaseError(_ error: any Error, phase: String) -> Failure {
        let failure = error as? Failure ?? Failure(.internalError, "Scenario preparation failed.")
        return Failure(failure.code, failure.message, retryable: failure.retryable,
                       details: (failure.details ?? [:]).merging(["phase": phase]) { old, _ in old })
    }

    private func snapshot(_ scope: String) throws -> ScreenState {
        guard Self.scopes.contains(scope) else { throw Failure(.invalidParams, "Snapshot scope is not registered.") }
        let destination = model.destination
        var fields: [String: JSONValue] = [:]
        if scope == "app" || destination.route == .projects {
            fields["projectCount"] = .integer(Int64(model.workspace.projects.count))
        }
        if scope != "app" {
            if model.projectFormVisible { fields["modal"] = .string("projects.form") }
            if let project = model.project {
                fields["projectId"] = .string(project.id)
                fields["projectName"] = .string(project.name)
                fields["nodeCount"] = .integer(Int64(project.nodes.count))
            }
            if let node = model.node {
                fields["nodeId"] = .string(node.id)
                fields["nodeName"] = .string(String(node.name.prefix(512)))
                fields["enabled"] = .bool(node.enabled)
            }
            if destination.route == .appearance {
                fields["theme"] = .string(model.workspace.theme.rawValue)
                fields["accent"] = .string(model.workspace.appearance.accent.rawValue)
                fields["previewTheme"] = .string(model.previewAppearance.theme.rawValue)
                fields["previewAccent"] = .string(model.previewAppearance.accent.rawValue)
                fields["appearanceDirty"] = .bool(model.appearanceDirty)
            }
        }
        if scope != "app", destination.route.requiresProject {
            fields["documentPhase"] = .string(model.documentPhase.rawValue)
        }
        return ScreenState(
            screenId: destination.route.rawValue, windowId: LabRoute.windowID, ready: model.ready,
            revision: runtime.journal.revision, scope: scope, fields: fields,
            operationId: destination.route.requiresProject ? model.presentationID : nil, blockers: blockers
        )
    }

    private func resolve(_ id: String, context: RouteContext?, in workspace: Workspace) throws -> Destination {
        guard let route = LabRoute(rawValue: id) else { throw Failure(.routeNotFound, "Route is not registered.") }
        guard route.requiresProject else {
            guard context?.projectId == nil, context?.nodeId == nil else {
                throw Failure(.invalidParams, "This route has no project context.")
            }
            return Destination(route: route)
        }
        let projectId = context?.projectId ?? (workspace.projects.count == 1 ? workspace.projects.first?.id : nil)
        guard let project = workspace.projects.first(where: { $0.id == projectId }) else {
            throw Failure(.invalidParams, "Select an existing projectId.")
        }
        guard route == .inspector else {
            guard context?.nodeId == nil else { throw Failure(.invalidParams, "The editor accepts only projectId.") }
            return Destination(route: route, projectId: project.id)
        }
        let nodeId = context?.nodeId ?? project.nodes.first?.id
        guard project.nodes.contains(where: { $0.id == nodeId }) else {
            throw Failure(.invalidParams, "Select an existing nodeId.")
        }
        return Destination(route: route, projectId: project.id, nodeId: nodeId)
    }

    private var blockers: [String] {
        if model.documentPhase == .loading { return ["document.load"] }
        if model.documentPhase == .failed { return ["document.failed"] }
        if !model.ready { return ["screen.appearance"] }
        return []
    }

    private func readinessFailure() -> Failure {
        Failure(.timeout, "Condition did not settle before the deadline.", details: ["blockers": blockers.joined(separator: ",")])
    }

    private func open(
        _ destination: Destination, wait: Bool, command: CommandContext, scenarioId: UUID? = nil
    ) async throws -> ScreenState {
        try command.checkDeadline()
        model.present(destination, correlationId: command.requestId, scenarioId: scenarioId)
        let presentation = model.presentationID
        guard wait else { return try snapshot("current-screen") }
        return try await runtime.wait(command: command, timeout: readinessFailure) {
            guard model.presentationID == presentation else {
                throw Failure(.conflict, "Navigation was superseded.")
            }
            if model.documentPhase == .failed {
                throw Failure(.notReady, "Document loading failed.", details: ["blockers": "document.failed"])
            }
            return model.ready ? try snapshot("current-screen") : nil
        }
    }

    private func wait(_ input: WaitRequest, command: CommandContext) async throws -> WaitState {
        _ = try snapshot(input.scope)
        let hasField = input.field != nil || input.value != nil
        switch input.condition {
        case "screen.ready", "work.quiescent":
            guard !hasField, input.operationId == nil else { throw invalidWait }
        case "state.field_equals":
            guard let field = input.field, !field.isEmpty, input.value != nil, input.operationId == nil else {
                throw invalidWait
            }
        case "operation.completed", "lifecycle.ended":
            guard !hasField, input.operationId != nil else { throw invalidWait }
        default:
            throw invalidWait
        }
        let presentation = model.presentationID
        return try await runtime.wait(command: command, timeout: {
            if input.condition == "lifecycle.ended" {
                return Failure(.timeout, "No retained terminal event for the span.",
                               details: ["blockers": "lifecycle.ended"])
            }
            return readinessFailure()
        }) {
            let screen = try snapshot(input.scope)
            let satisfied: Bool
            switch input.condition {
            case "screen.ready":
                guard presentation == model.presentationID else { throw Failure(.conflict, "Screen changed while waiting.") }
                if model.documentPhase == .failed {
                    throw Failure(.notReady, "Document loading failed.", details: ["blockers": "document.failed"])
                }
                satisfied = screen.ready
            case "work.quiescent":
                satisfied = model.documentPhase != .loading
            case "lifecycle.ended":
                guard let id = input.operationId, let terminal = runtime.journal.terminalLifecycle(id) else { return nil }
                return WaitState(screen: screen, lifecycle: terminal)
            case "operation.completed":
                guard input.operationId == screen.operationId else {
                    throw Failure(.conflict, "Operation is no longer current.")
                }
                satisfied = model.documentPhase != .loading
            default:
                satisfied = screen.fields[input.field ?? ""] == input.value
            }
            return satisfied ? WaitState(screen: screen) : nil
        }
    }

    private var invalidWait: Failure { Failure(.invalidParams, "Unknown predicate or invalid predicate arguments.") }

    var actions: [ActionCapability] {
        [
            .init(id: "inspector.save", scope: LabRoute.inspector.rawValue,
                  enabled: model.ready && model.destination.route == .inspector,
                  inputSchema: schema(field: "name", description: ["type": .string("string"), "maxLength": .integer(512)])),
            .init(id: "settings.appearance.save", scope: LabRoute.appearance.rawValue,
                  enabled: model.ready && model.destination.route == .appearance,
                  inputSchema: schema(field: "theme", description: ["type": .string("string"),
                    "enum": .array(Workspace.Theme.allCases.map { .string($0.rawValue) })]))
        ]
    }

    private func schema(field: String, description: [String: JSONValue]) -> [String: JSONValue] {
        ["type": .string("object"), "additionalProperties": .bool(false),
         "properties": .object([field: .object(description)]), "required": .array([.string(field)])]
    }

    private func invoke(_ input: ActionRequest, command: CommandContext) throws -> ScreenState {
        guard let action = actions.first(where: { $0.id == input.actionId }) else {
            throw Failure(.unknownMethod, "Action is not registered.")
        }
        if let expected = input.expectedRevision, expected != runtime.journal.revision {
            throw Failure(.conflict, "Workspace revision changed.")
        }
        guard action.enabled else { throw Failure(.notReady, "Action is unavailable on this screen.") }
        try command.checkDeadline()
        do {
            switch action.id {
            case "inspector.save":
                guard input.arguments.count == 1, case let .string(name) = input.arguments["name"], var node = model.node else {
                    throw Failure(.invalidParams, "Inspector save requires a name.")
                }
                node.name = name
                try model.saveNode(node, correlationId: command.requestId)
            default:
                guard input.arguments.count == 1, case let .string(value) = input.arguments["theme"],
                      let theme = Workspace.Theme(rawValue: value) else {
                    throw Failure(.invalidParams, "Appearance save requires a supported theme.")
                }
                try model.saveTheme(theme, correlationId: command.requestId)
            }
        } catch LabModel.EditError.invalidNode {
            throw Failure(.invalidParams, "Name must be nonempty and at most 512 UTF-8 bytes.")
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure(.internalError, "The isolated workspace could not be saved.")
        }
        return try snapshot("current-screen")
    }

    func apply(_ fixture: Fixture, requestId: UUID? = nil) throws -> FixtureState {
        do { try model.replaceWorkspace(fixture.workspace, correlationId: requestId) }
        catch { throw Failure(.internalError, "Could not write the isolated test workspace.") }
        var failNext = fixture.id == "network-error-v1"
        let delay: Duration = fixture.id == "slow-project-v1" ? .milliseconds(1_200) : .milliseconds(180)
        model.loadDocument = { project in
            try await Task.sleep(for: delay)
            if failNext {
                failNext = false
                throw URLError(.notConnectedToInternet)
            }
            return project
        }
        model.present(Destination(route: .home), correlationId: requestId)
        let project = fixture.workspace.projects.first
        return FixtureState(fixture: fixture.id, projectId: project?.id, nodeId: project?.nodes.first?.id,
                            revision: runtime.journal.revision)
    }

    private func findFixture(_ id: String) throws -> Fixture {
        guard let fixture = Fixture.all.first(where: { $0.id == id }) else {
            throw Failure(.fixtureNotFound, "Fixture is not registered.")
        }
        return fixture
    }
}

struct Fixture {
    let id: String
    let workspace: Workspace

    static let all = [
        Fixture(id: "empty-projects-v1", workspace: Workspace(projects: [])),
        project("basic-project", name: "Sample project", count: 3),
        project("network-error", name: "Recovery project", count: 3),
        project("slow-project", name: "Slow document project", count: 3),
        project("large-project", name: "Large project", count: 200),
        project("long-node-names", name: "Long names project", count: 1,
                firstName: "Quarterly planning and architecture review with extended notes for accessibility and visual inspection")
    ]

    private static func project(_ id: String, name: String, count: Int, firstName: String? = nil) -> Fixture {
        let nodes = (1...count).map { index in
            Workspace.Node(id: "node-\(index)", name: index == 1 ? firstName ?? "Node 1" : "Node \(index)", notes: "")
        }
        return Fixture(id: "\(id)-v1", workspace: Workspace(projects: [
            Workspace.Project(id: "fixture:\(id)", name: name, nodes: nodes)
        ]))
    }
}
