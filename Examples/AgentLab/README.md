# AgentLab

AgentLab is a native SwiftUI project organizer and editor that demonstrates AgentDevKit. Its Projects list, editor, Inspector, project details sheet, and Appearance settings are used by both ordinary UI navigation and the Testing bridge.

## Run

Follow the [quick start](../../README.md#quick-start) from the repository root. Use the `AgentLab-AgentTesting` scheme for bridge sessions. The ordinary Debug and Release targets exclude the bridge. Testing fixtures use isolated storage. Pass `--agentdevkit-profile UUID` to reopen the same test profile.

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

The default Inspector wraps a long title. The Testing-only `--agentdevkit-legacy-overflow` flag reproduces the one-line truncation with the same model value. XCUITest captured the [legacy window](images/inspector-legacy.png) and the [fixed window](images/inspector-fixed.png). See the [verification record](../../docs/13_IMPLEMENTATION_STATUS.md) for test and build evidence.
