# AgentDevKit

AgentDevKit gives coding agents a local, developer-only bridge into a running SwiftUI or AppKit app. Use it to navigate to a screen, load deterministic test data, inspect scoped state, and follow lifecycle events while verifying the UI separately.

The app and CLI target macOS 14+ with Swift 6 and Xcode 16+. The MCP sidecar's pinned dependencies require Swift 6.4.

## Quick start

From the repository root on macOS:

```sh
swift build
swift test
xcodebuild -project Examples/AgentLab/AgentLab.xcodeproj \
  -scheme AgentLab-AgentTesting -destination 'platform=macOS' \
  -derivedDataPath .build/AgentLab build
open -n "$PWD/.build/AgentLab/Build/Products/Debug/AgentLab-AgentTesting.app" \
  --args --enable-agentdevkit
.build/debug/agentdevctl session list --json
.build/debug/agentdevctl --session dev.agentdevkit.AgentTesting session ping --json
.build/debug/agentdevctl --session dev.agentdevkit.AgentTesting capabilities --json
```

Run the CLI after AgentLab displays **Bridge active**. Select an exact session UUID when multiple instances match. The Testing app requires the launch argument on each run. Its commands are read-only and use a per-session credential stored in owner-only local discovery files. Quit the app to end the session.

The read-only session also exposes scoped state. To load fixtures or open deep routes, start a Testing instance with both opt-in arguments:

```sh
open -n "$PWD/.build/AgentLab/Build/Products/Debug/AgentLab-AgentTesting.app" \
  --args --enable-agentdevkit --allow-agentdevkit-mutations
.build/debug/agentdevctl session list --json
.build/debug/agentdevctl --session SESSION_ID scenario prepare \
  --fixture large-project-v1 --route projects.editor.inspector \
  --context '{"nodeId":"node-42"}' --wait-ready --json
.build/debug/agentdevctl --session SESSION_ID state --scope current-screen --json
```

Testing profiles use isolated temporary storage. Pass `--agentdevkit-profile UUID` to reuse a profile after relaunch. Concurrent launches require distinct profiles.

## Track work and inspect changes

```sh
.build/debug/agentdevctl --session SESSION_ID wait --condition screen.ready --json
.build/debug/agentdevctl --session SESSION_ID observe --since REVISION --json
.build/debug/agentdevctl --session SESSION_ID diagnostics recent --severity error --limit 10 --json
.build/debug/agentdevctl --session SESSION_ID actions list --json
```

Start with the revision from a state snapshot. `observe` returns fresh scoped state and a page of app-wide changes together. When `delta.hasMore` is true, continue from `delta.nextRevision` to drain the changes. When `resynced` is true, use the returned snapshot as the new baseline. Use `events since` when only the changes are needed. Action invocations use the app's save logic and can check an expected revision.

Register lifecycle names alongside each new feature. The bridge can then correlate screen open and close, work start and finish, and scenario start and finish with the same events you already read in `observe`.

## Build the MCP sidecar

```sh
swift build --package-path Tools/MCP -c release
swift build --package-path Tools/MCP -c release --show-bin-path
```

Use the absolute path to `agentdevkit-mcp` in your MCP client's stdio server configuration. The process discovers Testing sessions on the same Mac. Run `agentdevkit_session` first and pass the returned session UUID to subsequent tools. The sidecar's locked dependencies currently require Swift 6.4. The app and CLI use a separate Swift 6 package without the MCP SDK.

## Examples and integration

- [AgentLab](Examples/AgentLab/README.md) is a runnable SwiftUI app with deterministic fixtures, deep navigation, and [UI regression scenarios](Examples/AgentLab/SCENARIOS.md).
- [AppKit adoption](Examples/AppKitAdoption/README.md) shows a read-only bridge in an existing window controller.
- [Agent skill](.agents/skills/macos-agent-native/SKILL.md) covers Testing-target setup and workflows for existing apps.

## Verification

Run `bash scripts/verify-macos.sh` from a macOS desktop session to build the apps, check Release linkage, and probe both builds at runtime. GitHub Actions uses the same entry point.

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
