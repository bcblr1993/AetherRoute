import Foundation

/// JSON is valid YAML, but the runtime's section-based rewriters require block
/// YAML. Canonicalize only the runtime copy, preserving the imported text.
public enum ProfileRuntimeYAML {
    public static func canonicalize(_ text: String) -> String {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).first == "{",
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
              let mapping = object as? [String: Any],
              let lines = try? render(mapping, indent: 0) else { return text }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func scalar(_ value: Any) throws -> String {
        // Later DNS section rewrites consume URI scalars without JSON decoding.
        let data = try JSONSerialization.data(
            withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]
        )
        return String(decoding: data, as: UTF8.self)
    }

    private static func key(_ value: String) throws -> String {
        let bytes = Array(value.utf8)
        let isLetter: (UInt8) -> Bool = { (65...90).contains($0) || (97...122).contains($0) || $0 == 95 }
        let reserved = ["true", "false", "null", "yes", "no", "on", "off"]
        if let first = bytes.first, isLetter(first),
           bytes.allSatisfy({ isLetter($0) || (48...57).contains($0) || $0 == 45 }),
           !reserved.contains(value.lowercased()) { return value }
        return try scalar(value)
    }

    private static func isNonemptyContainer(_ value: Any) -> Bool {
        if let mapping = value as? [String: Any] { return !mapping.isEmpty }
        if let sequence = value as? [Any] { return !sequence.isEmpty }
        return false
    }

    private static func render(_ value: Any, indent: Int) throws -> [String] {
        let padding = String(repeating: " ", count: indent)
        if let mapping = value as? [String: Any] {
            var lines = [String]()
            for name in mapping.keys.sorted() {
                guard let child = mapping[name] else { continue }
                let prefix = padding + (try key(name)) + ":"
                if isNonemptyContainer(child) {
                    lines.append(prefix)
                    lines.append(contentsOf: try render(child, indent: indent + 2))
                } else { lines.append(prefix + " " + (try scalar(child))) }
            }
            // Empty mappings still need a YAML value when used at the root.
            return lines.isEmpty ? [padding + "{}"] : lines
        }
        if let sequence = value as? [Any] {
            var lines = [String]()
            for child in sequence {
                if isNonemptyContainer(child) {
                    let nested = try render(child, indent: indent + 2)
                    lines.append(padding + "- " + String(nested[0].dropFirst(indent + 2)))
                    lines.append(contentsOf: nested.dropFirst())
                } else { lines.append(padding + "- " + (try scalar(child))) }
            }
            return lines.isEmpty ? [padding + "[]"] : lines
        }
        return [padding + (try scalar(value))]
    }
}
