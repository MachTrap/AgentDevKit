import AgentDevKitCore
import AgentDevKitHost
import Foundation

@MainActor
final class LabRuntime {
    private(set) var journal = RevisionJournal()
    private var screenSpan: LifecycleToken?
    private var documentSpan: LifecycleToken?
    private var saveSpan: LifecycleToken?
    private var modalSpan: LifecycleToken?
    private var activeScenario: LifecycleToken?
    private var diagnostics: [DiagnosticRecord] = []
    private var subscriptions: [UUID: AsyncStream<Void>.Continuation] = [:]

    init(model: LabModel) {
        model.onChange = { [weak self] change, route, presentation, requestId, scenarioId in
            self?.record(change, route: route, presentation: presentation, requestId: requestId, scenarioId: scenarioId)
        }
    }

    func beginScenario(_ requestId: UUID) -> LifecycleToken? {
        let token = journal.beginLifecycle(.scenario, name: "scenario.prepare", scope: "app",
                                           id: requestId, correlationId: requestId)
        activeScenario = token
        notifyObservers()
        return token
    }

    func endScenario(_ token: LifecycleToken?, outcome: LifecycleEvent.Outcome) {
        if activeScenario == token { activeScenario = nil }
        if journal.endLifecycle(token, outcome: outcome) { notifyObservers() }
    }

    private func record(
        _ change: LabModel.Change, route: LabRoute, presentation: UUID, requestId: UUID?, scenarioId: UUID?
    ) {
        switch change {
        case .appeared:
            screenSpan = journal.beginLifecycle(.screen, name: route.rawValue, scope: route.rawValue,
                                                parentId: scenarioId, correlationId: requestId, changedFields: ["ready"])
        case .disappeared, .screenReplaced:
            journal.endLifecycle(screenSpan, outcome: change == .screenReplaced ? .superseded : .completed,
                                 changedFields: ["ready"])
            screenSpan = nil
        case .documentStarted:
            documentSpan = journal.beginLifecycle(.work, name: "document.load", scope: route.rawValue,
                                                  id: presentation, parentId: scenarioId, correlationId: requestId,
                                                  changedFields: ["documentPhase"])
        case .documentLoaded, .documentFailed, .documentCancelled:
            let outcome: LifecycleEvent.Outcome = switch change {
            case .documentLoaded: .completed
            case .documentFailed: .failed
            default: .cancelled
            }
            journal.endLifecycle(documentSpan, outcome: outcome, changedFields: ["documentPhase"])
            documentSpan = nil
        case .projectFormOpened:
            modalSpan = journal.beginLifecycle(.screen, name: "projects.form", scope: route.rawValue,
                                               id: presentation, parentId: screenSpan?.id, changedFields: ["modal"])
        case .projectFormClosed:
            journal.endLifecycle(modalSpan, outcome: .completed, changedFields: ["modal"])
            modalSpan = nil
        case .saveStarted:
            let parent = activeScenario?.id == requestId ? activeScenario?.id : nil
            saveSpan = journal.beginLifecycle(.work, name: "workspace.save", scope: route.rawValue,
                                              id: presentation, parentId: parent, correlationId: requestId)
        case .saveFinished, .saveFailed:
            journal.endLifecycle(saveSpan, outcome: change == .saveFinished ? .completed : .failed)
            saveSpan = nil
        default:
            let fields: [String] = switch change {
            case .storageOpened, .workspaceReplaced: ["workspace"]
            case .storageFailed: ["storageError"]
            case .navigation: ["screenId", "ready", "documentPhase"]
            case .nodeSaved: ["nodeName", "enabled"]
            case .themeSaved, .appearanceEdited: ["theme", "accent", "appearanceDirty"]
            case .projectCreated: ["projectCount"]
            case .projectUpdated: ["projectName"]
            default: []
            }
            journal.append(type: change.rawValue, scope: route.rawValue, correlationId: requestId, changedFields: fields)
        }

        let diagnostic: DiagnosticRecord? = switch change {
        case .storageFailed:
            .init(severity: .error, category: "storage", code: "WORKSPACE_IO_FAILED",
                  message: "The isolated workspace could not be opened or saved.", correlationId: requestId)
        case .documentFailed:
            .init(severity: .error, category: "document", code: "DOCUMENT_LOAD_FAILED",
                  message: "The document service could not load the project.", correlationId: requestId)
        default: nil
        }
        if let diagnostic {
            if diagnostics.count == 64 { diagnostics.removeFirst() }
            diagnostics.append(diagnostic)
        }
        notifyObservers()
    }

    private func notifyObservers() {
        for subscription in subscriptions.values { subscription.yield(()) }
    }

    func recent(_ request: DiagnosticsRequest) throws -> [DiagnosticRecord] {
        let limit = request.limit ?? 10
        guard (1...50).contains(limit), request.category.map({ ["storage", "document"].contains($0) }) ?? true else {
            throw Failure(.invalidParams, "Unknown category or invalid diagnostic limit.")
        }
        return Array(diagnostics.reversed().lazy.filter { record in
            (request.severity != .error || record.severity == .error) &&
                (request.category == nil || record.category == request.category)
        }.prefix(limit))
    }

    func wait<Value: Sendable>(
        command: CommandContext, timeout: @escaping @MainActor () -> Failure, evaluate: () throws -> Value?
    ) async throws -> Value {
        let id = UUID()
        let (changes, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        subscriptions[id] = continuation
        defer {
            subscriptions[id] = nil
            continuation.finish()
        }
        return try await waitForChange(
            until: command.deadline - .milliseconds(120), changes: changes, timeout: timeout, evaluate: evaluate
        )
    }
}
