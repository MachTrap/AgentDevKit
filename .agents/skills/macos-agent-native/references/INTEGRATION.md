# Integrate AgentDevKit into an existing app

## Target and lifecycle

1. Find the Xcode target, composition root, router, data store and existing tests. Pick one screen and the real service or coordinator that already owns it.
2. Add a Testing app target with its own bundle ID and store.
   - Link the `AgentDevKitHost` and `AgentDevKitCore` products only in that target, from the [v0.3.0 source release](https://github.com/MachTrap/AgentDevKit/tree/v0.3.0).
   - Keep the bridge source and package products out of the normal Debug and Release targets.
   - Preserve the shipping app's entitlements.
3. Start the bridge from a Testing-only composition root:
   - **SwiftUI:** a Testing-only `NSApplicationDelegateAdaptor`.
   - **AppKit:** the Testing target's existing `NSApplicationDelegate`.

   `LaunchOptions.parse()` reads the explicit opt-in arguments `--enable-agentdevkit`, `--allow-agentdevkit-mutations`, `--agentdevkit-profile UUID` and `--agentdevkit-fixture ID`. It rejects other `--agentdevkit` arguments unless you pass them as `appFlags`. `AgentSession` starts the host, shows a status string, and implements `applicationShouldTerminate` so the session is withdrawn before exit.

## Read-only adapter

Conform one main-actor class to `AgentAdapter`. A read-only bridge needs only `snapshot(scope:)`. The library serves state, observe, events, diagnostics, actions and waits. This Testing-only example compiles against the package modules:

```swift
import AgentDevKitCore
import AgentDevKitHost
import AppKit

@MainActor
final class DocumentsBridge: AgentAdapter {
    private let session = AgentSession()
    private let runtime = AgentRuntime()
    private let selection: () -> String?

    /// Pass a closure that reads the app's existing model. Do not copy state.
    init(selection: @escaping () -> String?) { self.selection = selection }

    func start() {
        guard (try? LaunchOptions.parse())?.enabled == true else { return }
        let host = AgentHost(adapter: self, runtime: runtime, catalog: AgentCatalog(scopes: ["current-screen"]))
        session.start(host, readOnly: true)
    }

    /// Call from the model's change path, so revisions advance and waits re-evaluate.
    func selectionChanged() {
        runtime.record("selection.changed", scope: "current-screen", changedFields: ["selectedId"])
    }

    func snapshot(scope: String) throws -> ScreenSnapshot {
        ScreenSnapshot(screenId: "documents", windowId: "main", ready: selection() != nil,
                       fields: selection().map { ["selectedId": .string($0)] } ?? [:])
    }

    func terminate(_ app: NSApplication) -> NSApplication.TerminateReply { session.terminate(app) }
}
```

Snapshots return explicit, bounded fields. Never reflect arbitrary properties. Include display names only when the test needs them, sanitized by the app and bounded in UTF-8 size. In AppKit, check that the window is loaded before reading its visibility. `Examples/AppKitAdoption/TestingBridge.swift` is a complete read-only AppKit example.

## Routes, fixtures and actions

Declare everything in one `AgentCatalog`. The host builds both its method table and its capabilities from it, and validates every input before calling the adapter.

- **Routes:**
  - Declare each as `AgentRoute(id, context: ObjectSchema([...]), windowId:, accessibilityId:, readinessGates:)`.
  - `resolve(route:context:fixture:)` validates without changing state. When `fixture` is set, it validates against that fixture's data, which keeps the scenario preflight safe.
  - `present(_:request:)` uses the app's normal navigation and returns a presentation ID.
  - `readiness(of:)` reports `.ready`, `.pending(blockers:)`, `.failed(Failure)` or `.superseded`, based on actual view appearance and tracked work.
  - Implement `currentPresentation` so `screen.ready` waits notice replacement.
- **Fixtures:** list the IDs in the catalog. `loadFixture(_:context:)` replaces deterministic data through the app's own persistence, only in isolated storage, and returns summary fields. Open storage with `TestingProfile(appName:profile:)`. Grant `allowMutations: true` only when storage opened and the runner passed the mutation opt-in.
- **Actions:**
  - Declare each as `AgentAction(id, scope:, input: ObjectSchema, as: Input.self, enabled:, run:)`.
  - `run` returns `.completed`, or `.accepted(operationId:)` for tracked work that is still running.
  - Actions are semantic. They never prove that a control is visible, hittable or focusable.
- **Conditions:** add `AgentCondition`s for app-specific waits. Built-ins cover `screen.ready`, `work.quiescent`, `operation.completed`, `lifecycle.ended` and `state.field_equals`.

Read-only sessions hide routes, fixtures, actions and scenario lifecycle entries. They answer mutating methods with `PERMISSION_DENIED`. `Examples/AgentLab/AgentIntegration/LabAdapter.swift` is a complete mutation-enabled adapter.

## Lifecycle events

For each feature, agree on these during implementation: route and context, readiness, accessibility IDs, scoped state, and finite work names.

Record boundaries on the `AgentRuntime`, on the main actor with the state they describe:

- **Screen:** call `runtime.begin("screen", .screen, …)` at actual presentation and `runtime.end("screen", outcome:)` at departure.
- **Work:** use a slot such as `"document"` at the owning service, and close it on success, failure, cancellation and replacement.
- **Errors:** use `runtime.withLifecycle` for scoped work that throws.

Use static names, the presentation ID as the work span ID, and the scenario ID as the parent ID. Keep user data out of events and diagnostics. List the names in `catalog.lifecycle`. The library adds `scenario.prepare` itself. `Examples/AgentLab/AgentIntegration/LabEvents.swift` maps a whole model's changes in about 60 lines.

## Select a Testing location

- **Unsandboxed:** call `session.start(host, readOnly:)`. This uses `.local`.
- **Same-team sandbox:** call `session.start(host, at: .appGroup(groupID), readOnly:)`.
  - Sign the Testing app and the tools with the same App Group entitlement.
  - Use a short group ID so the Darwin socket path fits.
- **Paired loopback:** call `session.startPaired(host, pairing: LoopbackPairing(), readOnly:, identity:)`.
  - `identity` must create a fresh `SecIdentity` on every call.
  - Enable incoming connections on the Testing target.
  - `LoopbackPairing` stores only a security-scoped bookmark and holds the folder's scope until the session stops.
  - Bind `session.pair()` and `session.forgetPairing()` to Testing-only controls.

See the [signed AgentLab setup](https://github.com/MachTrap/AgentDevKit/blob/v0.3.0/Examples/AgentLab/README.md#sandboxed-testing) for entitlements, signing and the sample identity generator.

## Verify the integration

1. Build Testing and Release.
2. In Testing:
   - confirm the authenticated identity;
   - discover the real capabilities;
   - exercise an allowed operation;
   - assert the target screen with XCUITest or external AX;
   - check that a read-only session denies a mutation.
3. In Release:
   - inspect link inputs, dependencies and binary symbols;
   - launch it with the same opt-in argument and confirm it publishes no session.
4. Record the exact commands and observed results.
