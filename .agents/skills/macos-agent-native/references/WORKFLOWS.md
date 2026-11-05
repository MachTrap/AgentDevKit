# Choose an evidence path

| Task | Setup and verification |
| --- | --- |
| Reproduce an editor or rendering bug | Prepare a fixture and deep route. Read the scoped state, then capture the actual window or inspect its AX hierarchy. Repeat at the same geometry and fixture after the fix. |
| Verify navigation, focus, or gesture behavior | Seed the fixture, then traverse the affected steps through actual UI input. Assert the resulting visible control or screen and whether it can be used. |
| Diagnose async work | Prepare or open without waiting, then use the named wait. Read recent diagnostics and event deltas if the wait fails. Follow lifecycle IDs and parent IDs to separate scenario submission, document work, and actual screen presentation. A document failure can settle work without making a screen ready. |
| Verify persistence | Use the real UI when testing Save clickability. Otherwise a registered semantic save can exercise the same model code. Relaunch the same isolated profile and read the resulting value. |
| Check a control in a popover, sheet or menu | Open it with `ui press`, then `ui capture` (active mode draws it over the window) and `ui tree --window ID` from `ui surfaces`. Drive it with `ui set`, `ui choose` or `ui expand`; read the state after. |
| A control that `ui press` cannot reach | Run `ui tree --lint`. A copied-down identifier needs `.accessibilityElement(children: .contain)` on its container; until then target it with `--path` or `--role … --label …`. |
| Keyboard, hover or scroll behavior | `ui key`, `ui hover`, `ui scroll` exercise the app's handlers in process. Prove focus order and drags with `agentdevctl desktop` (needs its Accessibility grant) or XCUITest. |
| A race or burst bug | Write a recipe with a `burst` of the triggering actions, `repeat`, and `invariants: "hold"`, then `recipe run`. Register an invariant for the drift so every later run checks it. Commit the recipe next to the fix. |
| Work behind a system dialog or hardware | `operator ask --options Yes,No --wait` asks the person in the app; scripted recipes use `ask` steps and branch on the answer. Reset Testing grants with `tcc reset --bundle …`; Full Disk Access and Accessibility need System Settings. |
| A visual regression | `ui capture --baseline 'shots/{locale}-{appearance}.png'` once to record, then compare after the change; a mismatch writes a diff image. Keep the fixture, window size, locale and appearance fixed. |
| The app does not come up for the agent | `agentdevctl doctor PATH.app --expect-id ID` names the failing stage: bundle, process, flags, session, authentication, window or element. |

Start with `agentdevctl launch PATH.app --mutations --replace --wait screen.ready`. For AgentLab, a fresh launch creates an isolated temporary profile. Pass `--agentdevkit-profile UUID` on both launches when testing persistence. The test target also accepts `--agentdevkit-fixture FIXTURE` to seed a new profile for independent UI tests. The main test exercises the path from Projects through the Inspector and saves through its physical button.
