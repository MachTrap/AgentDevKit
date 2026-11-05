import AgentDevKitTransport
import AppKit
import Observation
import Security

/// Runs one bridge for an AppKit or SwiftUI Testing app: start after opt-in, show status,
/// and finish the session before the app terminates.
@MainActor
@Observable
public final class AgentSession {
    public enum Status: Sendable, Equatable {
        case disabled
        case starting
        case active(readOnly: Bool)
        case failed(String)
        case pairingRequired
        case pairingFailed(String)
        case pairingForgotten
    }

    public private(set) var status: Status = .disabled
    /// Whether a paired-loopback session currently holds a folder.
    public private(set) var paired = false
    public let label: String
    @ObservationIgnored private var host: AgentHost?
    @ObservationIgnored private var lifecycle: Task<Void, Never>?
    @ObservationIgnored private var pairing: LoopbackPairing?
    @ObservationIgnored private var identity: (@Sendable () throws -> SecIdentity)?
    @ObservationIgnored private var readOnly = true
    @ObservationIgnored private var stopping = false

    public init(label: String = "AgentTesting") { self.label = label }

    /// Human-readable status for a Testing banner.
    public var statusText: String {
        let detail = switch status {
        case .disabled: "Bridge disabled"
        case .starting: "Bridge starting"
        case .active(let readOnly): readOnly ? "Bridge active · Read-only" : "Bridge active · Test mutations enabled"
        case .failed(let reason): "Bridge failed: \(reason)"
        case .pairingRequired: "Pairing required"
        case .pairingFailed(let reason): "Pairing failed: \(reason)"
        case .pairingForgotten: "Pairing forgotten"
        }
        return "\(label) · \(detail)"
    }

    /// Shows why the bridge did not start, such as an invalid launch argument. The bridge stays off.
    public func reject(_ error: any Error) {
        guard host == nil else { return }
        status = .failed(String(describing: error))
    }

    /// Whether this session uses a pairing folder.
    public var usesPairing: Bool { pairing != nil }

    /// Starts an unsandboxed (`.local`) or App Group session.
    public func start(_ host: AgentHost, at location: SessionLocation = .local, readOnly: Bool) {
        guard self.host == nil else { return }
        self.host = host
        self.readOnly = readOnly
        status = .starting
        lifecycle = Task {
            defer { lifecycle = nil }
            do {
                try await host.start(at: location)
                status = .active(readOnly: readOnly)
            } catch {
                status = .failed(String(describing: error))
            }
        }
    }

    /// Starts a paired-loopback session. Prompts for a folder when none is saved.
    /// `identity` must create a fresh TLS identity on every call.
    public func startPaired(
        _ host: AgentHost, pairing: LoopbackPairing, readOnly: Bool, identity: @escaping @Sendable () throws -> SecIdentity
    ) {
        guard self.host == nil else { return }
        self.host = host
        self.pairing = pairing
        self.identity = identity
        self.readOnly = readOnly
        pair(prompt: false)
    }

    /// Asks for a pairing folder and starts the bridge in it. Use for a "Pair Folder…" control.
    public func pair() { pair(prompt: true) }

    private func pair(prompt: Bool) {
        guard let host, let pairing, let identity, !paired, !stopping, lifecycle == nil else { return }
        status = .starting
        lifecycle = Task {
            defer { lifecycle = nil }
            do {
                guard let folder = try await pairing.acquire(prompt: prompt) else {
                    status = .pairingRequired
                    return
                }
                try Task.checkCancellation()
                do { try await host.start(at: .pairingDirectory(folder), loopbackIdentity: identity) }
                catch let error as AgentHostStartError {
                    pairing.release()
                    if error != .cancelled { status = .pairingFailed(error.description) }
                    return
                }
                paired = true
                status = .active(readOnly: readOnly)
            } catch is CancellationError {
                pairing.release()
            } catch {
                status = .pairingFailed(String(describing: error))
            }
        }
    }

    /// Stops the paired bridge and removes the saved bookmark. Use for a "Forget Pairing" control.
    public func forgetPairing() {
        guard paired, !stopping, let host, let pairing else { return }
        stopping = true
        paired = false
        pairing.forget()
        lifecycle = Task {
            await host.stop()
            pairing.release()
            status = .pairingForgotten
            stopping = false
            lifecycle = nil
        }
    }

    /// Stops the bridge and waits until its descriptor is withdrawn.
    public func stop() async {
        let pending = lifecycle
        if !stopping { pending?.cancel() }
        pairing?.cancelPrompt()
        await pending?.value
        await host?.stop()
        pairing?.release()
        paired = false
    }

    /// Call from `applicationShouldTerminate(_:)`. Defers termination until the session is withdrawn.
    public func terminate(_ app: NSApplication) -> NSApplication.TerminateReply {
        guard host != nil else { return .terminateNow }
        Task {
            await stop()
            app.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
