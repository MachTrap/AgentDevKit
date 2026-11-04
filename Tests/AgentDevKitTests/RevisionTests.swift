import AgentDevKitCore
import Testing

@Test func revisionPaginationAndOverflow() throws {
    var journal = RevisionJournal(capacity: 3)
    for _ in 0..<4 {
        journal.append(type: "changed", scope: "screen", changedFields: ["status"])
    }

    #expect(throws: Failure(
        .staleRevision, "The cursor fell behind retained events.",
        details: ["resyncRequired": true, "latestRevision": 4]
    )) {
        try journal.since(0)
    }

    let first = try journal.since(1, limit: 2)
    #expect(first.events.map(\.revision) == [2, 3])
    #expect(first.nextRevision == 3)
    #expect(first.latestRevision == 4)
    #expect(first.hasMore)
    let last = try journal.since(first.nextRevision)
    #expect(last.events.map(\.revision) == [4])
    #expect(!last.hasMore)
    #expect(try journal.since(4).events.isEmpty)
}

@Test func observationResyncsAndKeepsSnapshotSeparateFromPageCursor() throws {
    var journal = RevisionJournal(capacity: 2)
    for _ in 0..<3 {
        journal.append(type: "changed", scope: "screen", changedFields: ["status"])
    }
    let screen = ScreenState(screenId: "screen", windowId: "main", ready: true, revision: 3, scope: "current-screen")
    let expired = try StateObservation(screen: screen, journal: journal, request: .init(scope: screen.scope, sinceRevision: 0))
    #expect(expired.resynced)
    #expect(expired.delta == nil)
    #expect(expired.screen.revision == 3)
    let paged = try StateObservation(screen: screen, journal: journal, request: .init(scope: screen.scope, sinceRevision: 1, limit: 1))
    #expect(!paged.resynced)
    #expect(paged.delta?.nextRevision == 2)
    #expect(paged.delta?.hasMore == true)
    #expect(paged.screen.revision == 3)
}

@Test func lifecyclePairsAndRejectsDuplicateOrForeignTokens() throws {
    var journal = RevisionJournal()
    let startedScenario = journal.beginLifecycle(.scenario, name: "scenario.prepare", scope: "app")
    let scenario = try #require(startedScenario)
    let startedWork = journal.beginLifecycle(.work, name: "document.load", scope: "editor", parentId: scenario.id)
    let work = try #require(startedWork)
    var other = RevisionJournal()
    let foreignWork = other.beginLifecycle(.work, name: "document.load", scope: "editor", id: work.id)
    let foreign = try #require(foreignWork)
    let endedForeign = journal.endLifecycle(foreign, outcome: .failed)
    let endedWork = journal.endLifecycle(work, outcome: .completed)
    let endedWorkTwice = journal.endLifecycle(work, outcome: .completed)
    let endedScenario = journal.endLifecycle(scenario, outcome: .completed)
    #expect(!endedForeign)
    #expect(endedWork)
    #expect(!endedWorkTwice)
    #expect(endedScenario)
    let events = try journal.since(0).events
    #expect(events.map(\.type) == ["scenario.started", "work.started", "work.finished", "scenario.finished"])
    #expect(events[1].lifecycle?.id == events[2].lifecycle?.id)
    #expect(events[2].lifecycle?.parentId == scenario.id)
    #expect(events[2].lifecycle?.outcome == .completed)
    #expect(events[2].lifecycle?.durationMs != nil)
    #expect(journal.terminalLifecycle(work.id) == events[2].lifecycle)
}
