# Integrate AgentDevKit into an existing app

## Target and lifecycle

1. Locate the Xcode target, composition root, router, data store, and existing tests. Choose one screen and the real service or coordinator that already owns it.
2. Add a dedicated Testing app target with its own bundle ID and store. Link the `AgentDevKitHost` and `AgentDevKitCore` products there. Keep the adapter source and package products out of the normal Debug and Release targets. The local socket integration supports an unsandboxed Testing app. A sandboxed application needs a separate supported transport design and should retain its shipping entitlements.
3. In SwiftUI, start the host from a Testing-only application delegate or composition root. In AppKit, use the Testing target's existing `NSApplicationDelegate` and coordinator. Require an explicit launch argument or trusted test configuration. Call `stop()` when ending the session. Await startup and shutdown off the synchronous UI lifecycle path. In the framework checkout, `Examples/AppKitAdoption/TestingBridge.swift` shows a complete read-only AppKit adapter and asynchronous termination reply. Its native verifier compares the existing window controls with the live snapshot.

The current Swift API registers typed commands. For a read-only starting point, the following Testing-only function compiles with the package modules. Pass an existing main-actor adapter as `snapshot`.

```swift
import AgentDevKitCore
import AgentDevKitHost

@MainActor
func makeHost(
    snapshot: @escaping @MainActor @Sendable (SnapshotRequest) throws -> ScreenState
) -> AgentHost {
    AgentHost(
        commands: [
            AppCommand(AppCommands.snapshot, parameterKeys: ["scope"]) { request, _ in
                guard request.scope == "current-screen" else {
                    throw Failure(.invalidParams, "Unknown scope.")
                }
                return try snapshot(request)
            }
        ],
        scopes: ["current-screen"]
    )
}
```

Start with `try await host.start()` after opt-in. Construct any mutating registration with `mutating: true`. Set `allowMutations: true` only when the test store opened successfully and the runner explicitly opted in. Fixture adapters replace deterministic test data using the app's own persistence and service boundaries. A route adapter should validate context before changing state. Observe actual SwiftUI view appearance or AppKit view/window lifecycle plus registered work before claiming readiness.

Use explicit fields and stable accessibility identifiers. For revisions, write the event and update model state on the same actor. `ScreenState` carries `screenId`, `windowId`, `scope`, `ready`, `revision`, and a bounded field map. Use the model's real readiness gates. In AppKit, inspect an already-loaded window before reading its visibility. Prefer selection presence and stable IDs. Include display names only when intended for the test, sanitize them through the app, and bound their UTF-8 size.

For each feature, agree on route and context, readiness, accessibility IDs, scoped state, and finite work names during implementation. Pair screen entry and exit at real view or controller presentation. Pair work and approved in-app scenarios at their owners, including failures and cancellation. Use `RevisionJournal.beginLifecycle` and `endLifecycle` on the state actor, and link child spans to their parent ID. Give events static names and omit user data. Register discoverable names through `AgentHost(lifecycle:)`. In the framework checkout, `docs/04_SWIFT_API_AND_ADAPTERS.md` describes the contract and `LabRuntime.swift` shows the integration.

## Verify the integration

Build Testing and Release. In Testing, confirm authenticated identity, discover the real capabilities, exercise an allowed operation, and assert the target screen with XCUITest or external AX. Verify a mutation is denied in a read-only session. Inspect Release link inputs, dependencies, and binary symbols, and launch it with the same opt-in argument to confirm it publishes no endpoint. Record exact commands and observed results.
