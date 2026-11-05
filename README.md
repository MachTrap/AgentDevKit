# AgentDevKit

AgentDevKit gives coding agents a local, developer-only bridge into a running SwiftUI or AppKit app. Use it to navigate to a screen, load deterministic test data, inspect scoped state, and follow lifecycle events while verifying the UI separately.

The package and examples target macOS 14 and later. Use Swift 6 for the package and CLI. The loopback example requires Xcode 26 or later, and the MCP sidecar requires Swift 6.2.

v0.3 and later speak wire protocol `agentdevkit/2`; v0.6 and v0.7 only add methods and optional fields. Build the app and tools from the same release. Upgrading? See the [migration guide](MIGRATION.md).

## Install the component you need

The v0.7.0 release is distributed as source. Use Swift 6 for the package and CLI, and Swift 6.2 for the MCP sidecar.

- **Skill only.** Ask your skill installer to install the [macos-agent-native directory at v0.7.0](https://github.com/MachTrap/AgentDevKit/tree/v0.7.0/.agents/skills/macos-agent-native), or copy that directory into your agent's skills directory. Keep its `references/` alongside `SKILL.md`.
- **App integration.** Add `https://github.com/MachTrap/AgentDevKit.git` in Xcode with **Exact Version 0.7.0**. Link `AgentDevKitHost` and `AgentDevKitCore` only in a dedicated Testing target with a separate bundle ID and data store. Implement one `AgentAdapter`, declare an `AgentCatalog`, and start an `AgentSession`. The library serves every protocol method. Follow the [integration guide](https://github.com/MachTrap/AgentDevKit/blob/v0.7.0/.agents/skills/macos-agent-native/references/INTEGRATION.md).
- **CLI only.** Check out the tag and build the executable product. The root package has no external dependencies.
- **MCP only.** Build the [separate MCP package](#build-the-mcp-sidecar) from the tag. It uses the client libraries directly.
- **Examples.** Open the Xcode projects from the same tag and choose the Testing scheme described in the example's guide.

```sh
git clone --branch v0.7.0 --depth 1 https://github.com/MachTrap/AgentDevKit.git
cd AgentDevKit
swift build -c release --product agentdevctl
.build/release/agentdevctl --version
```

## Choose a session source

| Testing app (`SessionLocation`) | CLI global options | MCP server environment |
| --- | --- | --- |
| Unsandboxed (`.local`) | Default | Default |
| Sandboxed, own container (`.appContainer`, chosen automatically) | `--session BUNDLE_ID`, or `--container BUNDLE_ID` | `sessionId` = bundle ID, or `AGENTDEVKIT_CONTAINER=BUNDLE_ID` |
| Same-team App Group (`.appGroup`) | `--app-group TEAMID.adk` | `AGENTDEVKIT_APP_GROUP=TEAMID.adk` |
| Paired loopback (`.pairingDirectory`) | `--pairing-dir /absolute/private/folder` | `AGENTDEVKIT_PAIRING_DIR=/absolute/private/folder` |

Place CLI options before the command. Configure one location per process.

A sandboxed Testing app needs no App Group, team signing or pairing folder. `AgentSession.start(host, readOnly:)` publishes inside the app's own container, and the tools find it from the bundle ID. App Group and paired loopback remain available for tools that must run sandboxed themselves, or when the container path is too long. The socket path must fit in 104 bytes, which allows a bundle ID of about 45 characters with a home folder like `/Users/name`. `session list` does not scan containers, so pass the bundle ID. For an App Group, sign the app and both tools with the same team and matching App Group entitlement. For loopback, select an owner-only folder in the Testing app once. The bookmark survives launches and the TLS certificate and bridge credential rotate each session. See the [sandbox setup and verification guide](Examples/AgentLab/README.md#sandboxed-testing).

`session list` shows each session's protocol version. A v0.2 app or tool reports `UNSUPPORTED_VERSION` (exit 6) with a remedy instead of misbehaving.

## Quick start

From the repository root on macOS:

```sh
swift build --product agentdevctl
xcodebuild -project Examples/AgentLab/AgentLab.xcodeproj \
  -scheme AgentLab-AgentTesting -destination 'platform=macOS' \
  -derivedDataPath .build/AgentLab build
open -n "$PWD/.build/AgentLab/Build/Products/Debug/AgentLab-AgentTesting.app" \
  --args --enable-agentdevkit
.build/debug/agentdevctl session list --json
.build/debug/agentdevctl --session dev.agentdevkit.AgentTesting session ping --json
.build/debug/agentdevctl --session dev.agentdevkit.AgentTesting capabilities --json
```

Run the CLI after AgentLab displays **Bridge active**. `--session` accepts a UUID or a bundle ID that matches one session. Select an exact UUID when multiple instances match. The Testing app requires the launch argument on each run. Its commands are read-only and use a per-session credential stored in owner-only local discovery files. Quit the app to end the session.

The read-only session also exposes scoped state. To load fixtures or open deep routes, start a Testing instance with both opt-in arguments:

```sh
open -n "$PWD/.build/AgentLab/Build/Products/Debug/AgentLab-AgentTesting.app" \
  --args --enable-agentdevkit --allow-agentdevkit-mutations
.build/debug/agentdevctl session list --json
.build/debug/agentdevctl --session SESSION_ID scenario prepare \
  --fixture large-project-v1 --route projects.editor.inspector \
  --context '{"nodeId":"node-42"}' --json
.build/debug/agentdevctl --session SESSION_ID state --json
```

Testing profiles use isolated temporary storage. Pass `--agentdevkit-profile UUID` to reuse a profile after relaunch. Concurrent launches require distinct profiles.

## Launch, select once, read one value

```sh
.build/debug/agentdevctl launch "$PWD/.build/AgentLab/Build/Products/Debug/AgentLab-AgentTesting.app" \
  --mutations --replace --wait screen.ready
export AGENTDEVKIT_SESSION=dev.agentdevkit.AgentTesting      # or a .agentdevkit.json file
.build/debug/agentdevctl navigation open --route settings.controls
.build/debug/agentdevctl state --field density                # raw value, exit 4 when absent
.build/debug/agentdevctl wait --until 'density=regular'
.build/debug/agentdevctl doctor --expect-id controls.density  # which startup stage failed, if any
```

A misspelled ID returns the closest valid name and a runnable example. Slow fixtures, scenarios and actions that open panels answer `accepted`; add `--wait` to follow them, or ask `operations status`.

## Track work and inspect changes

```sh
.build/debug/agentdevctl --session SESSION_ID wait --condition screen.ready --timeout-ms 1500 --json
.build/debug/agentdevctl --session SESSION_ID wait --condition operation.completed --operation UUID --json
.build/debug/agentdevctl --session SESSION_ID observe --since REVISION --json
.build/debug/agentdevctl --session SESSION_ID diagnostics recent --severity error --limit 10 --json
.build/debug/agentdevctl --session SESSION_ID actions list --json
```

Start with the revision from a state snapshot. `observe` returns fresh scoped state and a page of app-wide changes together. When `delta.hasMore` is true, continue from `delta.nextRevision` to drain the changes. When `resynced` is true, use the returned snapshot as the new baseline. Use `events since` when only the changes are needed. Timeouts report the open `blockers`. Add `--no-fail-on-timeout` to get `satisfied: false` instead of an error. Action invocations use the app's save logic, return an outcome and the new revision, and fail with `STALE_REVISION` when state moved after `--revision`. Retrying with the same request ID replays the original response. Exit codes: 2 invalid input, 3 session or connection, 4 app failure, 5 timeout, 6 version or identity mismatch.

Register lifecycle names alongside each new feature. The bridge can then correlate screen open and close, work start and finish, and scenario start and finish with the same events you already read in `observe`.

## See the window

Apps that opt in with `AgentCatalog(ui: .all)` let agents look at their own windows, with no Screen Recording or Accessibility permission:

```sh
.build/debug/agentdevctl --session SESSION_ID ui capture --out window.png
.build/debug/agentdevctl --session SESSION_ID ui tree --only-identified
.build/debug/agentdevctl --session SESSION_ID ui press --id button.send
.build/debug/agentdevctl --session SESSION_ID operations list
```

The default capture draws the main window plus every sheet, popover and alert above it; `ui surfaces` lists them. `ui tree --lint` finds identifiers SwiftUI copied onto children. Drive real controls with `ui set`, `ui choose`, `ui expand` and `ui press --path`, and send in-process input with `ui key`, `ui hover` and `ui scroll`. The MCP sidecar returns captures as image content, so the model sees the UI directly. Captures approximate Liquid Glass and popover chrome and report it; check controls with `ui tree`. To add a Testing target to an app, start with `agentdevctl scaffold --app NAME`.

## Keep a bug fixed

```sh
.build/debug/agentdevctl recipe run Examples/AgentLab/recipes/queue-map.json      # bursts, waits, assertions; exit 4 on failure
.build/debug/agentdevctl invariants                                               # app invariants checked on every change
.build/debug/agentdevctl ui capture --baseline 'shots/controls-{locale}-{appearance}.png'
.build/debug/agentdevctl audit-release .build/AgentLabRelease/Build/Products/Release/AgentLab.app
```

When an agent needs a person, `operator ask --question … --options Yes,No --wait` shows a labelled Testing-only panel in the app.

## Build the MCP sidecar

```sh
swift build --package-path Tools/MCP --force-resolved-versions -c release
swift build --package-path Tools/MCP --force-resolved-versions -c release --show-bin-path
```

Use the absolute path to `agentdevkit-mcp` in your MCP client's stdio server configuration, for example `claude mcp add agentdevkit -- /absolute/path/to/agentdevkit-mcp`. Set a session location in that configuration when using a sandboxed app. Run `agentdevkit_session` first and pass the returned session UUID or bundle ID to subsequent tools. The CLI and MCP tools are generated from one operation table, so names, fields, defaults and timeouts match. The sidecar's locked dependencies currently require Swift 6.2. The app and CLI use a separate Swift 6 package without the MCP SDK.

## Examples and integration

- [AgentLab](Examples/AgentLab/README.md) is a runnable SwiftUI app with deterministic fixtures, deep navigation, and [UI regression scenarios](Examples/AgentLab/SCENARIOS.md).
- [AppKit adoption](Examples/AppKitAdoption/README.md) shows a read-only bridge in an existing window controller.
- [Agent skill](.agents/skills/macos-agent-native/SKILL.md) covers Testing-target setup and workflows for existing apps.

## Verification

Run `bash scripts/verify-macos.sh` from a macOS desktop session to build the apps, check Release linkage, and probe both builds at runtime. GitHub Actions uses the same entry point.

To publish a release, merge to `main`, then tag that commit so the versioned links above and Xcode's **Exact Version** resolve:

```sh
git tag -a v0.7.0 -m "AgentDevKit 0.7.0" && git push origin v0.7.0
python3 scripts/check-version.py --release
```

| Path | Contents |
| --- | --- |
| `Sources/` | Swift framework modules and `agentdevctl` |
| `Tools/MCP/` | MCP sidecar and its pinned dependencies |
| `Examples/` | Native sample projects and UI verification |
| `Tests/` and `scripts/` | Package tests and live verification |
| `.agents/skills/` | Installable skill and workflow references |

For changes to the repository, see [AGENTS.md](AGENTS.md).

## License

[MIT](LICENSE)
