# Read-only AppKit adoption

The app displays the selected document using its existing `NSWindowController` and native controls. The Testing adapter reads the same selection through AgentDevKit. The normal app target builds the same controller and UI without the adapter source or package products.

Build from the repository root:

```sh
swift build --product agentdevctl
project=Examples/AppKitAdoption/AppKitDocuments.xcodeproj
xcodebuild -project "$project" -scheme AppKitDocuments-AgentTesting \
  -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/AppKitAdoption build
xcodebuild -project "$project" -scheme AppKitDocuments \
  -configuration Release -destination 'platform=macOS' -derivedDataPath .build/AppKitAdoption build
python3 Examples/AppKitAdoption/verify.py
```

The verifier uses a local GUI session and Accessibility permission. It presses the existing Review button and reads the visible label. Then it compares the Testing app's snapshot, checks the opt-in and Release boundaries, and closes the real window to verify graceful endpoint cleanup.

To inspect interactively, run the Testing scheme in Xcode with the `--enable-agentdevkit` launch argument, or use:

```sh
open -n "$PWD/.build/AppKitAdoption/Build/Products/Debug/AppKitDocuments-AgentTesting.app" \
  --args --enable-agentdevkit
.build/debug/agentdevctl --session dev.agentdevkit.AppKitDocuments.Testing state --scope selected-document --json
```

`TestingBridge.swift` is a 31-line `AgentAdapter`: one `snapshot(scope:)`, an `AgentRuntime.record` call from the controller's selection callback, and an `AgentSession` that handles opt-in and graceful termination. The library serves state, observe, events, diagnostics and waits. The adapter exposes only a document ID, has no fixture or action, and does not open windows when taking a snapshot. For integration in another app, copy the target separation and delegate wiring, and adapt the read-only scope to the app's existing model.
