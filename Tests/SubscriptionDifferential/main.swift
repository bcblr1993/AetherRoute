import Foundation

/// Produces the profile the app's engine would load for a subscription
/// payload: the import normalizer, then (unless disabled) the domestic
/// routing optimizer, as `TunnelManager` applies them. Also writes the
/// Clash-format profile Mihomo should get: the payload itself when it is
/// already YAML with proxies, otherwise the normalizer's conversion.
@main
struct SubscriptionDifferentialProfile {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 5 || (arguments.count == 6 && arguments[5] == "--no-domestic") else {
            FileHandle.standardError.write(Data(
                "usage: profile <payload> <ours.yaml> <reference.yaml> <report.json> [--no-domestic]\n".utf8
            ))
            exit(64)
        }
        let payload = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
        let normalized = try SubscriptionPayloadNormalizer.normalizeWithReport(payload)
        guard let normalizedYAML = String(data: normalized.data, encoding: .utf8) else {
            throw ProfileImportError.notUTF8
        }
        let ours = arguments.count == 6
            ? normalizedYAML
            : DomesticRoutingOptimizer.optimizedProfile(for: normalizedYAML)
        try write(ours, to: arguments[2])

        let payloadText = String(data: payload, encoding: .utf8) ?? ""
        let payloadIsProfile = payloadText.range(
            of: #"(?m)^proxies\s*:"#, options: .regularExpression
        ) != nil
        try write(payloadIsProfile ? payloadText : normalizedYAML, to: arguments[3])

        let report: [String: Any] = [
            "usableNodeCount": normalized.report.usableNodeCount as Any,
            "skippedNodeCount": normalized.report.skippedNodeCount,
            "referenceIsPayload": payloadIsProfile,
            "domesticOptimization": arguments.count == 5,
        ]
        let json = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        try write(String(decoding: json, as: UTF8.self), to: arguments[4])
    }

    private static func write(_ text: String, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try Data(text.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
}
