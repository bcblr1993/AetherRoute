import Foundation

@main
enum ExternalSubscriptionVerifier {
    static func main() async {
        do {
            try await run()
        } catch {
            fputs(
                "subscription verification failed: "
                    + error.localizedDescription + "\n",
                stderr
            )
            exit(1)
        }
    }

    private static func run() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let normalized: Data
        let report: SubscriptionPayloadReport
        let outputPath: String
        let inputBytes: Int

        if arguments.count == 3, arguments[0] == "normalize" {
            let input = try Data(
                contentsOf: URL(fileURLWithPath: arguments[1]),
                options: [.mappedIfSafe]
            )
            let result = try SubscriptionPayloadNormalizer.normalizeWithReport(
                input
            )
            normalized = result.data
            report = result.report
            outputPath = arguments[2]
            inputBytes = input.count
        } else if arguments.count == 2, arguments[0] == "fetch" {
            guard let rawURL = readLine(strippingNewline: true),
                  !rawURL.isEmpty,
                  rawURL.utf8.count <= 4_096,
                  let url = URL(string: rawURL) else {
                throw ProfileSubscriptionError.invalidURL
            }
            let subscription = try ProfileSubscription(url: url)
            guard case let .updated(data, _, updateReport) = try await ProfileSubscriptionClient
                .live()
                .fetch(subscription) else {
                throw ProfileSubscriptionError.notModifiedWithoutActiveProfile
            }
            normalized = data
            report = updateReport
            outputPath = arguments[1]
            inputBytes = data.count
        } else {
            fputs(
                "usage: subscription_fixture_verifier normalize PAYLOAD OUTPUT_YAML\n"
                    + "       subscription_fixture_verifier fetch OUTPUT_YAML < URL\n",
                stderr
            )
            exit(64)
        }

        try ProfileImportValidator.validate(data: normalized)
        guard let yaml = String(data: normalized, encoding: .utf8) else {
            throw ProfileImportError.notUTF8
        }

        let summary = ProfileConfigurationInspector.inspect(yaml: yaml)
        guard summary.proxyCount > 0 else {
            throw SubscriptionPayloadError.unsupportedFormat
        }
        let protocolCounts = summary.proxies.reduce(into: [String: Int]()) {
            counts, proxy in
            let key = proxy.protocolName.lowercased()
            counts[key, default: 0] += 1
        }
        let protocolSummary = protocolCounts.keys.sorted().map {
            "\($0)=\(protocolCounts[$0] ?? 0)"
        }.joined(separator: ",")

        guard FileManager.default.createFile(
            atPath: outputPath,
            contents: normalized,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }

        print(
            "subscription import_preflight=pass "
                + "input_bytes=\(inputBytes) "
                + "canonical_bytes=\(normalized.count) "
                + "proxies=\(summary.proxyCount) "
                + "groups=\(summary.proxyGroupCount) "
                + "rules=\(summary.ruleCount) "
                + "usable_nodes=\(report.usableNodeCount.map(String.init) ?? "yaml") "
                + "skipped_nodes=\(report.skippedNodeCount) "
                + "protocols=[\(protocolSummary)]"
        )
    }
}
