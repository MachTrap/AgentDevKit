import Foundation

/// Helpers that turn an unknown name into an error an agent can act on: the valid names,
/// the closest match and a ready-to-run CLI line.
public enum NameSuggestions {
    /// At most this many valid names are listed in `details.validNames`.
    public static let maxListed = 64

    /// Lowercases and drops `_` and `-`, so `state.fieldEquals`, `state.field_equals` and `State.Field-Equals` compare equal.
    public static func normalized(_ name: String) -> String {
        String(name.lowercased().unicodeScalars.filter { $0 != "_" && $0 != "-" }.map(Character.init))
    }

    /// The valid name that equals `name` after normalization, if exactly one does.
    public static func alias(_ name: String, in valid: [String]) -> String? {
        let key = normalized(name)
        let matches = valid.filter { normalized($0) == key }
        return matches.count == 1 ? matches[0] : nil
    }

    /// The nearest valid name by edit distance over normalized names, when it is plausibly a typo.
    public static func closest(_ name: String, in valid: [String]) -> String? {
        let key = normalized(name)
        guard !key.isEmpty else { return nil }
        var best: (name: String, distance: Int)?
        for candidate in valid {
            let distance = editDistance(key, normalized(candidate))
            if best == nil || distance < best!.distance || (distance == best!.distance && candidate < best!.name) {
                best = (candidate, distance)
            }
        }
        guard let best else { return nil }
        // Accept up to a third of the longer name, so unrelated names are not suggested.
        let allowed = max(2, max(key.count, normalized(best.name).count) / 3)
        return best.distance <= allowed ? best.name : nil
    }

    /// Levenshtein distance over Unicode scalars.
    public static func editDistance(_ a: String, _ b: String) -> Int {
        let left = Array(a.unicodeScalars), right = Array(b.unicodeScalars)
        if left.isEmpty { return right.count }
        if right.isEmpty { return left.count }
        var previous = Array(0...right.count)
        var current = [Int](repeating: 0, count: right.count + 1)
        for i in 1...left.count {
            current[0] = i
            for j in 1...right.count {
                let cost = left[i - 1] == right[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[right.count]
    }

    /// Quotes a value for a POSIX shell when it contains anything but safe characters.
    public static func shellQuoted(_ text: String) -> String {
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./:=,@%+"))
        guard !text.isEmpty, text.unicodeScalars.allSatisfy(safe.contains) else {
            return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        return text
    }

    /// Compact, key-sorted JSON for an example command line.
    public static func compactJSON(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}

extension Failure {
    /// An unknown registered name: a condition, action, route, fixture, scope or experiment.
    /// `details` carries `field`, `kind`, `name`, `validNames` (sorted, bounded), `closest` and `example`.
    public static func unknownName(
        _ code: Code = .invalidParams, kind: String, field: String, name: String, valid: [String],
        example: ((String) -> String)? = nil
    ) -> Failure {
        let sorted = valid.sorted()
        let closest = NameSuggestions.closest(name, in: sorted)
        var details: [String: JSONValue] = [
            "field": .string(field), "kind": .string(kind),
            "validNames": .array(sorted.prefix(NameSuggestions.maxListed).map(JSONValue.string))
        ]
        if sorted.count > NameSuggestions.maxListed { details["validNamesTruncated"] = true }
        if let closest {
            details["closest"] = .string(closest)
            if let example { details["example"] = .string(example(closest)) }
        } else if let first = sorted.first, let example {
            details["example"] = .string(example(first))
        }
        let hint = closest.map { " Did you mean \($0)?" } ?? (sorted.isEmpty ? " None are registered." : "")
        return Failure(code, "Unknown \(kind) \(name.prefix(128)).\(hint)", details: details)
    }
}
