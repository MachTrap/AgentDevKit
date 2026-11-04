# AgentLab — Deterministic Scenarios and Acceptance Cases

## Fixtures

| ID | Contents | Used for |
| --- | --- | --- |
| `empty-projects-v1` | no projects | empty UI/disabled controls |
| `basic-project-v1` | one project, three nodes | basic editor navigation and save |
| `large-project-v1` | 1 project with 200 nodes | scroll, selection, deterministic performance |
| `long-node-names-v1` | project with very long node name/notes | Inspector overflow/visual regression |
| `network-error-v1` | known project + simulated document load failure | error UI, diagnostics |
| `slow-project-v1` | project with a 1.2-second document load | wait timeout and completion |

Fixture IDs and entities returned by fixture load must remain deterministic across repeated resets. Avoid dynamic timestamps in asserted visible text unless frozen by test clock.

## Scenario A — Fast deep-screen reproduction

**Setup:** AgentLab-AgentTesting running, fixture `long-node-names-v1`; target route `projects.editor.inspector` with returned project/node IDs.

**Actions:** run `scenario.prepare` with fixture+route+wait, get scoped snapshot; inspect actual visible Inspector via AX/XCUITest and screenshot.

**Expected:** real Inspector displayed, correct selected node in snapshot, full name present in model state; visual variant demonstrates clipping and fixed layout demonstrates correct rendering. If no external view inspection occurred, record state-only status.

**Pass:** single composed API setup succeeds, independent UI shows target, visual difference is real and reproducible.

## Scenario B — Full user navigation

**Setup:** same fixture and reset; app at Home, no direct route to Inspector after initial setup.

**Actions:** click Projects, open project row, Editor, select node, click Inspector. Verify appropriate route/window and visible controls. Use XCUITest or external AX, not semantic `navigation.open` for the transitions.

**Expected:** user can traverse complete path and reach same selected Inspector. Compare target state with Scenario A.

**Pass:** all real user transitions and controls work; no hidden intermediate failure.

## Scenario C — Settings save persists

**Setup:** fixture `basic-project-v1`, route `settings.advanced.appearance`.

**Actions:** change theme via actual toggle/picker, verify UI dirty state and Save enabled; click Save physically; wait; relaunch AgentTesting app with same isolated store and check theme persisted.

**Expected:** save persists, action/log revisions reflect change, no unhandled errors.

**Pass:** runtime, UI and storage agree. A direct semantic `actions.invoke` may be used as an extra comparison but cannot replace physical Save.

## Scenario D — Async work without sleeps

**Setup:** fixture `basic-project-v1`; injected document load takes a bounded deterministic interval.

**Actions:** open editor; `runtime.wait(screen.ready)` with explicit timeout; inspect pending blockers before completion if supported, then completion status.

**Expected:** no fixed sleep needed; readiness not claimed before real editor content is usable.

**Pass:** target active and UI check passes; timeout path returns useful blockers when deliberately slowed beyond deadline.

## Scenario E — Network error and recovery

**Setup:** `network-error-v1` and editor route.

**Actions:** trigger documented load failure, wait for error state, check visible error/retry UI and `diagnostics.recent`; restore service scenario and hit Retry via actual UI.

**Expected:** error code and correlated diagnostic, test-only data, retry succeeds and UI becomes ready.

**Pass:** no endless spinner or misleading `ready=true`.

## Scenario F — Revision overflow and resync

**Setup:** app with bounded event buffer.

**Actions:** generate more registered changes than ring capacity using safe testing operations; request delta from very old revision.

**Expected:** `STALE_REVISION` with `resyncRequired`, not incomplete data represented as comprehensive. Fresh `state.snapshot` returns new cursor.

**Pass:** client resynchronizes correctly and continues.

## Scenario G — Unauthorized access and Release safety

**Setup:** AgentTesting and Release builds.

**Actions:** send malformed/unauthorized frame to testing socket; verify rejection. Build/launch Release and attempt session discovery and connection.

**Expected:** no private data from unauthorized call; Release does not expose bridge/fixture commands and doesn't link debug host.

**Pass:** tests + binary/build evidence prove separation.

## Scenario H — Efficiency benchmark

**Compare:** same destination and fixture via (1) user-path click traversal and (2) `scenario.prepare`.

**Record:** 3+ runs each, wall time, number of agent tool calls, screenshot count, response bytes, failures. Test on same machine/app build/window size; note if independent visual verification still required.

**Pass:** measurements documented without invented percentage. Efficiency is a design target, not a promise.

### Reproduce the Inspector layout comparison

Launch AgentLab-AgentTesting with `--agentdevkit-fixture long-node-names-v1` and traverse Projects → the fixture project → its first node. Add `--agentdevkit-legacy-overflow` to a separate Testing launch to show the one-line title. The default title wraps. Both launches use the same node data. The XCUITest `testInspectorLongTitleRegression` checks both and attaches actual window screenshots and accessibility geometry. The measured route comparison and exact commands are in the [implementation evidence](../../docs/13_IMPLEMENTATION_STATUS.md).
