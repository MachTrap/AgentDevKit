# Migrating from v0.2 to v0.3

v0.3 moves the protocol runtime into the library. An app now supplies one main-actor adapter and a declarative catalog, and the host serves every protocol method. The wire protocol moves to `agentdevkit/2`, and the Swift API changes are source-breaking.

Build the app, the CLI and the MCP sidecar from the same release.

## Compatibility

| Pair | Result |
| --- | --- |
| v0.3 tools ↔ v0.3 app | Supported |
| v0.2 CLI → v0.3 app | `UNSUPPORTED_VERSION`, exit 6. The v0.2 client sees `agentdevkit/2` in the descriptor |
| v0.3 CLI → v0.2 app | `session list` shows the session as `agentdevkit/1`. Selecting it returns `UNSUPPORTED_VERSION` with `details.remedy`, exit 6 |
| `agentdevkit/1` frame → v0.3 host | `UNSUPPORTED_VERSION` with `details.supported: ["agentdevkit/2"]` |

Session descriptors and the existing locations are unchanged. A v0.3 descriptor adds a `limits` object. A new `.appContainer` location lets a sandboxed Testing app publish in its own container without an App Group.

## Swift API

| v0.2 | v0.3 |
| --- | --- |
| `AgentHost(commands:allowMutations:routes:fixtures:scopes:actions:lifecycle:)` | `AgentHost(adapter:runtime:catalog:allowMutations:configuration:)`, or `AgentHost(catalog:allowMutations:configuration:)` for typed commands only |
| App-written `state.snapshot`, `state.observe`, `events.since`, `diagnostics.recent`, `actions.list`, `actions.invoke`, `runtime.wait`, `navigation.open`, `fixtures.load`, `scenario.prepare` | Built in. Implement `AgentAdapter` (`snapshot`, `resolve`, `present`, `readiness`, `currentPresentation`, `loadFixture`) |
| `Capabilities.RouteCapability(id:contextKeys:…)` | `AgentRoute(id, context: ObjectSchema, windowId:, accessibilityId:, readinessGates:)` |
| `ActionCapability` list plus a hand-written `invoke` switch | `AgentAction(id, scope:, input: ObjectSchema, as: Input.self, enabled:, run:)`, returning `ActionOutcome` |
| String wait conditions parsed by the app | Built-in conditions, plus `AgentCondition(id, arguments:, evaluate:)` |
| `AppCommand(command, mutating:, parameterKeys:)` | `AppCommand(command, parameters: ObjectSchema)`. `Command(_, mutating:)` carries the flag |
| `RouteContext {projectId, nodeId}` | `RouteContext = [String: JSONValue]`, validated by the route's schema |
| `FixtureState(fixture:projectId:nodeId:revision:)` | `FixtureState(fixture:revision:fields:)` |
| `RevisionJournal` plus subscriptions, a diagnostics ring and token variables in app code | `AgentRuntime`: `record`, `begin` / `end` (optionally by `SpanSlot`), `withLifecycle`, `diagnose`, `notifyChange` |
| `waitForChange(until:changes:timeout:evaluate:)` | Internal. The built-in waits use it |
| `AgentHost.Transport` and `SessionSource` | `SessionLocation { .local, .appGroup, .pairingDirectory }` |
| `host.start()` / `host.start(transport:)` throwing `Failure` | `host.start(at:loopbackIdentity:)`, which throws `AgentHostStartError`. Also `host.state` and `stateUpdates()` |
| Launch-argument parsing, profile store, pairing panel and terminate reply in app code | `LaunchOptions.parse(appFlags:)`, `TestingProfile`, `LoopbackPairing` and `AgentSession` |
| `AgentClient(session:source:)`, `AgentClient.sessions(source:)` | `AgentClient(session:at:)`, `AgentClient.sessions(at:)`. `call(_:_:timeoutMs:requestId:)` |
| `Failure.Code` enum, `details: [String: String]` | Open `Failure.Code` struct, `details: [String: JSONValue]`, and `Code.exitCode` |

AgentLab's integration shrank from 753 to 311 lines:

| v0.2 file | Lines | v0.3 file | Lines |
| --- | --- | --- | --- |
| `LabCommands.swift` | 360 | `LabAdapter.swift` | 191 |
| `LabRuntime.swift` | 130 | `LabEvents.swift` | 63 |
| `TestingSession.swift` | 196 | `TestingSession.swift` | 57 |
| `TestingWorkspace.swift` | 67 | removed | — |

The AppKit example's bridge shrank from 42 to 31 lines.

## Wire

- **Response identity.** Every authenticated response carries `sessionId` and `pid`. The client checks them on each call and no longer sends `system.hello` first, so each call costs one connection and one rate token.
- **Error details** are a JSON object. Blockers are an array; `latestRevision` is an integer; `resyncRequired` is a boolean.
- **New error codes:**

  | Code | Replaces or means |
  | --- | --- |
  | `SESSION_NOT_FOUND` | No match. `SESSION_EXPIRED` now means only an exited process or a stale listener |
  | `AMBIGUOUS_SESSION` | Was `CONFLICT` |
  | `CONNECTION_LOST` | The connection closed after the request was sent |
  | `INVALID_RESPONSE` | An undecodable response. Was `APP_INSTANCE_MISMATCH` |
  | `ACTION_NOT_FOUND` | Was `UNKNOWN_METHOD` |
  | `RESPONSE_TOO_LARGE` | Was a dropped connection |

- **`runtime.wait`** takes `{condition, scope, arguments?, failOnTimeout?}`. Move `operationId`, `field` and `value` into `arguments`. The result is `{satisfied, blockers, screen, lifecycle?}`.
- **`actions.invoke`** returns `{actionId, outcome, revision, operationId?, screen}`. A stale `expectedRevision` returns `STALE_REVISION`, which was `CONFLICT`.
- **Capabilities:**
  - `routes[].contextKeys` is replaced by `contextSchema`.
  - New fields: `libraryVersion`, `conditions`, `diagnosticCategories`.
  - `limits.maxFrameBytes` is renamed `maxResponseBytes`.
  - Read-only sessions no longer list scenario lifecycle entries.
- **Request IDs.** Repeating a request ID with identical method and params replays the original response. In v0.2 this was `CONFLICT`.
- **Unauthenticated requests.** These count against a separate budget. The request frame must arrive within 500 ms.

## CLI and MCP

- **CLI:**
  - `--session` accepts a unique bundle ID.
  - `state`, `observe` and `wait` default to `--scope current-screen`.
  - Every command accepts `--timeout-ms`.
  - New `wait` options: `--args JSON` and `--no-fail-on-timeout`.
  - Exit codes changed: 3 is session or connection only; `CONFLICT`, `PERMISSION_DENIED` and `STALE_REVISION` are now 4.
- **MCP:**
  - New `agentdevkit_fixtures` tool.
  - Every tool accepts `timeoutMs`.
  - `sessionId` accepts a unique bundle ID.
  - `scope` defaults to `current-screen`.
  - `agentdevkit_wait` takes `arguments`.

## Upgrade steps

1. Update the package to exact version 0.3.0 in the Testing target.
2. Replace the command list with an `AgentAdapter` over your existing model and an `AgentCatalog`. Delete app-side implementations of built-in methods.
3. Move event recording to `AgentRuntime`, and call it from the same model boundaries.
4. Replace launch-flag parsing, storage and termination with `LaunchOptions`, `TestingProfile` and `AgentSession`.
5. Rebuild the CLI and MCP sidecar from the same tag. Update scripts that parse `details` strings, `CONFLICT` on stale saves, or exit code 3 for `CONFLICT`.
6. Rerun the Testing and Release builds, live checks and the Release-exclusion audit.
