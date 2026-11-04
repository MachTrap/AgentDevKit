# Choose an evidence path

| Task | Setup and verification |
| --- | --- |
| Reproduce an editor or rendering bug | Prepare a fixture and deep route. Read the scoped state, then capture the actual window or inspect its AX hierarchy. Repeat at the same geometry and fixture after the fix. |
| Verify navigation, focus, or gesture behavior | Seed the fixture, then traverse the affected steps through actual UI input. Assert the resulting visible control or screen and whether it can be used. |
| Diagnose async work | Prepare or open without waiting, then use the named wait. Read recent diagnostics and event deltas if the wait fails. Follow lifecycle IDs and parent IDs to separate scenario submission, document work, and actual screen presentation. A document failure can settle work without making a screen ready. |
| Verify persistence | Use the real UI when testing Save clickability. Otherwise a registered semantic save can exercise the same model code. Relaunch the same isolated profile and read the resulting value. |

For AgentLab, a fresh launch creates an isolated temporary profile. Pass `--agentdevkit-profile UUID` on both launches when testing persistence. The test target also accepts `--agentdevkit-fixture FIXTURE` to seed a new profile for independent UI tests. The main test exercises the path from Projects through the Inspector and saves through its physical button.
