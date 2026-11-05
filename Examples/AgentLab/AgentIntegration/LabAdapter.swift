import AgentDevKitCore
import AgentDevKitFixtures
import AgentDevKitHost
import Foundation

/// AgentLab's typed bridge boundary. The library serves every protocol method from this adapter and catalog.
@MainActor
final class LabAdapter: AgentAdapter {
    let model: LabModel
    /// The profile folder for file fixtures, set once the Testing profile opened.
    var fixtureHome: (() throws -> URL)?
    /// Summary of the last file fixture, reported in the app scope.
    private(set) var fileFixture: FileTreeManifest?

    init(model: LabModel) { self.model = model }

    var currentPresentation: UUID? { model.presentationID }

    func snapshot(scope: String) throws -> ScreenSnapshot {
        let destination = model.destination
        var fields: [String: JSONValue] = [:]
        if scope == "app" || destination.route == .projects {
            fields["projectCount"] = .integer(Int64(model.workspace.projects.count))
        }
        if scope == "app", let manifest = fileFixture {
            fields["fileFixture"] = ["files": .integer(Int64(manifest.entries.filter { $0.kind == .file }.count)),
                                     "totalBytes": .integer(Int64(manifest.totalBytes)),
                                     "duplicateGroups": .integer(Int64(manifest.duplicateGroups.count))]
        }
        if scope == "app" || destination.route == .controls {
            fields["queued"] = .array(model.queuedNames.map(JSONValue.string))
            fields["queueCount"] = .integer(Int64(model.queuedNames.count))
            fields["mapItems"] = .array(model.mapItems.map(JSONValue.string))
            fields["queuedVisibleOnMap"] = .array(model.queuedVisibleOnMap.map(JSONValue.string))
        }
        if destination.route == .controls, scope != "app" {
            fields["detailLevel"] = .integer(Int64(model.detailLevel))
            fields["detailName"] = .string(model.detailName)
            fields["density"] = .string(model.density.rawValue)
            fields["advancedExpanded"] = .bool(model.advancedExpanded)
            fields["showHidden"] = .bool(model.showHidden)
            fields["highlighted"] = .string(model.queue[model.highlighted].name)
            fields["displayPopoverShown"] = .bool(model.displayPopoverShown)
            if let hovered = model.hovered { fields["hovered"] = .string(hovered) }
            if let folder = model.importedFolder { fields["importedFolder"] = .string(folder) }
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

    /// The slow fixture models a real scan: it takes five seconds, so the host answers `accepted` and tracks it.
    func loadFixture(_ id: String, arguments: [String: JSONValue], context: CommandContext) async throws -> [String: JSONValue] {
        if id == "slow-fixture-v1" { try await Task.sleep(for: .seconds(5)) }
        if id == "files-v1" { return try loadFiles(context: context) }
        return try loadFixture(id, context: context)
    }

    /// Generates a small home folder with duplicates, a hard link, an old download and an app package.
    private func loadFiles(context: CommandContext) throws -> [String: JSONValue] {
        guard let fixtureHome else { throw Failure(.notReady, "The Testing profile is not open.") }
        let tree = FileTree([
            .file("Downloads/installer.dmg", size: 2.mb, seed: 3, age: .days(300)),
            .duplicate("Desktop/installer copy.dmg", of: "Downloads/installer.dmg"),
            .hardLink("Documents/installer-link.dmg", to: "Downloads/installer.dmg"),
            .file("Documents/notes.txt", size: 4.kb, seed: 9, age: .days(2)),
            .directory("Documents/Empty"),
            .symlink("Desktop/Docs", to: "../Documents"),
            .package("Applications/Sample.app", bundleId: "dev.agentdevkit.fixture.sample"),
        ])
        let manifest: FileTreeManifest
        do { manifest = try tree.materialize(in: fixtureHome(), replace: true) }
        catch { throw Failure(.internalError, "The file fixture could not be written.") }
        fileFixture = manifest
        _ = try apply(Fixture.named("files-v1"), requestId: context.requestId)
        return ["root": .string(manifest.root), "files": .integer(Int64(manifest.entries.filter { $0.kind == .file }.count)),
                "duplicateGroups": .integer(Int64(manifest.duplicateGroups.count))]
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
        model.resetControls()
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
                AgentAction("queue.toggle", scope: LabRoute.controls.rawValue,
                            input: ObjectSchema(["names": .array(.string(maxLength: 64, oneOf: model.queue.map(\.name)), maxItems: 8)],
                                                required: ["names"]), as: QueueToggle.self) { [model] input, _ in
                    for name in input.names { model.toggleQueue(name) }
                    return .completed
                },
                AgentAction("controls.seedMapBug", scope: LabRoute.controls.rawValue,
                            input: ObjectSchema(["enabled": .boolean], required: ["enabled"]), as: Toggle.self) { [model] input, _ in
                    model.mapBugEnabled = input.enabled
                    if !input.enabled { model.rebuildMap() }
                    return .completed
                },
                AgentAction("controls.import", scope: LabRoute.controls.rawValue, input: .empty, as: Empty.self, presentsUI: true,
                            enabled: { [model] in model.destination.route == .controls }) { [model] _, _ in
                    guard await model.chooseImportFolder() else { throw Failure(.cancelled, "The person cancelled the panel.") }
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
            ui: .all,
            invariants: [
                // The DiskUnbloat stale-map bug as an invariant: a queued folder must leave the map.
                AgentInvariant("queue.mapConsistent", scope: "app") { screen in
                    let stale = screen.fields["queuedVisibleOnMap"]?.arrayValue ?? []
                    return stale.isEmpty ? .holds : .violated(details: ["queuedVisibleOnMap": .array(stale)])
                }
            ],
            experiments: [
                AgentExperiment("probe.stat", input: ObjectSchema(["path": .string(maxLength: 256)], required: ["path"])) { [weak self] arguments, _ in
                    guard let root = try self?.fixtureHome?() else { throw Failure(.notReady, "Load files-v1 first.") }
                    let relative = arguments["path"]?.stringValue ?? ""
                    guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else {
                        throw Failure(.invalidParams, "Pass a path inside the fixture home.", details: ["field": "arguments.path"])
                    }
                    let url = root.appending(path: relative)
                    var isDirectory: ObjCBool = false
                    let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
                    return ["exists": .bool(exists), "directory": .bool(isDirectory.boolValue),
                            "readable": .bool(FileManager.default.isReadableFile(atPath: url.path)),
                            "bytes": size.map { .integer(Int64($0)) } ?? .null]
                }
            ],
            operatorPrompts: true
        )
    }

    private struct QueueToggle: Decodable { let names: [String] }
    private struct Toggle: Decodable { let enabled: Bool }
    private struct Empty: Decodable {}
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
        project("slow-fixture", name: "Scanned project", count: 3),
        project("files", name: "Files project", count: 1),
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
