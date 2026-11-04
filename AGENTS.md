# Repository-level Handoff Instructions for Coding Agents

You are implementing **AgentDevKit**, a developer-only automation and observability framework for native macOS apps, plus a reusable Agent Skill and a working sample app. The authoritative product scope is [docs/00_PRODUCT_SCOPE.md](docs/00_PRODUCT_SCOPE.md); architecture is [docs/01_ARCHITECTURE.md](docs/01_ARCHITECTURE.md).

## Priorities

1. Deliver a **real buildable Swift package** and **real runnable AgentLab**. Documentation or protocol-only simulation is not completion.
2. Keep app integration small, typed, explicitly opted-in, and modular. Do not invade app feature code unnecessarily.
3. Implement the highest-leverage developer features first: connect, capabilities, navigate, fixtures, scoped state, idle, diagnostics, and CLI.
4. Make the agent skill operational for both a new repo and an **existing** SwiftUI/AppKit app. Integration should be additive, reversible, with minimal dependencies.
5. Demonstrate proof from a real running window and from independent UI automation / XCUITest where feasible.

## Ground rules

- Read only the relevant docs for the current phase; avoid loading every file into context for a small change.
- Implement one vertical slice completely (host → IPC → client → CLI → test) before another domain.
- No mock responses in end-to-end acceptance results. Tag any protocol/sample payloads clearly if illustrative.
- `AgentDevKitHost` must be explicitly excluded from Release targets/configurations. `DEBUG` alone is not an adequate shipping guarantee. Validate with Release build inspection.
- Use Swift 6 strict concurrency. UI/state adapters run on `MainActor` as appropriate; transport and event buffers are isolated actors. Do not block main thread while waiting for UI.
- All commands are allowlisted, validated, size-bounded, time-bounded and auditable; fixture mutation is restricted to isolated test storage.
- Never send log messages to stdout from `agentdevkit-mcp` (stdout is the stdio MCP transport); use stderr or a file.
- The protocol and Swift APIs in these docs are **design contracts**, not assertions that code already exists.
- Avoid implementing generic reflective access to arbitrary private Swift properties. App adapters explicitly expose safe snapshots.
- If platform limitations prevent a requirement, implement the best demonstrable substitute and document the exact limitation. Never claim unobserved build/test success.

## Working sequence

- Verify Swift/Xcode availability and supported macOS. If running on Linux, implement platform-neutral core/tests only and clearly mark GUI verification as blocked.
- Build minimal AgentLab; add debug-only host, authenticated connection, and ping.
- Add capabilities and typed state/navigation/fixtures; prove each with in-app behavior.
- Add wait, revisioned events, diagnostics, and safe actions.
- Add MCP sidecar, executable CLI, skill, integration guides and regression coverage.
- Run debug and release builds, unit/integration tests, real UI checks, security-negative tests; record evidence.

## Completion report

Use the [acceptance checklist](docs/10_ACCEPTANCE_CRITERIA.md) to find outstanding requirements and the [verification record](docs/13_IMPLEMENTATION_STATUS.md) to locate existing evidence.

Provide: implemented items, exact build/test commands and outcomes, real app screenshots or inspector evidence, protocol compatibility, limitations, Release exclusion proof, and next work. Separate verified from unverified items.

## Skill lifecycle

The repository contains `.agents/skills/macos-agent-native/SKILL.md`. This is the *deliverable skill*, not a replacement for the current implementation task. Keep it concise and operational; reference detailed files only on demand. Ensure its actual instructions match the implemented CLI/MCP contracts before declaring completion.

## Instrument new feature boundaries during development

- For each new navigable screen, agree on its route, context keys, window identity, scoped state, accessibility IDs, and what must be true before it is ready.
- Pair screen entry and exit at actual presentation and departure. Pair finite work and approved scenarios at their owning service or coordinator, including failure, cancellation, and replacement.
- Use static lifecycle names and instance IDs. Preserve request and parent correlation when an operation starts from a bridge command. Keep user content and secrets out of the trace.
- Verify the happy path and one relevant terminal path while implementing the feature. Keep external UI assertions separate from model evidence.
