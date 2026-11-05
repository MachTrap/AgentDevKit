import AgentDevKitClient
import AgentDevKitCore
import Darwin
import Foundation

/// `agentdevctl desktop …` runs the separate, opt-in `agentdevkit-desktop` runner, which is never linked into apps.
enum Desktop {
    static func runner() -> URL? {
        let me = URL(filePath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let candidates = [me.deletingLastPathComponent().appending(path: "agentdevkit-desktop")]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { URL(filePath: String($0)).appending(path: "agentdevkit-desktop") }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    static func forward(_ arguments: [String], selector: String?, location: SessionLocation, json: Bool) throws -> Int32 {
        guard let runner = runner() else {
            throw Failure(.invalidParams, "agentdevkit-desktop is not installed next to agentdevctl.",
                          details: ["remedy": "Build it with: swift build -c release --product agentdevkit-desktop, and grant it Accessibility in System Settings → Privacy & Security."])
        }
        var argv = [runner.path]
        if let selector { argv += ["--session", selector] }
        switch location {
        case .appGroup(let group): argv += ["--app-group", group]
        case .appContainer(let container): argv += ["--container", container]
        case .pairingDirectory(let folder): argv += ["--pairing-dir", folder.path]
        case .local: break
        }
        argv += arguments + (json ? ["--json"] : [])
        // Replace this process, so signals and the exit status pass straight through.
        var cArguments = argv.map { strdup($0) } + [nil]
        execv(runner.path, &cArguments)
        throw Failure(.internalError, "agentdevkit-desktop could not be started.")
    }
}
