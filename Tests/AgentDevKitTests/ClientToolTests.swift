import AgentDevKitClient
import AgentDevKitCore
import AgentDevKitFixtures
import AppKit
import Foundation
import Testing

/// Client-side v0.6 behavior that needs no live host: suggestions, session defaults, field projection,
/// `--until`, recipe validation, visual diffs and file-tree fixtures.
@Suite struct ClientToolTests {
    // MARK: Suggestions

    @Test func suggestionsNormalizeCaseAndUnderscores() {
        let valid = ["screen.ready", "work.quiescent", "state.field_equals"]
        #expect(NameSuggestions.alias("state.fieldEquals", in: valid) == "state.field_equals")
        #expect(NameSuggestions.alias("Screen.Ready", in: valid) == "screen.ready")
        #expect(NameSuggestions.alias("state.equals", in: valid) == nil)
        #expect(NameSuggestions.closest("state.feild_equals", in: valid) == "state.field_equals")
        #expect(NameSuggestions.closest("work.quiet", in: valid) == "work.quiescent")
        #expect(NameSuggestions.closest("completely.different.thing", in: valid) == nil)
        #expect(NameSuggestions.editDistance("kitten", "sitting") == 3)
        #expect(NameSuggestions.shellQuoted("a b") == "'a b'")
        #expect(NameSuggestions.shellQuoted("it's") == "'it'\\''s'")
        #expect(NameSuggestions.shellQuoted("plain.value") == "plain.value")
    }

    @Test func unknownNameFailuresListBoundedNamesAndAnExample() {
        let many = (0..<100).map { "fixture-\($0)" }
        let failure = Failure.unknownName(.fixtureNotFound, kind: "fixture", field: "fixture", name: "fixture-7x", valid: many) {
            "agentdevctl fixtures load --fixture \($0)"
        }
        #expect(failure.code == .fixtureNotFound)
        #expect(failure.details?["validNames"]?.arrayValue?.count == NameSuggestions.maxListed)
        #expect(failure.details?["validNamesTruncated"] == true)
        #expect(failure.details?["closest"] == "fixture-7")
        #expect(failure.details?["example"] == "agentdevctl fixtures load --fixture fixture-7")
        #expect(failure.message.contains("Did you mean fixture-7?"))
    }

    // MARK: Session defaults

    @Test func sessionResolutionPrefersFlagThenEnvironmentThenProjectFile() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "adk-defaults-\(UUID().uuidString)")
        let nested = root.appending(path: "a/b/c")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"session": "com.example.app.testing"}"#.utf8).write(to: root.appending(path: ".agentdevkit.json"))

        let fromFile = try #require(try SessionDefaults.resolve(explicit: nil, environment: [:], directory: nested))
        #expect(fromFile.selector == "com.example.app.testing" && fromFile.source == .projectFile)
        #expect(fromFile.file?.lastPathComponent == ".agentdevkit.json")
        let fromEnvironment = try SessionDefaults.resolve(explicit: nil, environment: ["AGENTDEVKIT_SESSION": "env.app"], directory: nested)
        #expect(fromEnvironment?.selector == "env.app" && fromEnvironment?.source == .environment)
        let fromFlag = try SessionDefaults.resolve(explicit: "flag.app", environment: ["AGENTDEVKIT_SESSION": "env.app"], directory: nested)
        #expect(fromFlag?.selector == "flag.app" && fromFlag?.source == .flag)

        let empty = FileManager.default.temporaryDirectory.appending(path: "adk-none-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        #expect(SessionDefaults.projectFile(from: empty) == nil || SessionDefaults.projectFile(from: empty)?.path.hasPrefix(empty.path) == false)

        try Data("not json".utf8).write(to: root.appending(path: ".agentdevkit.json"))
        #expect(throws: Failure.self) { try SessionDefaults.resolve(explicit: nil, environment: [:], directory: nested) }
    }

    // MARK: Field projection and --until

    @Test func fieldProjectionReachesNestedAndReportsMissingFields() throws {
        let state = try #require(AgentOperation.all.first { $0.tool == "state" })
        let response: JSONValue = ["ok": true, "result": [
            "screenId": "controls", "revision": 7, "ready": true,
            "fields": ["phase": "results", "queue": ["count": 2, "items": ["Downloads", "Desktop"]]],
        ]]
        #expect(state.field("phase", in: response) == "results")
        #expect(state.field("queue.count", in: response) == 2)
        #expect(state.field("queue.items.1", in: response) == "Desktop")
        #expect(state.field("revision", in: response) == 7, "State-level keys are reachable too.")
        // JSONValue is ExpressibleByNilLiteral, so compare with an explicit Optional.none.
        #expect(state.field("queue.items.9", in: response) == Optional<JSONValue>.none)
        #expect(state.field("absent", in: response) == Optional<JSONValue>.none)
        let selected = state.select(["phase", "queue.count", "nope"], in: response)
        #expect(selected.object == ["phase": "results", "queue.count": 2])
        #expect(selected.missing == ["nope"])
        #expect(AgentOperation.raw("text") == "text")
        #expect(AgentOperation.raw(["a": 1]) == #"{"a":1}"#)

        let observe = try #require(AgentOperation.all.first { $0.tool == "observe" })
        let observed: JSONValue = ["result": ["screen": ["revision": 3, "fields": ["phase": "scan"]]]]
        #expect(observe.field("phase", in: observed) == "scan")
        #expect(observe.field("revision", in: observed) == 3)
    }

    @Test func untilShorthandMapsToConditions() throws {
        var values: [String: JSONValue] = [:]
        try AgentOperation.applyUntil("phase=results", to: &values)
        #expect(values == ["condition": "state.field_equals", "arguments.field": "phase", "arguments.value": "results"])
        values = [:]
        try AgentOperation.applyUntil("count == 3", to: &values)
        #expect(values["arguments.value"] == 3 && values["arguments.field"] == "count")
        values = [:]
        try AgentOperation.applyUntil("enabled=true", to: &values)
        #expect(values["arguments.value"] == true)
        values = [:]
        try AgentOperation.applyUntil(#"name="3""#, to: &values)
        #expect(values["arguments.value"] == "3", "Quoted JSON keeps a string.")
        values = [:]
        try AgentOperation.applyUntil("screen.ready", to: &values)
        #expect(values == ["condition": "screen.ready"])
        values = ["condition": "screen.ready"]
        #expect(throws: Failure.self) { try AgentOperation.applyUntil("a=b", to: &values) }
        values = [:]
        #expect(throws: Failure.self) { try AgentOperation.applyUntil("a!=b", to: &values) }
        #expect(throws: Failure.self) { try AgentOperation.applyUntil("=b", to: &values) }

        let wait = try #require(AgentOperation.all.first { $0.tool == "wait" })
        let params = try wait.params(["condition": "screen.ready", "everyMs": 200, "until": "x"])
        #expect(params["everyMs"] == nil && params["until"] == nil, "Local options never reach the host.")
    }

    @Test func aliasesMatchTheLongestCommand() throws {
        let set = try #require(AgentOperation.match(["ui", "set", "--id", "x"]))
        #expect(set.operation.method == UICommands.perform.method && set.fixed == ["operation": "set"] && set.length == 2)
        let press = try #require(AgentOperation.match(["ui", "press", "--id", "x"]))
        #expect(press.operation.method == UICommands.press.method)
        #expect(AgentOperation.match(["ui", "nothing"]) == nil)
    }

    // MARK: Recipes

    @Test func recipeValidationNamesTheBadStep() throws {
        let good = Recipe(steps: [["action": "a"], ["burst": [["action": "b"], ["action": "c"]]], ["assert": ["field": "x", "equals": 1]]])
        try good.validate()
        let unknown = Recipe(steps: [["action": "a"], ["teleport": true]])
        #expect(throws: Failure.self) { try unknown.validate() }
        do { try unknown.validate() } catch let failure as Failure { #expect(failure.details?["field"] == "steps.2") }
        let ambiguous = Recipe(steps: [["action": "a", "wait": "screen.ready"]])
        #expect(throws: Failure.self) { try ambiguous.validate() }
        let readInBurst = Recipe(steps: [["burst": [["assert": ["field": "x", "equals": 1]]]]])
        #expect(throws: Failure.self) { try readInBurst.validate() }
        var tooMany = good
        tooMany.repeat = 5_000
        #expect(throws: Failure.self) { try tooMany.validate() }
        let decoded = try JSONDecoder().decode(Recipe.self, from: Data(#"{"fixture": "f", "repeat": 2, "steps": [{"wait": "phase=done"}]}"#.utf8))
        #expect(decoded.repeat == 2 && decoded.fixture == "f")
    }

    // MARK: Visual diffs

    private func image(width: Int = 40, height: Int = 30, draw: (CGContext) -> Void) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        draw(context)
        let rep = NSBitmapImageRep(cgImage: try #require(context.makeImage()))
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    @Test func visualDiffToleratesTinyChangesAndCatchesMovedControls() throws {
        let block: (CGFloat) -> (CGContext) -> Void = { x in { context in
            context.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: x, y: 10, width: 10, height: 10))
        } }
        let baseline = try image(draw: block(5))
        let same = try VisualDiff.compare(baseline, baseline: baseline)
        #expect(same.0.matched && same.0.differingPixels == 0)

        let onePixel = try image { context in
            block(5)(context)
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 30, y: 2, width: 1, height: 1))
        }
        let small = try VisualDiff.compare(onePixel, baseline: baseline, threshold: 0.01)
        #expect(small.0.matched, "One changed pixel of 1200 is below a 1% threshold.")
        #expect(small.0.differingPixels == 1)

        let moved = try image(draw: block(22))
        let (result, diff) = try VisualDiff.compare(moved, baseline: baseline, threshold: 0.01)
        #expect(!result.matched && result.differingPixels >= 100)
        let diffImage = try #require(diff.flatMap { NSBitmapImageRep(data: $0) })
        #expect(diffImage.pixelsWide == 40 && diffImage.pixelsHigh == 30)

        let resized = try image(width: 41, draw: block(5))
        let mismatch = try VisualDiff.compare(resized, baseline: baseline)
        #expect(!mismatch.0.matched && mismatch.0.sizeMismatch == [41, 30, 40, 30])
        #expect(VisualDiff.baselinePath("shots/main-{locale}-{appearance}.png", locale: "ru", appearance: "dark") == "shots/main-ru-dark.png")
    }

    // MARK: File-tree fixtures

    @Test func fileTreesAreDeterministicCanonicalAndPreserveLinks() throws {
        let tree = FileTree([
            .file("Downloads/a.dmg", size: 100.kb, seed: 3, age: .days(300)),
            .duplicate("Desktop/a copy.dmg", of: "Downloads/a.dmg"),
            .hardLink("Documents/a-link.dmg", to: "Downloads/a.dmg"),
            .file("Documents/b.txt", size: 10.bytes),
            .text("Documents/readme.txt", contents: "hello"),
            .directory("Empty", age: .days(2)),
            .symlink("Docs", to: "Documents"),
            .package("Applications/Foo.app", bundleId: "com.example.foo"),
        ])
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // A /var path, which realpath turns into /private/var.
        let base = URL(fileURLWithPath: "/var/tmp/adk-tree-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let first = try tree.materialize(in: base.appending(path: "one"), now: now)
        let second = try tree.materialize(in: base.appending(path: "two"), now: now)
        #expect(first.root.hasPrefix("/private/var/"))
        #expect(first.entry("Downloads/a.dmg")?.sha256 == second.entry("Downloads/a.dmg")?.sha256, "Seeded contents repeat.")
        #expect(first.entry("Downloads/a.dmg")?.size == 102_400)
        #expect(first.entry("Documents/a-link.dmg")?.inode == first.entry("Downloads/a.dmg")?.inode, "A hard link shares the inode.")
        #expect(first.entry("Desktop/a copy.dmg")?.inode != first.entry("Downloads/a.dmg")?.inode)
        #expect(first.duplicateGroups == [["Desktop/a copy.dmg", "Downloads/a.dmg"]])
        let age = try #require(first.entry("Downloads/a.dmg")?.modified)
        #expect(abs(age.timeIntervalSince(now.addingTimeInterval(-300 * 86_400))) < 1)
        #expect(abs((first.entry("Empty")?.modified ?? now).timeIntervalSince(now.addingTimeInterval(-2 * 86_400))) < 1)
        #expect(first.entry("Docs")?.kind == .symlink && first.entry("Docs")?.target == "Documents")
        #expect(FileManager.default.fileExists(atPath: first.root + "/Applications/Foo.app/Contents/Info.plist"))
        #expect(first.totalBytes == 102_400 * 2 + 10 + 5)

        #expect(throws: FileTree.TreeError.self) { try tree.materialize(in: base.appending(path: "one"), now: now) }
        _ = try tree.materialize(in: base.appending(path: "one"), now: now, replace: true)
        #expect(throws: FileTree.TreeError.self) { try FileTree([.file("../escape", size: 1.bytes)]).materialize(in: base.appending(path: "bad")) }
        #expect(throws: FileTree.TreeError.self) { try FileTree([.hardLink("x", to: "missing")]).materialize(in: base.appending(path: "bad2")) }
        #expect(throws: FileTree.TreeError.self) { try FileTree([.file("big", size: 2.mb)], maxBytes: 1_000).materialize(in: base.appending(path: "bad3")) }
    }
}
