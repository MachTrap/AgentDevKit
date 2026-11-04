# Tool commands

Build the core package from the v0.2.0 checkout with `swift build --product agentdevctl`. Use the resulting `.build/debug/agentdevctl` or put it on your path. A Testing app must be running with its bridge explicitly enabled. AgentLab uses `--enable-agentdevkit`; to permit fixture, route, and save commands, also pass `--allow-agentdevkit-mutations`.

```sh
agentdevctl session list --json
agentdevctl --session SESSION_ID session ping --json
agentdevctl --session SESSION_ID capabilities --json

agentdevctl --session SESSION_ID scenario prepare \
  --fixture large-project-v1 --route projects.editor.inspector \
  --context '{"nodeId":"node-42"}' --wait-ready --json
agentdevctl --session SESSION_ID state --scope current-screen --json
agentdevctl --session SESSION_ID wait --condition screen.ready --timeout-ms 1500 --json
agentdevctl --session SESSION_ID observe --since REVISION --limit 20 --json
agentdevctl --session SESSION_ID events since --revision REVISION --limit 20 --json
agentdevctl --session SESSION_ID diagnostics recent --severity error --limit 10 --json
agentdevctl --session SESSION_ID actions list --json
agentdevctl --session SESSION_ID action invoke --id inspector.save \
  --args '{"name":"Verified test edit"}' --revision REVISION --json
```

AgentLab's route and fixture names are examples. Discover the actual target app's capability names. For standalone setup, use `fixtures load --fixture ID` or `navigation open --route ID`. Pass `--no-wait` to return an accepted transition and use the returned operation ID with `wait --condition operation.completed --operation UUID`. Use `wait --condition lifecycle.ended --operation UUID` to retrieve a retained span outcome after navigating elsewhere. The current wire maximum is 2 seconds per command.

Use `observe` when you need both state and changes. A response with `resynced: true` supplies a fresh baseline. For paginated changes, continue with the delta's `nextRevision`. If `hasMore` is true, continue before claiming to have observed all retained changes. A stale cursor requires a fresh snapshot. A save with `--revision` fails with `CONFLICT` when the app state has moved.

For a sandboxed session, put `--app-group TEAMID.adk` or `--pairing-dir /absolute/private/folder` before the command. Use the same source for discovery and later commands. Discover again after relaunch because the session UUID rotates.

## MCP

Build with `swift build --package-path Tools/MCP --force-resolved-versions -c release`. Use the absolute path to the built `agentdevkit-mcp` in the client's stdio server settings. The current lockfile requires Swift 6.2. Configure either `AGENTDEVKIT_APP_GROUP` or `AGENTDEVKIT_PAIRING_DIR` in the stdio server environment for sandboxed sessions. To locate the executable directory, add `--show-bin-path` to the build command.

Use `agentdevkit_session` first and pass the returned `sessionId` to subsequent tools. Then use `agentdevkit_capabilities`, `agentdevkit_prepare`, `agentdevkit_navigate`, `agentdevkit_state`, `agentdevkit_observe`, `agentdevkit_wait`, `agentdevkit_events`, `agentdevkit_diagnostics`, `agentdevkit_actions`, or `agentdevkit_invoke` as needed. Tool errors carry bridge codes in structured output. The MCP client's tool discovery is the schema reference.
