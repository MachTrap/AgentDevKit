import AgentDevKitHost
import AppKit
import Observation
#if ADK_LOOPBACK
import DevelopmentIdentity
#endif

/// The Testing app's composition root: isolated storage, explicit opt-in, and the bridge session.
@MainActor
@Observable
final class TestingSession: NSObject, NSApplicationDelegate {
    let model = LabModel()
    let bridge = AgentSession()
    @ObservationIgnored private var profile: TestingProfile?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let runtime = AgentRuntime()
        LabEvents.connect(model, to: runtime)
        let adapter = LabAdapter(model: model)
        let options: LaunchOptions
        do { options = try LaunchOptions.parse(appFlags: ["--agentdevkit-legacy-overflow"]) }
        catch {
            model.reportStorageError()
            bridge.reject(error)
            return
        }
        do {
            let profile = try TestingProfile(appName: "AgentLab", profile: options.profile)
            try model.configure(
                load: { try profile.read("workspace.json").map { try JSONDecoder().decode(Workspace.self, from: $0) } },
                save: { try profile.write(JSONEncoder().encode($0), to: "workspace.json") }
            )
            self.profile = profile
            // Seed only a fresh profile, so a reopened profile keeps its saved edits.
            if options.profile == nil, let fixture = options.fixture { try adapter.apply(Fixture.named(fixture)) }
        } catch {
            model.reportStorageError()
        }
        guard options.enabled else { return }
        let allowMutations = profile != nil && options.allowMutations
        let host = AgentHost(adapter: adapter, runtime: runtime, catalog: adapter.catalog, allowMutations: allowMutations)
        #if ADK_LOOPBACK
        bridge.startPaired(host, pairing: LoopbackPairing(), readOnly: !allowMutations, identity: DevelopmentIdentity.make)
        #elseif ADK_APP_GROUP
        guard let group = Bundle.main.object(forInfoDictionaryKey: "AgentDevKitAppGroup") as? String else {
            return bridge.reject(AgentHostStartError.appGroupUnavailable)
        }
        bridge.start(host, at: .appGroup(group), readOnly: !allowMutations)
        #else
        bridge.start(host, readOnly: !allowMutations)
        #endif
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        bridge.terminate(sender)
    }
}
