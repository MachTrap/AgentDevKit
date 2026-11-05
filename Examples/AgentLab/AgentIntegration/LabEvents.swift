import AgentDevKitCore
import AgentDevKitHost
import Foundation

/// Maps AgentLab's model boundaries to revisioned events, paired lifecycle spans and diagnostics.
@MainActor
enum LabEvents {
    static func connect(_ model: LabModel, to runtime: AgentRuntime) {
        model.onChange = { [weak runtime] change, route, operation, requestId, scenarioId in
            runtime.map { record(change, in: $0, route: route, operation: operation, requestId: requestId, scenarioId: scenarioId) }
        }
    }

    private static func record(
        _ change: LabModel.Change, in runtime: AgentRuntime, route: LabRoute, operation: UUID, requestId: UUID?, scenarioId: UUID?
    ) {
        let scope = route.rawValue
        switch change {
        case .appeared:
            runtime.begin("screen", .screen, name: scope, scope: scope, parentId: scenarioId, correlationId: requestId, changedFields: ["ready"])
        case .disappeared, .screenReplaced:
            runtime.end("screen", outcome: change == .screenReplaced ? .superseded : .completed, changedFields: ["ready"])
        case .documentStarted:
            runtime.begin("document", .work, name: "document.load", scope: scope, id: operation, parentId: scenarioId,
                          correlationId: requestId, changedFields: ["documentPhase"])
        case .documentLoaded, .documentFailed, .documentCancelled:
            let outcome: LifecycleEvent.Outcome = change == .documentLoaded ? .completed : change == .documentFailed ? .failed : .cancelled
            runtime.end("document", outcome: outcome, changedFields: ["documentPhase"])
        case .projectFormOpened:
            runtime.begin("modal", .screen, name: "projects.form", scope: scope, id: operation,
                          parentId: runtime.span("screen")?.id, changedFields: ["modal"])
        case .projectFormClosed:
            runtime.end("modal", outcome: .completed, changedFields: ["modal"])
        case .saveStarted:
            // A save made by scenario.prepare is a child of that scenario, whose span ID is the request ID.
            let parent = requestId.flatMap { runtime.journal.activeLifecycle($0)?.kind == .scenario ? $0 : nil }
            runtime.begin("save", .work, name: "workspace.save", scope: scope, id: operation, parentId: parent, correlationId: requestId)
        case .saveFinished, .saveFailed:
            runtime.end("save", outcome: change == .saveFinished ? .completed : .failed)
        default:
            let fields: [String] = switch change {
            case .storageOpened, .workspaceReplaced: ["workspace"]
            case .storageFailed: ["storageError"]
            case .navigation: ["screenId", "ready", "documentPhase"]
            case .nodeSaved: ["nodeName", "enabled"]
            case .themeSaved, .appearanceEdited: ["theme", "accent", "appearanceDirty"]
            case .projectCreated: ["projectCount"]
            case .projectUpdated: ["projectName"]
            case .controlChanged: ["detailLevel", "density", "advancedExpanded", "showHidden"]
            case .queueChanged: ["queued", "mapItems", "queuedVisibleOnMap"]
            case .highlightChanged: ["highlighted"]
            case .hoverChanged: ["hovered"]
            case .popoverChanged: ["displayPopoverShown"]
            case .importFinished: ["importedFolder"]
            default: []
            }
            runtime.record(change.rawValue, scope: scope, correlationId: requestId, changedFields: fields)
        }
        switch change {
        case .storageFailed:
            runtime.diagnose(.init(severity: .error, category: "storage", code: "WORKSPACE_IO_FAILED",
                                   message: "The isolated workspace could not be opened or saved.", correlationId: requestId))
        case .documentFailed:
            runtime.diagnose(.init(severity: .error, category: "document", code: "DOCUMENT_LOAD_FAILED",
                                   message: "The document service could not load the project.", correlationId: requestId))
        default: break
        }
    }
}
