import AgentDevKitCore
import AgentDevKitHost
import Foundation

/// AgentLab's typed bridge boundary. The library serves every protocol method from this adapter and catalog.
@MainActor
final class LabAdapter: AgentAdapter {
    let model: LabModel

    init(model: LabModel) { self.model = model }

    var currentPresentation: UUID? { model.presentationID }

    func snapshot(scope: String) throws -> ScreenSnapshot {
        let destination = model.destination
        var fields: [String: JSONValue] = [:]
        if scope == "app" || destination.route == .projects {
            fields["projectCount"] = .integer(Int64(model.workspace.projects.count))
        }
        if scope != "app" {
            if model.projectFormVisible { fields["modal"] = "projects.form" }
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
            if destination.route.requiresProject { fields["documentPhase"] = .string(model.documentPhase.rawValue) }
        }
        return ScreenSnapshot(
            screenId: destination.route.rawValue, windowId: LabRoute.windowID, ready: model.ready, fields: fields,
            operationId: destination.route.requiresProject ? model.presentationID : nil, blockers: blockers
        )
    }

    private var blockers: [String] {
        if model.documentPhase == .loading { return ["document.load"] }
        if model.documentPhase == .failed { return ["document.failed"] }
        return model.ready ? [] : ["screen.appearance"]
    }

    func resolve(route id: String, context: RouteContext, fixture: String?) throws -> Destination {
        let workspace = try fixture.map { try Fixture.named($0).workspace } ?? model.workspace
        let route = LabRoute(rawValue: id)!
        guard route.requiresProject else { return Destination(route: route) }
        let projectId = context["projectId"]?.stringValue ?? (workspace.projects.count == 1 ? workspace.projects.first?.id : nil)
        guard let project = workspace.projects.first(where: { $0.id == projectId }) else {
            throw Failure(.invalidParams, "Select an existing projectId.", details: ["field": "context.projectId"])
        }
        guard route == .inspector else { return Destination(route: route, projectId: project.id) }
        let nodeId = context["nodeId"]?.stringValue ?? project.nodes.first?.id
        guard project.nodes.contains(where: { $0.id == nodeId }) else {
            throw Failure(.invalidParams, "Select an existing nodeId.", details: ["field": "context.nodeId"])
        }
        return Destination(route: route, projectId: project.id, nodeId: nodeId)
    }

    func present(_ destination: Destination, request: PresentationRequest) -> UUID {
        model.present(destination, correlationId: request.requestId, scenarioId: request.scenarioId)
        return model.presentationID
    }

    func readiness(of presentation: UUID) -> Readiness {
        guard presentation == model.presentationID else { return .superseded }
        if model.documentPhase == .failed {
            return .failed(Failure(.notReady, "Document loading failed.", details: ["blockers": ["document.failed"]]))
        }
        return model.ready ? .ready : .pending(blockers: blockers)
    }

    func loadFixture(_ id: String, context: CommandContext) throws -> [String: JSONValue] {
        let project = try apply(Fixture.named(id), requestId: context.requestId)
        var fields: [String: JSONValue] = [:]
        if let project {
            fields["projectId"] = .string(project.id)
            if let node = project.nodes.first { fields["nodeId"] = .string(node.id) }
        }
        return fields
    }

    /// Replaces the isolated workspace and installs the fixture's simulated document service.
    @discardableResult
    func apply(_ fixture: Fixture, requestId: UUID? = nil) throws -> Workspace.Project? {
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
        return fixture.workspace.projects.first
    }

    // MARK: Catalog

    var catalog: AgentCatalog {
        AgentCatalog(
            scopes: ["app", "current-screen", "window:main"],
            routes: LabRoute.allCases.map { route in
                let context: ObjectSchema = switch route {
                case .inspector: ObjectSchema(["projectId": .string(maxLength: 128), "nodeId": .string(maxLength: 128)])
                case .editor: ObjectSchema(["projectId": .string(maxLength: 128)])
                default: .empty
                }
                return AgentRoute(route.rawValue, context: context, windowId: LabRoute.windowID, accessibilityId: route.accessibilityID,
                                  readinessGates: route.requiresProject ? ["screen.appearance", "document.load"] : ["screen.appearance"])
            },
            fixtures: Fixture.all.map(\.id),
            actions: [
                AgentAction("inspector.save", scope: LabRoute.inspector.rawValue,
                            input: ObjectSchema(["name": .string(maxLength: 512)], required: ["name"]), as: NodeName.self,
                            enabled: { [model] in model.ready && model.destination.route == .inspector }) { [model] input, command in
                    guard var node = model.node else { throw Failure(.notReady, "No node is selected.") }
                    node.name = input.name
                    try Self.saving { try model.saveNode(node, correlationId: command.requestId) }
                    return .completed
                },
                AgentAction("settings.appearance.save", scope: LabRoute.appearance.rawValue,
                            input: ObjectSchema(["theme": .string(maxLength: 16, oneOf: Workspace.Theme.allCases.map(\.rawValue))],
                                                required: ["theme"]), as: ThemeChoice.self,
                            enabled: { [model] in model.ready && model.destination.route == .appearance }) { [model] input, command in
                    try Self.saving { try model.saveTheme(input.theme, correlationId: command.requestId) }
                    return .completed
                }
            ],
            lifecycle: LabRoute.allCases.map { LifecycleCapability(kind: .screen, name: $0.rawValue) } + [
                .init(kind: .work, name: "document.load"), .init(kind: .work, name: "workspace.save"),
                .init(kind: .screen, name: "projects.form")
            ],
            diagnosticCategories: ["storage", "document"],
            ui: .all
        )
    }

    private struct NodeName: Decodable { let name: String }
    private struct ThemeChoice: Decodable { let theme: Workspace.Theme }

    private static func saving(_ save: () throws -> Void) throws {
        do { try save() }
        catch LabModel.EditError.invalidNode {
            throw Failure(.invalidParams, "Name must be nonempty and at most 512 UTF-8 bytes.", details: ["field": "arguments.name"])
        } catch {
            throw Failure(.internalError, "The isolated workspace could not be saved.")
        }
    }
}

struct Fixture {
    let id: String
    let workspace: Workspace

    static func named(_ id: String) throws -> Fixture {
        guard let fixture = all.first(where: { $0.id == id }) else { throw Failure(.fixtureNotFound, "Fixture is not registered.") }
        return fixture
    }

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
