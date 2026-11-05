import AgentDevKitCore
import Foundation

/// `agentdevctl scaffold`: writes the files a Testing target needs and prints the Xcode steps.
/// It never edits the project file; the steps say exactly what to change.
enum Scaffold {
    struct Options {
        var app: String
        var bundleId: String?
        var output: URL
        var appKit: Bool
        var force: Bool
    }

    static let usage = "agentdevctl scaffold --app NAME [--bundle-id ID] [--out DIR] [--appkit] [--force]"

    static func parse(_ arguments: ArraySlice<String>) throws -> Options {
        var app: String?
        var bundleId: String?
        var output = URL(filePath: FileManager.default.currentDirectoryPath)
        var appKit = false
        var force = false
        var iterator = arguments.makeIterator()
        while let flag = iterator.next() {
            switch flag {
            case "--app": app = iterator.next()
            case "--bundle-id": bundleId = iterator.next()
            case "--out": output = URL(filePath: iterator.next() ?? ".")
            case "--appkit": appKit = true
            case "--force": force = true
            default: throw Failure(.invalidParams, "Unexpected option \(flag). Usage: \(usage)")
            }
        }
        guard let app, app.range(of: #"^[A-Za-z][A-Za-z0-9]{0,40}$"#, options: .regularExpression) != nil else {
            throw Failure(.invalidParams, "Pass --app with the app's type-name prefix, such as --app Notes. Usage: \(usage)")
        }
        return Options(app: app, bundleId: bundleId, output: output, appKit: appKit, force: force)
    }

    /// Writes the files and returns the paths written, relative to the output directory.
    static func run(_ options: Options) throws -> [String] {
        let name = options.app
        let files: [(String, String)] = [
            ("\(name)Testing/TestingSession.swift", options.appKit ? appKitSession(name) : swiftUISession(name)),
            ("\(name)Testing/\(name)Adapter.swift", adapter(name)),
            ("Config/\(name)Testing.entitlements", entitlements),
            ("scripts/require-debug-configuration.sh", guardScript),
        ]
        let manager = FileManager.default
        for (path, _) in files where !options.force && manager.fileExists(atPath: options.output.appending(path: path).path) {
            throw Failure(.invalidParams, "\(path) already exists. Pass --force to overwrite.")
        }
        for (path, contents) in files {
            let url = options.output.appending(path: path)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url, options: .atomic)
        }
        try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: options.output.appending(path: "scripts/require-debug-configuration.sh").path)
        return files.map(\.0)
    }

    static func steps(_ options: Options) -> String {
        let name = options.app
        let bundle = options.bundleId.map { "\($0).Testing" } ?? "<your bundle ID>.Testing"
        return """
        Wrote the \(name) Testing files. In Xcode:

        1. Duplicate your app target and name it "\(name)-Testing" (Product name "\(name)-Testing").
           Bundle identifier: \(bundle). Use a separate bundle ID so Testing data never mixes with real data.
        2. Add the folder \(name)Testing/ to the \(name)-Testing target only (with folder references or a
           synchronized folder, every file inside it builds automatically).
        3. Add the package https://github.com/MachTrap/AgentDevKit.git at Exact Version \(AgentDevKitVersion.current),
           and link AgentDevKitHost and AgentDevKitCore to \(name)-Testing only.
        4. In \(name)-Testing's build settings:
           - Active Compilation Conditions (Debug): DEBUG AGENT_DEVKIT
           - Code Signing Entitlements: Config/\(name)Testing.entitlements (merge your app's own entitlements in)
        5. Add a Run Script build phase to \(name)-Testing, first in the list:
               "$SRCROOT/scripts/require-debug-configuration.sh"
           It fails any non-Debug build of the Testing target, so it can never ship.
        6. In your app's entry point, use the Testing session in the Testing build:
               #if AGENT_DEVKIT
               @NSApplicationDelegateAdaptor(TestingSession.self) private var testing
               #endif
           and add TestingBanner(session: testing) to the window under the same condition.
        7. Edit the \(name)-Testing scheme > Run > Arguments and add:
               --enable-agentdevkit --allow-agentdevkit-mutations
        8. Fill in \(name)Adapter.swift: snapshot fields, routes and fixtures for your app (search for TODO).

        Then run the scheme and check the bridge:
            agentdevctl --session \(bundle) capabilities
            agentdevctl --session \(bundle) ui capture --out window.png
        """
    }

    // MARK: Templates

    static func swiftUISession(_ name: String) -> String {
        """
        import AgentDevKitHost
        import AppKit
        import Observation
        import SwiftUI

        /// The \(name) Testing composition root: isolated storage, explicit opt-in and the AgentDevKit session.
        /// Generated by `agentdevctl scaffold`. Testing target only.
        @MainActor
        @Observable
        final class TestingSession: NSObject, NSApplicationDelegate {
            let bridge = AgentSession(label: "\(name) Testing")
            @ObservationIgnored private(set) var profile: TestingProfile?

            func applicationDidFinishLaunching(_ notification: Notification) {
                let options: LaunchOptions
                do { options = try LaunchOptions.parse() } catch {
                    bridge.reject(error)
                    return
                }
                // TODO: point your app's storage at `profile.directory` so tests never touch real data.
                profile = try? TestingProfile(appName: "\(name)", profile: options.profile)
                guard options.enabled else { return }
                let runtime = AgentRuntime()
                let adapter = \(name)Adapter(runtime: runtime)
                let mutations = profile != nil && options.allowMutations
                let host = AgentHost(adapter: adapter, runtime: runtime, catalog: adapter.catalog, allowMutations: mutations)
                bridge.start(host, readOnly: !mutations)
            }

            func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
                bridge.terminate(sender)
            }
        }

        /// Shows the bridge state in the Testing build's window.
        struct TestingBanner: View {
            let session: TestingSession

            var body: some View {
                Label(session.bridge.statusText, systemImage: "hammer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.bar)
                    .accessibilityIdentifier("status.agent-testing")
            }
        }

        """
    }

    static func appKitSession(_ name: String) -> String {
        """
        import AgentDevKitHost
        import AppKit

        /// The \(name) Testing composition root for an AppKit app. Call `start()` from your app delegate's
        /// `applicationDidFinishLaunching` and `terminate(_:)` from `applicationShouldTerminate`.
        /// Generated by `agentdevctl scaffold`. Testing target only.
        @MainActor
        final class TestingSession {
            static let shared = TestingSession()
            let bridge = AgentSession(label: "\(name) Testing")
            private(set) var profile: TestingProfile?

            func start() {
                let options: LaunchOptions
                do { options = try LaunchOptions.parse() } catch {
                    bridge.reject(error)
                    return
                }
                // TODO: point your app's storage at `profile.directory` so tests never touch real data.
                profile = try? TestingProfile(appName: "\(name)", profile: options.profile)
                guard options.enabled else { return }
                let runtime = AgentRuntime()
                let adapter = \(name)Adapter(runtime: runtime)
                let mutations = profile != nil && options.allowMutations
                let host = AgentHost(adapter: adapter, runtime: runtime, catalog: adapter.catalog, allowMutations: mutations)
                bridge.start(host, readOnly: !mutations)
            }

            func terminate(_ app: NSApplication) -> NSApplication.TerminateReply { bridge.terminate(app) }
        }

        """
    }

    static func adapter(_ name: String) -> String {
        """
        import AgentDevKitCore
        import AgentDevKitHost
        import Foundation

        /// \(name)'s typed boundary for AgentDevKit. Generated by `agentdevctl scaffold`; Testing target only.
        /// Expose safe, bounded fields. Never expose secrets or arbitrary model properties.
        @MainActor
        final class \(name)Adapter: AgentAdapter {
            let runtime: AgentRuntime

            init(runtime: AgentRuntime) { self.runtime = runtime }

            func snapshot(scope: String) throws -> ScreenSnapshot {
                // TODO: describe the current screen with a few static fields, for example a selected item's ID.
                ScreenSnapshot(screenId: "home", windowId: "main", ready: true, fields: [:])
            }

            // TODO: return your app's secret values (tokens, passwords) so the host redacts them everywhere.
            func secretValues() -> [String] { [] }

            // TODO: add routes. Resolve validates against a fixture; present navigates the real UI and
            // reports readiness when the destination view actually appeared (onAppear inside .id(presentation)).

            func loadFixture(_ id: String, arguments: [String: JSONValue], context: CommandContext) async throws -> [String: JSONValue] {
                // TODO: replace the isolated Testing data with a named, deterministic data set.
                guard id == "empty-v1" else { throw Failure(.fixtureNotFound, "Fixture is not registered.") }
                runtime.record("fixture.loaded", scope: "app", correlationId: context.requestId, changedFields: ["data"])
                return [:]
            }

            var catalog: AgentCatalog {
                AgentCatalog(
                    scopes: ["current-screen", "app"],
                    fixtures: ["empty-v1"],
                    diagnosticCategories: [],
                    // Lets agents see the window and its accessibility tree, and press controls in mutation sessions.
                    ui: .all
                )
            }
        }

        """
    }

    static let entitlements = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
    \t<!-- Merge your app's own entitlements. The sandbox is supported: the bridge publishes inside the app's container. -->
    \t<key>com.apple.security.app-sandbox</key>
    \t<true/>
    </dict>
    </plist>

    """

    static let guardScript = """
    #!/bin/sh
    # Generated by agentdevctl scaffold. Fails any non-Debug build of a Testing target, so it can never ship.
    if [ "$CONFIGURATION" != Debug ]; then
        echo "error: $TARGET_NAME can only build in Debug configuration. Ship the app target instead." >&2
        exit 1
    fi

    """
}
