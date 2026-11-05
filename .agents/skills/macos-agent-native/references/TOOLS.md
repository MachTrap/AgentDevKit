# Tool commands

Build the CLI from the v0.4.0 checkout with `swift build -c release --product agentdevctl`, then use `.build/release/agentdevctl` or put it on your path. Tools and app must come from the same release: v0.3 speaks `agentdevkit/2`.

A Testing app must be running with its bridge explicitly enabled. AgentLab uses `--enable-agentdevkit`. To permit fixture, route and save commands, also pass `--allow-agentdevkit-mutations`.

```sh
agentdevctl session list --json
agentdevctl --session SESSION_ID session ping --json
agentdevctl --session SESSION_ID capabilities --json

agentdevctl --session SESSION_ID scenario prepare \
  --fixture large-project-v1 --route projects.editor.inspector \
  --context '{"nodeId":"node-42"}' --json
agentdevctl --session SESSION_ID state --json
agentdevctl --session SESSION_ID wait --condition screen.ready --timeout-ms 1500 --json
agentdevctl --session SESSION_ID observe --since REVISION --limit 20 --json
agentdevctl --session SESSION_ID events since --revision REVISION --limit 20 --json
agentdevctl --session SESSION_ID diagnostics recent --severity error --limit 10 --json
agentdevctl --session SESSION_ID actions list --json
agentdevctl --session SESSION_ID action invoke --id inspector.save \
  --args '{"name":"Verified test edit"}' --revision REVISION --json
```

- **Names.** AgentLab's routes and fixtures are examples. Read the target app's capabilities for:
  - route `contextSchema`;
  - wait `conditions`;
  - `diagnosticCategories`;
  - effective `limits`, including `maxTimeoutMs`.
- **Session selection.** `--session` takes a UUID, or a bundle ID that matches exactly one session.
- **Scope.** `state`, `observe` and `wait` default to `--scope current-screen`.
- **Timeouts.** Every command accepts `--timeout-ms`.
- **Exit codes:**

  | Code | Meaning |
  | --- | --- |
  | 2 | Invalid input |
  | 3 | Session or connection |
  | 4 | App failure |
  | 5 | Timeout |
  | 6 | Version or identity mismatch |

- **Setup alone.** Use `fixtures load --fixture ID` or `navigation open --route ID`.
- **Waiting on started work.** Pass `--no-wait` to get an accepted transition, then use its operation ID with `wait --condition operation.completed --operation UUID`.
- **Finished spans.** `wait --condition lifecycle.ended --operation UUID` returns a retained span outcome even after you have navigated elsewhere.
- **Checking without failing.** Add `--no-fail-on-timeout` to receive `satisfied: false` and the open `blockers` instead of a TIMEOUT error.
- **Other conditions.** Pass arguments with `--args JSON`, or with `--field KEY --value JSON`.
- **Long waits.** `wait --timeout-ms` accepts up to 120000. A wait longer than the session's `limits.maxTimeoutMs` runs as consecutive requests, and returns as soon as the condition holds. MCP `agentdevkit_wait` behaves the same way.
- **Fixture arguments.** `fixtures load` and `scenario prepare` take `--fixture-args JSON` matching `capabilities.fixtureArguments[fixture]`, for example a test server's base URL.

Use `observe` when you need both state and changes:

- A response with `resynced: true` supplies a fresh baseline.
- When paging, continue from the delta's `nextRevision`. If `hasMore` is true, keep reading before claiming you observed every retained change.
- `action invoke --revision` fails with `STALE_REVISION` when app state moved. Read fresh state before retrying.
- A repeated request ID returns the original response and does not run the command again.

For scripted checks, drive the CLI from Python and parse one JSON envelope per call. Shell variables that hold a whole command are not split into words in zsh:

```python
import json, subprocess
def run(*args):
    out = subprocess.run(["agentdevctl", "--session", "BUNDLE_ID", *args, "--json"], capture_output=True, text=True)
    return json.loads(out.stdout)   # check out.returncode against the documented exit codes
```

For a sandboxed app that publishes in its own container, select it by bundle ID with `--session BUNDLE_ID`, or put `--container BUNDLE_ID` before the command. `session list` does not scan containers. For App Group or paired loopback sessions, put `--app-group TEAMID.adk` or `--pairing-dir /absolute/private/folder` before the command. Use the same location for discovery and every later command. Discover again after a relaunch, because the session UUID rotates.

## UI inspection

When capabilities list `ui`, look at the real window before and after a change:

```sh
agentdevctl --session BUNDLE_ID ui capture --out window.png [--max-dimension 1600] [--format jpeg]
agentdevctl --session BUNDLE_ID ui tree --only-identified            # roles, identifiers, labels, frames
agentdevctl --session BUNDLE_ID ui tree --prefix button. --source appkit
agentdevctl --session BUNDLE_ID ui press --id button.send            # mutation sessions only
agentdevctl --session BUNDLE_ID operations list                      # open spans, age, progress
```

- `ui tree --source accessibility` (default) is the system accessibility tree. `appkit` walks AppKit accessibility objects, and `views` lists the view hierarchy with class names, for diagnosing layout and captures.
- Frames are `[x, y, width, height]` in window points from the top-left corner.
- A press runs the control's real action, but it does not prove hit testing or focus. Use XCUITest for that.
- Captures approximate glass: refraction and blur are not reproduced, and SwiftUI glass shapes draw without their fill. Check controls you cannot see with `ui tree`.

## Scaffold

`agentdevctl scaffold --app NAME [--bundle-id ID] [--out DIR] [--appkit]` writes a Testing target's files and prints the Xcode steps. It refuses to overwrite files unless you pass `--force`.

## MCP

Build with `swift build --package-path Tools/MCP --force-resolved-versions -c release`. This needs Swift 6.2 or later. Add `--show-bin-path` to find the executable directory. Register the absolute path of `agentdevkit-mcp` as a stdio server in the client the user already uses. For example, Claude Code:

```sh
claude mcp add agentdevkit -- /absolute/path/to/agentdevkit-mcp
```

For a container session, pass the bundle ID as `sessionId` or set `AGENTDEVKIT_CONTAINER`. For App Group or loopback sessions, set `AGENTDEVKIT_APP_GROUP` or `AGENTDEVKIT_PAIRING_DIR` in the server environment. Stdout carries only MCP frames.

Call `agentdevkit_session` first, then pass a `sessionId` (UUID or unique bundle ID) to the other tools as needed:

- `agentdevkit_capabilities`, `agentdevkit_prepare`, `agentdevkit_fixtures`, `agentdevkit_navigate`
- `agentdevkit_state`, `agentdevkit_observe`, `agentdevkit_wait`, `agentdevkit_events`
- `agentdevkit_diagnostics`, `agentdevkit_actions`, `agentdevkit_invoke`, `agentdevkit_operations`
- `agentdevkit_capture` (returns image content, so the model sees the window), `agentdevkit_ui_tree`, `agentdevkit_press`

Every tool accepts `timeoutMs`. The app answers `TIMEOUT` with its blockers and hints at that deadline; the client keeps reading for up to one more second so that answer survives a loaded machine. Tool errors carry the bridge error code in structured output. The CLI and the MCP tools are generated from one operation table, so their fields and defaults match.
