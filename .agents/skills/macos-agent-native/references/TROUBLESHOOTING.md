# Diagnose bridge and UI access

- **No session.** Confirm that the actual Testing build is running, its opt-in argument was supplied, and its bridge status is active. A Release build cannot publish a session. A crashed or relaunched process needs a fresh discovery result.
- **Sandbox source unavailable.** Confirm the source used by the running app. For an App Group, inspect both signatures and check the exact entitlement and socket path length. For loopback, verify the folder is accessible and owner-only, then use the app’s pairing UI again if its bookmark is stale. Never bypass certificate pinning.
- **Multiple sessions or changed app.** Select the exact current UUID. Verify the bundle ID and build fingerprint. Re-discover after rebuilding or relaunching.
- **Permission denied.** Use read-only observations unless a test mutation is authorized. Confirm the isolated store and mutation opt-in. Never copy credentials into arguments or logs.
- **Route or fixture unavailable.** Use capabilities from the selected session. If the app lacks the adapter, choose ordinary UI setup or add the smallest typed adapter within the requested scope.
- **Timeout.** Inspect reported blockers and recent diagnostics. A timed-out route may already have changed app state. Take a snapshot before retrying a mutation.
- **GUI or AX unavailable.** Run the existing build, unit, or bridge checks and identify which UI evidence remains unavailable. Use regular Xcode/XCUITest or an authorized accessibility tool when the host supports it.
