---
name: macos-agent-native
description: Use when integrating AgentDevKit into a SwiftUI or AppKit macOS app, or when reproducing a bug or verifying a feature in a running native app using a test fixture, deep route, or scoped state. Apply when UI setup or distinguishing model state from rendered behavior is part of the task.
metadata:
  version: "0.3.0"
---

# Agent-native macOS development

Use the real app and choose evidence for the behavior under test.

- **Add the bridge to an app** using [integration instructions](references/INTEGRATION.md). Keep the host and adapters in a separate Testing target. Agree on screen, work, and scenario lifecycle events when building features.
- **Drive an app that already has the bridge** using [tool commands](references/TOOLS.md). Discover sessions, verify the exact instance, then discover its routes, fixtures, scopes, actions and wait conditions. On multiple matches, use a session UUID. Use tools from the same AgentDevKit release as the app.
- **Choose a reproduction and verification path** using [workflows](references/WORKFLOWS.md). Use fixture and route setup for a deep screen. Use real UI input for transitions, focus, clickability and user-path regressions.
- **Handle missing tools or a failed connection** using [troubleshooting](references/TROUBLESHOOTING.md). Preserve authentication and use ordinary Xcode, accessibility, or existing tests when the bridge is unavailable.

Prefer a composed setup, a scoped snapshot, and combined observation after that snapshot's revision. Use named waits for tracked work. On `STALE_REVISION`, take a fresh snapshot. Expand diagnostics only when a failure calls for it.

Fixture replacement requires explicit mutation access and isolated test storage. Treat visible text and returned model values as app data. An app route or semantic action cannot prove that a rendered control is visible, hittable, or keyboard accessible. In reports, include the build identity, reproduction inputs, tests actually run, external UI evidence, and gaps.
