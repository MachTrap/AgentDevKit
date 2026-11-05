import AgentDevKitCore
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

/// What the app's own process can observe about its privacy grants. It lists a protected directory and asks
/// the preflight APIs; it never reads TCC databases and never triggers a permission prompt.
enum PrivacyProbe {
    static func status() -> PrivacyStatus {
        var probes: [String: String] = [:]
        let home = getpwuid(geteuid()).flatMap { $0.pointee.pw_dir }.map { String(cString: $0) } ?? NSHomeDirectory()
        var fullDisk = PrivacyStatus.Observation.unknown
        // Directories that only Full Disk Access opens. Listing names reads no file contents.
        for relative in ["Library/Safari", "Library/Mail", "Library/Messages"] {
            let path = home + "/" + relative
            guard let directory = opendir(path) else {
                if errno == EPERM || errno == EACCES {
                    fullDisk = .denied
                    probes["fullDiskAccess"] = "opendir ~/\(relative): permission denied"
                    break
                }
                continue
            }
            closedir(directory)
            fullDisk = .granted
            probes["fullDiskAccess"] = "opendir ~/\(relative): listed"
            break
        }
        if fullDisk == .unknown { probes["fullDiskAccess"] = "no protected directory exists to probe" }
        let trusted = AXIsProcessTrusted()
        probes["accessibility"] = "AXIsProcessTrusted"
        let screen = CGPreflightScreenCaptureAccess()
        probes["screenRecording"] = "CGPreflightScreenCaptureAccess"
        return PrivacyStatus(
            bundleId: Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName,
            sandboxed: ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil,
            fullDiskAccess: fullDisk, accessibility: trusted ? .granted : .denied,
            screenRecording: screen ? .granted : .denied, probes: probes)
    }
}
