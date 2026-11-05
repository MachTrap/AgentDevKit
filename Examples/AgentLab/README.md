# AgentLab

AgentLab is a native SwiftUI project organizer and editor that demonstrates AgentDevKit. Its Projects list, editor, Inspector, project details sheet, and Appearance settings are used by both ordinary UI navigation and the Testing bridge.

## Run

The Testing integration is three files: `AgentIntegration/LabAdapter.swift` (the `AgentAdapter` and `AgentCatalog`), `LabEvents.swift` (model changes to events and spans) and `TestingSession.swift` (launch options, isolated `TestingProfile` storage and the `AgentSession`).

Follow the [quick start](../../README.md#quick-start) from the repository root. Use the `AgentLab-AgentTesting` scheme for bridge sessions. The ordinary Debug and Release targets exclude the bridge. Testing fixtures use isolated storage. Pass `--agentdevkit-profile UUID` to reopen the same test profile.

## Controls, recipes and invariants

**Settings → Controls** is a disk-cleanup style screen for v0.6 and v0.7: a map-detail slider in a popover (`controls.display`, `controls.detail`), a SwiftUI menu (`controls.density`), a disclosure (`controls.advanced`), a cleanup queue whose rows deliberately copy `queueRow` onto their checkboxes (find it with `ui tree --lint`), a map of folders, arrow-key navigation, a hover card, and an Import… button that opens an open panel (`controls.import`, a `presentsUI` action). Testing-only extras: the `queue.toggle` and `controls.seedMapBug` actions, the `queue.mapConsistent` invariant, the `probe.stat` experiment, operator prompts, and the `slow-fixture-v1` (5 s) and `files-v1` (a generated home folder, `AgentDevKitFixtures`) fixtures. `recipes/queue-map.json` passes; `recipes/queue-map-seeded-failure.json` fails on purpose at its sixth step. `scripts/check-live-v07.py` exercises all of it.

## Sandboxed Testing

Build from the [v0.7.0 source tag](https://github.com/MachTrap/AgentDevKit/tree/v0.7.0) using the installation steps in the root README. Both schemes require `--enable-agentdevkit` on every launch. Add `--allow-agentdevkit-mutations` for fixture and route commands. The app starts read-only by default.

To build and sign from a shell, choose the development identity and the team it belongs to. Set `lane=AppGroup` or `lane=Loopback`. This uses the same entitlements as the Xcode targets.

```sh
team=TEAMID
identity=SIGNING_IDENTITY_SHA1
lane=AppGroup
scheme="AgentLab-${lane}Testing"
output="$PWD/.build/$scheme"
xcodebuild -project Examples/AgentLab/AgentLab.xcodeproj -scheme "$scheme" \
  -destination 'platform=macOS' -derivedDataPath "$output" \
  DEVELOPMENT_TEAM="$team" CODE_SIGN_IDENTITY=- build
app="$output/Build/Products/Debug/$scheme.app"
codesign -d --entitlements :- "$app" > "$output/entitlements.plist"
codesign --force --sign "$identity" --entitlements "$output/entitlements.plist" "$app"
codesign --verify --strict "$app"
open -n "$app" --args --enable-agentdevkit
```

### Same-team App Group

Use `AgentLab-AppGroupTesting`. Set its **Development Team** and use the same team when signing the CLI and MCP sidecar. The default group is `TEAMID.adk`. Override `AGENTDEVKIT_APP_GROUP` in the target build settings if needed. Prefer a short name because Darwin limits the entire Unix socket address to 103 UTF-8 bytes. Keep the app's Info.plist identifier and App Group entitlement in sync. [Apple's App Group requirements](https://developer.apple.com/documentation/xcode/accessing-app-group-containers)

Build both tools from source as described in the root README. Use a separate copy for signed App Group tooling. Use an Apple Development signing identity from the app's team, available in `security find-identity -v -p codesigning`.

```sh
group=TEAMID.adk
identity=SIGNING_IDENTITY_SHA1
mkdir -p .build/group-tools
cp .build/release/agentdevctl .build/group-tools/
cp Tools/MCP/.build/release/agentdevkit-mcp .build/group-tools/
cat > .build/group-tools/entitlements.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>com.apple.security.application-groups</key><array><string>${group}</string></array>
</dict></plist>
EOF
for tool in agentdevctl agentdevkit-mcp; do
  codesign --force --sign "$identity" --entitlements .build/group-tools/entitlements.plist ".build/group-tools/$tool"
  codesign --verify --strict ".build/group-tools/$tool"
done
.build/group-tools/agentdevctl --app-group "$group" session list --json
```

Set `AGENTDEVKIT_APP_GROUP` to that group and use the signed sidecar's absolute path in the MCP client's stdio server settings.

### Paired loopback

Use `AgentLab-LoopbackTesting` with Xcode 26 or later. Its identity generator uses the public Security SDK declaration of `SecIdentityCreate`. Its entitlements allow incoming connections and access to a selected folder. It generates a fresh development identity in memory using the example's separate [DevelopmentIdentity package](DevelopmentIdentity/Package.swift). Tools can use their usual signatures and need no App Group entitlement.

```sh
mkdir -m 700 "$HOME/AgentDevKitPairing"
agentdevctl --pairing-dir "$HOME/AgentDevKitPairing" session list --json
```

On the first enabled launch, select that directory in the app's folder panel before running the CLI. Set `AGENTDEVKIT_PAIRING_DIR` to its absolute path for the MCP sidecar. Quit and relaunch the app with the same enable flag. Discover the new UUID using the same folder. If the bookmark is stale or access has been revoked, use **Pair Folder…** to select a private directory again. **Forget Pairing** ends the running bridge and clears the Testing app's bookmark.

### Verify a signed desktop run

- Inspect both app signatures with `codesign -d --entitlements - APP`. Verify that the App Group app has no network entitlement and that the loopback app has no App Group entitlement.
- In each lane, launch read-only and run `python3 scripts/check-live-bridge.py SESSION_ID --cli TOOL --app-group GROUP` or the equivalent with `--pairing-dir FOLDER`. The script also checks TLS pin rejection and non-loopback binding in the loopback lane.
- Relaunch with mutations enabled and use `scripts/check-live-mcp.py SESSION_ID --cli TOOL --mcp SIDECAR` with the corresponding MCP environment variable. Confirm the Inspector in the running window independently of the returned model.
- For loopback, repeat the launch three times after the first pairing. Confirm the panel stays closed, UUIDs and pins rotate, and the tools continue working with the same folder. Check **Forget Pairing**, a stale descriptor after a crash, and a folder whose access was revoked.
- Record the macOS version, the build and verification commands, and observed outcomes before releasing.

The signed lanes were last verified on v0.2 with macOS 27.2 and Xcode 27.2. v0.3 builds both lanes, but their signed desktop run is still pending. In the v0.2 run, both lanes passed the CLI and MCP probes. External Accessibility showed `screen.editor.inspector`, `field.node.name` and `button.inspector.save` for Node 42 in each window. Loopback passed three relaunches with the same folder using tools signed by a different team. The deployment target is macOS 14.0.

## Navigate and verify

| Route | Context | Destination |
| --- | --- | --- |
| `home` | Empty | Main overview |
| `projects.list` | Empty | Search and create projects |
| `projects.editor` | `projectId` | Project details and nodes |
| `projects.editor.inspector` | `projectId`, optional `nodeId` | Selected node, editable metadata and Save |
| `settings.advanced.appearance` | Empty | Theme and accent preview, Save and Reset |

Run `agentdevctl capabilities --json` for the installed route, fixture, action and accessibility identifiers. The [scenario guide](SCENARIOS.md) covers composed setup, ordinary UI navigation, persistence, failure recovery and timing.

Run the UI suite from the repository root:

```sh
xcodebuild -project Examples/AgentLab/AgentLab.xcodeproj \
  -scheme AgentLab-AgentTesting -destination 'platform=macOS' \
  -derivedDataPath .build/AgentLab test
```

## Inspector layout regression

The default Inspector wraps a long title. The Testing-only `--agentdevkit-legacy-overflow` flag reproduces the one-line truncation with the same model value. XCUITest captured the [legacy window](images/inspector-legacy.png) and the [fixed window](images/inspector-fixed.png).
