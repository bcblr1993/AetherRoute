import Foundation

/// Mihomo's `ca` option names a PEM file on the machine that runs the core.
/// The network extensions are sandboxed and cannot open the user's files, so
/// an imported profile carries the certificate inline as `ca-str` instead.
/// Paths that cannot be read are left in place and reported; the engine then
/// refuses only those nodes, with the reason.
public enum ProfileCertificateAuthorityInliner {
    public struct Outcome: Equatable, Sendable {
        public let data: Data
        public let unreadablePaths: [String]
    }

    static let maximumCertificateBytes = 256 * 1_024

    public static func inline(
        _ data: Data,
        relativeTo directory: URL?,
        readFile: (URL) throws -> Data = { try Data(contentsOf: $0) }
    ) -> Outcome {
        guard let text = String(data: data, encoding: .utf8),
              text.contains("ca:") else {
            return Outcome(data: data, unreadablePaths: [])
        }
        var unreadable = [String]()
        var changed = false
        var output = [String]()
        for line in text.components(separatedBy: "\n") {
            guard let (indent, value) = blockCAValue(in: line),
                  !value.contains("-----BEGIN") else {
                output.append(line)
                continue
            }
            guard let pem = readCertificate(
                at: value,
                relativeTo: directory,
                readFile: readFile
            ) else {
                unreadable.append(value)
                output.append(line)
                continue
            }
            output.append("\(indent)ca-str: |")
            output.append(contentsOf: pem
                .split(whereSeparator: \.isNewline)
                .map { "\(indent)  \($0)" })
            changed = true
        }
        return Outcome(
            data: changed ? Data(output.joined(separator: "\n").utf8) : data,
            unreadablePaths: unreadable
        )
    }

    /// A block-style `ca: value` line (not `ca-str`, not inside a flow
    /// mapping), with its indentation and the unquoted value.
    static func blockCAValue(in line: String) -> (String, String)? {
        let indent = String(line.prefix(while: { $0 == " " }))
        var rest = line.dropFirst(indent.count)
        if rest.hasPrefix("- ") { return nil }
        guard rest.hasPrefix("ca:") else { return nil }
        rest = rest.dropFirst(3)
        var value = rest.trimmingCharacters(in: .whitespaces)
        if let comment = value.range(of: " #") {
            value = String(value[..<comment.lowerBound])
                .trimmingCharacters(in: .whitespaces)
        }
        if value.count >= 2,
           let first = value.first, first == value.last,
           first == "\"" || first == "'" {
            value = String(value.dropFirst().dropLast())
        }
        guard !value.isEmpty, value != "|", value != ">" else { return nil }
        return (indent, value)
    }

    private static func readCertificate(
        at path: String,
        relativeTo directory: URL?,
        readFile: (URL) throws -> Data
    ) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        let url: URL
        if expanded.hasPrefix("/") {
            url = URL(fileURLWithPath: expanded)
        } else if let directory {
            url = directory.appendingPathComponent(expanded)
        } else {
            return nil
        }
        guard let data = try? readFile(url),
              data.count <= maximumCertificateBytes,
              let pem = String(data: data, encoding: .utf8),
              pem.contains("-----BEGIN CERTIFICATE-----") else {
            return nil
        }
        return pem
    }
}
