import AgentDevKitClient
import AgentDevKitCore
import Foundation

/// `ui capture --baseline PATH [--threshold 0.01] [--update-baseline]`.
enum Baselines {
    struct Options {
        let path: String
        let threshold: Double
        let update: Bool

        /// Removes the baseline options from `values`; nil when no baseline was requested.
        init?(values: inout [String: JSONValue]) {
            let path = values.removeValue(forKey: "baseline")?.stringValue
            let threshold = values.removeValue(forKey: "threshold")?.doubleValue
            let update = values.removeValue(forKey: "updateBaseline")?.boolValue == true
            guard let path else { return nil }
            self.path = path
            self.threshold = threshold ?? 0.01
            self.update = update
        }
    }

    struct Report: Encodable {
        let baseline: String
        let matched: Bool
        let updated: Bool
        let created: Bool
        let diff: String?
        let result: VisualDiff.Result?

        var line: String {
            if created { return "Baseline created: \(baseline)" }
            if updated { return "Baseline updated: \(baseline)" }
            guard let result else { return "Baseline \(baseline)" }
            if let size = result.sizeMismatch {
                return "Baseline MISMATCH: size \(size[0])×\(size[1]) vs \(size[2])×\(size[3])  \(baseline)"
            }
            let percent = String(format: "%.4f%%", result.fraction * 100)
            return "Baseline \(matched ? "matched" : "MISMATCH"): \(result.differingPixels) pixels differ (\(percent), threshold \(result.threshold * 100)%)\(diff.map { "  diff → \($0)" } ?? "")"
        }
    }

    static func compare(_ image: Data, capture: [String: JSONValue], options: Options) throws -> Report {
        let path = VisualDiff.baselinePath(options.path, locale: capture["locale"]?.stringValue, appearance: capture["appearance"]?.stringValue)
        let url = URL(filePath: path)
        let manager = FileManager.default
        if options.update || !manager.fileExists(atPath: url.path) {
            let created = !manager.fileExists(atPath: url.path)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try image.write(to: url, options: .atomic)
            return Report(baseline: url.path, matched: true, updated: !created, created: created, diff: nil, result: nil)
        }
        let baseline = try Data(contentsOf: url)
        let (result, diff) = try VisualDiff.compare(image, baseline: baseline, threshold: options.threshold)
        var diffPath: String?
        if !result.matched, let diff {
            let target = url.deletingPathExtension().appendingPathExtension("diff.png")
            try diff.write(to: target, options: .atomic)
            diffPath = target.path
        }
        return Report(baseline: url.path, matched: result.matched, updated: false, created: false, diff: diffPath, result: result)
    }

    /// Replaces the value at `path` inside `root`; an empty path replaces the root.
    static func replacing(_ root: JSONValue, at path: [String], with value: JSONValue) -> JSONValue {
        guard let head = path.first else { return value }
        guard case .object(var object) = root else { return root }
        object[head] = replacing(object[head] ?? .object([:]), at: Array(path.dropFirst()), with: value)
        return .object(object)
    }
}
