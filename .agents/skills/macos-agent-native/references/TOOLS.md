# Tool commands

Build the tools from the v0.7.0 checkout with `swift build -c release --product agentdevctl --product agentdevkit-desktop`, then use `.build/release/agentdevctl` or put it on your path. Tools and app must come from the same release line: v0.3 and later speak `agentdevkit/2`, and newer tools feature-detect through `capabilities.features`.

## Start the app

```sh
agentdevctl launch PATH/App-Testing.app --mutations --replace --wait screen.ready      # or --build SCHEME [--project P]
agentdevctl doctor PATH/App-Testing.app --expect-id main.toolbar                      # which startup stage failed
```

`launch` passes `--enable-agentdevkit` (plus `--allow-agentdevkit-mutations` with `--mutations`), `--agentdevkit-fixture ID`, `--agentdevkit-profile UUID`, `--language en` (`-AppleLanguages`/`-AppleLocale`) and repeatable `--arg`. It returns `{sessionId, pid, bundleId, buildFingerprint, profile}`. `--replace` quits a running instance first; `--background` does not activate the app. `doctor` checks, in order: bundle and signature, process, opt-in flags, published session, authentication, a visible window, and an expected element. It stops at the first failure with a remedy.

## Select the session once

`--session` takes a UUID or a bundle ID that matches one session. Without it, the tools use `$AGENTDEVKIT_SESSION`, then the nearest `.agentdevkit.json` (`{"session": "com.example.app.testing"}`). `session list` marks the default. `--session=ID` works too, and so does a variable holding `--session ID`, even in zsh.

```sh
export AGENTDEVKIT_SESSION=com.example.app.testing
agentdevctl capabilities --json          # routes, fixtures, scopes, actions, conditions, invariants, experiments, features, limits
```

## Set up, read and wait

```sh
agentdevctl scenario prepare --fixture large-project-v1 --route projects.editor.inspector --context '{"nodeId":"node-42"}'
agentdevctl state --field phase                     # raw value; exit 4 when absent; dotted paths reach nested values
agentdevctl state --fields phase,queueCount         # one JSON object keyed by path
agentdevctl wait --until 'phase=results'            # state.field_equals; VALUE is JSON or bare text
agentdevctl wait --until screen.ready               # any condition name; camelCase spellings resolve
agentdevctl wait --operation UUID                   # operation.completed
agentdevctl observe --since REVISION                # state, events and invariant violations since REVISION
```

- Errors for unknown conditions, routes, fixtures, actions, scopes and experiments list `validNames`, the `closest` name and a runnable `example`. The CLI prints "Did you mean …?" and the example.
- A parse error prints only that command's usage. `agentdevctl help COMMAND` lists its options.
- `wait --timeout-ms` accepts up to 120000 and splits into requests within `limits.maxTimeoutMs`. `--every-ms` sets the request length. `--no-fail-on-timeout` returns `satisfied: false` with blockers.
- **Exit codes:** 2 invalid input · 3 session or connection · 4 app failure or failed check · 5 timeout · 6 version or identity mismatch.

## Long-running and UI-presenting work

`fixtures load`, `scenario prepare` and `action invoke` answer `accepted` with an `operationId` when the work outlasts the request deadline. Actions that open panels (`presentsUI` in `actions list`) always do. Add `--wait` to follow the operation to its final result.

```sh
agentdevctl fixtures load --fixture real-scan-v1 --wait
agentdevctl operations list                              # open spans; awaitingUser while a panel or sheet waits
agentdevctl operations status --operation UUID           # pending | completed (revision, result) | failed (code, reason) | cancelled | unknown
agentdevctl ui dismiss [--item ok]                       # close the front sheet, panel, alert or popover
```

While tracked work runs, other mutations get a retryable `CONFLICT` naming its operation. If a connection drops during a mutation, the tools ask `operations.status` with the same request ID and report "applied at revision N", "still running", or "not applied, safe to retry".

## Look at and drive the UI

```sh
agentdevctl ui surfaces                                  # windows, sheets, popovers, panels, alerts, open menus
agentdevctl ui capture --out ui.png                      # main window plus every sheet, popover and alert above it
agentdevctl ui capture --mode window | --surface ID      # one window, or one surface
agentdevctl ui snapshot --out ui.png --json              # image, tree and revision from one main-actor turn
agentdevctl ui tree --lint                               # values, min/max/step, actions, paths, identifier problems
agentdevctl ui press --path 'cleanupQueue/queueRow[3]/checkbox' | --role checkbox --label Downloads
agentdevctl ui set --id map.detail --value 2             # slider, stepper, checkbox (true/false) or text
agentdevctl ui choose --id density --item Detailed       # pop-up or SwiftUI Menu, without leaving it open
agentdevctl ui expand --role disclosuretriangle --label Advanced
agentdevctl ui key --keys "Down Down Return"             # in-process key events to the key window
agentdevctl ui hover --id row.downloads                  # synthesized pointer: hover cards, tooltips
agentdevctl ui scroll --id list --dy 400
```

- `ui press --id` fails with `AMBIGUOUS_ELEMENT` and lists paths when several elements share an identifier. `ui tree --lint` shows identifiers SwiftUI copied from a container onto its children, and the `.accessibilityElement(children: .contain)` fix.
- Locators search the main window and the surfaces above it; pass `--window ID` from `ui surfaces` to target one.
- `--revision N` on `ui capture` and `ui tree` fails with `STALE_REVISION` if state moved.
- Captures report `approximations`: `glassEffect` (Liquid Glass approximated), `popoverChrome`, and `remoteContent` for open and save panels, whose content another process draws and which a capture cannot show.
- Evidence labels: `ui press`, `ui perform` → `accessibility` (control exists, is enabled, responds); `ui key/hover/scroll` → `in-process` (the app's handlers ran); `agentdevctl desktop …` → `desktop` (real system events). None replaces XCUITest for hit testing.

## Regression evidence

```sh
agentdevctl recipe run recipes/queue-map.json [--repeat 10]      # setup, steps, bursts, waits, assertions; exit 4 on failure
agentdevctl recipe record start --file draft.json  …  agentdevctl recipe record stop
agentdevctl invariants [--watch]                                # app invariants: holds, violations with revisions, cost
agentdevctl ui capture --baseline 'shots/main-{locale}-{appearance}.png' [--threshold 0.01] [--update-baseline]
agentdevctl audit-release PATH/App.app [--forbid AgentDevKit,TestingSession]   # shipping build: no symbols, no session
```

A recipe failure reports the round, step, expected and observed values, revision, and a folder with `capture.png`, `tree.json` and `state.json`. Recipe steps: `action`, `perform`, `press`, `key`, `hover`, `scroll`, `wait`, `assert` (`field` with `equals`, `contains`, `greaterThan` …; `element`; `invariants`), `burst` (sent back to back), `ask`, `capture` (`baseline`), `navigate`, `fixture`, `sleep`, `note`. Top-level `invariants: "hold"` fails a round that violated one.

## People, probes and permissions

```sh
agentdevctl operator ask --question "Did a dialog appear?" --options Yes,No --wait   # a person answers in a labelled Testing panel
agentdevctl experiment run --id probe.stat --args '{"path":"Downloads"}'            # recorded under diagnostics category experiment
agentdevctl tcc status                                     # what the app observes: Full Disk Access probe, Accessibility, Screen Recording
agentdevctl tcc reset --bundle com.example.app.testing --service MediaLibrary       # Testing bundles only; prints what it cannot reset
agentdevctl desktop check | click --id X | drag --from-id A --to-id B | key --keys "Tab Tab"   # needs the runner's Accessibility grant
```

`tccutil` at user level cannot reset Full Disk Access, Accessibility, Screen Recording or Input Monitoring; the person removes those in System Settings → Privacy & Security.

## Scaffold

`agentdevctl scaffold --app NAME [--bundle-id ID] [--out DIR] [--appkit]` writes a Testing target's files and prints the Xcode steps. It refuses to overwrite files unless you pass `--force`.

## MCP

Build with `swift build --package-path Tools/MCP --force-resolved-versions -c release` (Swift 6.2 or later) and register the absolute path of `agentdevkit-mcp` as a stdio server, for example `claude mcp add agentdevkit -- /absolute/path/to/agentdevkit-mcp`. Set `AGENTDEVKIT_SESSION` in the server environment to skip `sessionId`; `AGENTDEVKIT_CONTAINER`, `AGENTDEVKIT_APP_GROUP` or `AGENTDEVKIT_PAIRING_DIR` select another location. Stdout carries only MCP frames.

Every CLI operation is one tool, `agentdevkit_<name>`, generated from the same table (`agentdevctl --tools-markdown` prints it): `session`, `capabilities`, `prepare`, `fixtures`, `navigate`, `state` (`fields`), `observe`, `wait` (`until`, `everyMs`), `events`, `diagnostics`, `operations`, `operation_status`, `actions`, `invoke` (`wait`), `capture` and `ui_snapshot` (image content), `ui_surfaces`, `ui_tree`, `press`, `ui_perform`, `ui_key`, `ui_hover`, `ui_scroll`, `invariants`, `operator_ask`, `operator_answer`, `experiment`, `privacy_status`. Every tool accepts `sessionId` and `timeoutMs`. Tool errors carry the bridge error code and its `details`.
