import Foundation
import Observation

struct Workspace: Codable {
    struct Project: Codable, Identifiable {
        let id: String
        var name: String
        var nodes: [Node]
        var summary: String? = nil
        var modifiedAt: Date? = nil
    }

    struct Node: Codable, Identifiable {
        let id: String
        var name: String
        var notes: String
        var enabled = true

        var valid: Bool {
            !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                name.utf8.count <= 512 && notes.utf8.count <= 2048
        }
    }

    enum Theme: String, Codable, CaseIterable { case system, light, dark }
    enum Accent: String, Codable, CaseIterable { case system, blue, purple, orange }

    struct Appearance: Equatable {
        var theme: Theme
        var accent: Accent
    }

    var appearance: Appearance { Appearance(theme: theme, accent: accent ?? .system) }

    var projects: [Project]
    var theme: Theme = .system
    var accent: Accent? = nil

    static let starter = Workspace(projects: [
        Project(id: "starter", name: "Example project", nodes: [
            Node(id: "overview", name: "Overview", notes: "Outline the project here."),
            Node(id: "references", name: "References", notes: "")
        ])
    ])
}

struct ProjectFormState: Identifiable {
    let id = UUID()
    let projectId: String?
    let draft: ProjectDraft
}

struct ProjectDraft {
    var name = ""
    var summary = ""

    var valid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            name.utf8.count <= 128 && summary.utf8.count <= 2048
    }
}

enum LabRoute: String, CaseIterable {
    case home
    case projects = "projects.list"
    case editor = "projects.editor"
    case inspector = "projects.editor.inspector"
    case settings
    case advanced = "settings.advanced"
    case appearance = "settings.advanced.appearance"

    static let windowID = "main"

    var requiresProject: Bool { self == .editor || self == .inspector }

    var accessibilityID: String {
        switch self {
        case .projects: "screen.projects"
        case .editor: "screen.editor"
        case .inspector: "screen.editor.inspector"
        default: "screen." + rawValue
        }
    }
}

struct Destination: Equatable {
    let route: LabRoute
    var projectId: String? = nil
    var nodeId: String? = nil
}

@MainActor
@Observable
final class LabModel {
    enum DocumentPhase: String { case idle, loading, ready, failed }

    enum Change: String {
        case storageOpened = "storage.opened"
        case storageFailed = "storage.failed"
        case workspaceReplaced = "workspace.replaced"
        case navigation = "navigation.changed"
        case appeared = "screen.appeared"
        case disappeared = "screen.disappeared"
        case screenReplaced = "screen.replaced"
        case documentStarted = "document.started"
        case documentLoaded = "document.loaded"
        case documentFailed = "document.failed"
        case documentCancelled = "document.cancelled"
        case nodeSaved = "node.saved"
        case themeSaved = "theme.saved"
        case appearanceEdited = "appearance.edited"
        case projectCreated = "project.created"
        case projectUpdated = "project.updated"
        case projectFormOpened = "project.form.opened"
        case projectFormClosed = "project.form.closed"
        case saveStarted = "workspace.save.started"
        case saveFinished = "workspace.save.finished"
        case saveFailed = "workspace.save.failed"
    }

    enum EditError: Error { case invalidNode, inactiveNode, invalidProject, storageUnavailable }
    typealias DocumentLoader = @MainActor (Workspace.Project) async throws -> Workspace.Project

    private(set) var workspace = Workspace.starter
    private(set) var destination = Destination(route: .home)
    private(set) var presentationID = UUID()
    private(set) var ready = false
    private(set) var documentPhase = DocumentPhase.idle
    private(set) var storageError: String?
    @ObservationIgnored var onChange: ((Change, LabRoute, UUID, UUID?, UUID?) -> Void)?
    @ObservationIgnored private var correlationId: UUID?
    @ObservationIgnored private var scenarioId: UUID?
    @ObservationIgnored private var saveWorkspace: ((Workspace) throws -> Void)?
    @ObservationIgnored var loadDocument: DocumentLoader = { $0 }
    private(set) var project: Workspace.Project?
    private(set) var projectForm: ProjectFormState?
    private(set) var projectFormVisible = false
    private(set) var appearanceDraft: Workspace.Appearance?
    var previewAppearance: Workspace.Appearance { appearanceDraft ?? workspace.appearance }
    var appearanceDirty: Bool { appearanceDraft != nil }

    var node: Workspace.Node? {
        project?.nodes.first { $0.id == destination.nodeId }
    }

    func configure(load: () throws -> Workspace?, save: @escaping (Workspace) throws -> Void) throws {
        if let persisted = try load() { workspace = persisted }
        saveWorkspace = save
        emit(.storageOpened)
    }

    func configureDefaultStore() {
        guard saveWorkspace == nil else { return }
        let root = URL.applicationSupportDirectory
            .appending(path: "dev.agentdevkit.AgentLab", directoryHint: .isDirectory)
        let file = root.appending(path: "workspace.json")
        do {
            try configure(load: {
                do { return try JSONDecoder().decode(Workspace.self, from: Data(contentsOf: file)) }
                catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
            }, save: { workspace in
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try JSONEncoder().encode(workspace).write(to: file, options: .atomic)
            })
        } catch {
            reportStorageError()
        }
    }

    func reportStorageError(correlationId: UUID? = nil) {
        storageError = "The workspace could not be opened or saved."
        emit(.storageFailed, correlationId: correlationId)
    }

    func replaceWorkspace(_ replacement: Workspace, correlationId: UUID?) throws {
        try save(replacement, correlationId: correlationId)
        appearanceDraft = nil
        emit(.workspaceReplaced, correlationId: correlationId)
    }

    func present(_ destination: Destination, correlationId: UUID? = nil, scenarioId: UUID? = nil) {
        dismissProjectForm()
        if self.destination.route == .appearance && destination.route != .appearance { resetAppearance() }
        if ready {
            ready = false
            emit(.screenReplaced, correlationId: self.correlationId)
        }
        if documentPhase == .loading { emit(.documentCancelled, correlationId: self.correlationId) }
        self.destination = destination
        self.correlationId = correlationId
        self.scenarioId = scenarioId
        presentationID = UUID()
        ready = false
        project = nil
        documentPhase = destination.route.requiresProject ? .loading : .idle
        emit(.navigation, correlationId: correlationId)
        if documentPhase == .loading { emit(.documentStarted, correlationId: correlationId) }
    }

    func fetchDocument(_ id: UUID) async {
        guard id == presentationID, documentPhase == .loading,
              let source = workspace.projects.first(where: { $0.id == destination.projectId }) else { return }
        do {
            let document = try await loadDocument(source)
            try Task.checkCancellation()
            guard id == presentationID, documentPhase == .loading else { return }
            project = document
            documentPhase = .ready
            emit(.documentLoaded, correlationId: correlationId)
        } catch is CancellationError {
            guard id == presentationID, documentPhase == .loading else { return }
            documentPhase = .idle
            emit(.documentCancelled, correlationId: correlationId)
        } catch {
            guard id == presentationID, documentPhase == .loading else { return }
            documentPhase = .failed
            emit(.documentFailed, correlationId: correlationId)
        }
    }

    func retryDocument() { present(destination) }

    func didAppear(_ id: UUID) {
        guard id == presentationID, !ready, !destination.route.requiresProject || documentPhase == .ready else { return }
        ready = true
        emit(.appeared, correlationId: correlationId)
    }

    func didDisappear(_ id: UUID) {
        guard id == presentationID, ready else { return }
        ready = false
        emit(.disappeared, correlationId: correlationId)
    }

    func saveNode(_ node: Workspace.Node, correlationId: UUID? = nil) throws {
        guard node.valid else { throw EditError.invalidNode }
        guard destination.route == .inspector, ready, node.id == destination.nodeId,
              let projectIndex = workspace.projects.firstIndex(where: { $0.id == destination.projectId }),
              let nodeIndex = workspace.projects[projectIndex].nodes.firstIndex(where: { $0.id == node.id })
        else { throw EditError.inactiveNode }
        var replacement = workspace
        replacement.projects[projectIndex].nodes[nodeIndex] = node
        replacement.projects[projectIndex].modifiedAt = .now
        try save(replacement, correlationId: correlationId)
        project = replacement.projects[projectIndex]
        emit(.nodeSaved, correlationId: correlationId)
    }

    func openProjectForm(_ project: Workspace.Project? = nil) {
        let draft = ProjectDraft(name: project?.name ?? "", summary: project?.summary ?? "")
        projectForm = ProjectFormState(projectId: project?.id, draft: draft)
    }

    func projectFormDidAppear(_ id: UUID) {
        guard projectForm?.id == id, !projectFormVisible else { return }
        projectFormVisible = true
        emit(.projectFormOpened, operationID: id)
    }

    func dismissProjectForm(_ id: UUID? = nil) {
        guard let form = projectForm, id == nil || id == form.id else { return }
        projectForm = nil
        if projectFormVisible {
            projectFormVisible = false
            emit(.projectFormClosed, operationID: form.id)
        }
    }

    func saveProject(_ draft: ProjectDraft, id: String?) throws {
        guard draft.valid else { throw EditError.invalidProject }
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        var replacement = workspace
        if let id {
            guard let index = replacement.projects.firstIndex(where: { $0.id == id }),
                  destination.projectId == id, project?.id == id else { throw EditError.invalidProject }
            replacement.projects[index].name = name
            replacement.projects[index].summary = draft.summary
            replacement.projects[index].modifiedAt = .now
            try save(replacement)
            project = replacement.projects[index]
            emit(.projectUpdated)
        } else {
            guard destination.route == .projects else { throw EditError.invalidProject }
            let newProject = Workspace.Project(
                id: UUID().uuidString, name: name,
                nodes: [.init(id: "overview", name: "Overview", notes: "")],
                summary: draft.summary, modifiedAt: .now
            )
            replacement.projects.append(newProject)
            try save(replacement)
            emit(.projectCreated)
            present(Destination(route: .editor, projectId: newProject.id))
        }
    }

    func updateAppearance(_ appearance: Workspace.Appearance) {
        let draft = appearance == workspace.appearance ? nil : appearance
        guard draft != appearanceDraft else { return }
        appearanceDraft = draft
        emit(.appearanceEdited)
    }

    func resetAppearance() { updateAppearance(workspace.appearance) }

    func saveTheme(_ theme: Workspace.Theme, correlationId: UUID? = nil) throws {
        try saveAppearance(.init(theme: theme, accent: workspace.appearance.accent), correlationId: correlationId)
    }

    func saveAppearance(_ appearance: Workspace.Appearance, correlationId: UUID? = nil) throws {
        var replacement = workspace
        replacement.theme = appearance.theme
        replacement.accent = appearance.accent
        try save(replacement, correlationId: correlationId)
        appearanceDraft = nil
        emit(.themeSaved, correlationId: correlationId)
    }

    private func save(_ replacement: Workspace, correlationId: UUID? = nil) throws {
        guard let saveWorkspace else { throw EditError.storageUnavailable }
        let operationID = UUID()
        emit(.saveStarted, correlationId: correlationId, operationID: operationID)
        do { try saveWorkspace(replacement) }
        catch {
            emit(.saveFailed, correlationId: correlationId, operationID: operationID)
            reportStorageError(correlationId: correlationId)
            throw error
        }
        workspace = replacement
        storageError = nil
        emit(.saveFinished, correlationId: correlationId, operationID: operationID)
    }

    private func emit(_ change: Change, correlationId: UUID? = nil, operationID: UUID? = nil) {
        onChange?(change, destination.route, operationID ?? presentationID, correlationId, scenarioId)
    }
}
