import Foundation

@main
enum ExternalProfileVerifier {
    static func main() async throws {
        let paths = Array(CommandLine.arguments.dropFirst())
        guard !paths.isEmpty else {
            fputs("usage: profile_fixture_verifier PROFILE...\n", stderr)
            exit(64)
        }

        for (offset, path) in paths.enumerated() {
            let data = try Data(
                contentsOf: URL(fileURLWithPath: path),
                options: [.mappedIfSafe]
            )
            try ProfileImportValidator.validate(data: data)
            try await verifySubscriptionPipeline(data: data)
            guard let yaml = String(data: data, encoding: .utf8) else {
                throw ProfileImportError.notUTF8
            }

            let summary = ProfileConfigurationInspector.inspect(yaml: yaml)
            let protocolCounts = summary.proxies.reduce(into: [String: Int]()) {
                counts, proxy in
                let key = proxy.protocolName.lowercased()
                counts[key, default: 0] += 1
            }
            let protocolSummary = protocolCounts.keys.sorted().map {
                "\($0)=\(protocolCounts[$0] ?? 0)"
            }.joined(separator: ",")

            print(
                "profile[\(offset + 1)] import_preflight=pass "
                    + "subscription_pipeline=pass bytes=\(data.count) "
                    + "proxies=\(summary.proxyCount) "
                    + "groups=\(summary.proxyGroupCount) "
                    + "rules=\(summary.ruleCount) "
                    + "protocols=[\(protocolSummary)]"
            )
        }
    }

    private static func verifySubscriptionPipeline(data: Data) async throws {
        let url = URL(
            string: "https://subscription-fixture.invalid/profile.yaml"
        )!
        let checkedAt = Date(timeIntervalSince1970: 2_000)
        let subscription = try ProfileSubscription(url: url)
        let client = ProfileSubscriptionClient(
            transport: { request in
                guard request.url == url,
                      request.headers["Accept"] != nil,
                      request.headers["User-Agent"]
                        == ProfileSubscriptionClient.userAgent,
                      request.headers["User-Agent"]?
                        .localizedCaseInsensitiveContains("clash") == true,
                      request.headers["Cache-Control"] == "no-cache" else {
                    throw ProfileSubscriptionError.invalidResponse
                }
                return ProfileSubscriptionHTTPResponse(
                    data: data,
                    statusCode: 200,
                    finalURL: url,
                    headers: ["ETag": "\"fixture\""]
                )
            },
            now: { checkedAt }
        )

        guard case let .updated(downloaded, metadata, report) = try await client.fetch(
            subscription
        ), downloaded == data,
           metadata.etag == "\"fixture\"",
           metadata.lastCheckedAt == checkedAt,
           metadata.lastUpdatedAt == checkedAt,
           report == SubscriptionPayloadReport(
               usableNodeCount: nil,
               skippedNodeCount: 0
           ) else {
            throw ProfileSubscriptionError.invalidResponse
        }
    }
}
