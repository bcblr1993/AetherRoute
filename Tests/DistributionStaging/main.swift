import Foundation

@main
enum DistributionStagingVerifier {
    private static let productID = "com.example.aetherroute"
    private static let deviceID = "11111111-2222-3333-4444-555555555555"
    private static let now = Date(timeIntervalSince1970: 1_785_585_600)

    static func main() async throws {
        guard CommandLine.arguments.count == 3,
              let port = UInt16(CommandLine.arguments[1]),
              let baseURL = URL(string: "http://127.0.0.1:\(port)"),
              let licenseURL = URL(
                  string: "https://staging.invalid/v1/license"
              ),
              let updateURL = URL(
                  string: "https://staging.invalid/v1/update"
              ) else {
            throw IndependentDistributionError.invalidClientIdentity
        }
        let configuration = try IndependentDistributionConfiguration(
            productID: productID,
            licenseServiceURL: licenseURL,
            updateManifestURL: updateURL,
            signingPublicKeyBase64: CommandLine.arguments[2]
        )
        let client = try IndependentDistributionClient(
            configuration: configuration,
            transport: { request in
                try await loopbackTransport(request, baseURL: baseURL)
            },
            now: { now }
        )

        let active = try await client.activateLicense(
            key: "ACTIVE-LICENSE-KEY",
            deviceID: deviceID,
            appVersion: "1.0.0",
            appBuild: "100"
        )
        guard active.entitlement.state == .active,
              DistributionConnectionAccess.authorized.permitsNewConnection
        else { throw IndependentDistributionError.invalidEntitlement }

        let revokedOnRefresh = try await client.refreshLicense(
            signedReceipt: active.signedReceipt,
            deviceID: deviceID,
            appVersion: "1.0.0",
            appBuild: "100"
        )
        guard revokedOnRefresh.entitlement.state == .revoked,
              !DistributionConnectionAccess.restricted(.revoked)
                .permitsNewConnection else {
            throw IndependentDistributionError.invalidEntitlement
        }

        let deviceLimit = try await client.activateLicense(
            key: "DEVICE-LIMIT-KEY",
            deviceID: deviceID,
            appVersion: "1.0.0",
            appBuild: "100"
        )
        guard deviceLimit.entitlement.state == .deviceLimit,
              !DistributionConnectionAccess.restricted(.deviceLimit)
                .permitsNewConnection else {
            throw IndependentDistributionError.invalidEntitlement
        }

        let revoked = try await client.activateLicense(
            key: "REVOKED-LICENSE-KEY",
            deviceID: deviceID,
            appVersion: "1.0.0",
            appBuild: "100"
        )
        guard revoked.entitlement.state == .revoked else {
            throw IndependentDistributionError.invalidEntitlement
        }

        do {
            _ = try await client.activateLicense(
                key: "UNKNOWN-LICENSE-KEY",
                deviceID: deviceID,
                appVersion: "1.0.0",
                appBuild: "100"
            )
            throw IndependentDistributionError.invalidEntitlement
        } catch let error as IndependentDistributionError {
            guard error == .httpStatus(404) else { throw error }
        }

        try await client.deactivateLicense(
            signedReceipt: active.signedReceipt,
            deviceID: deviceID,
            appVersion: "1.0.0",
            appBuild: "100"
        )

        guard case let .available(manifest) = try await client.checkForUpdates(
            currentBuild: 100
        ), manifest.build == 101, manifest.architecture == "arm64" else {
            throw IndependentDistributionError.invalidUpdateManifest
        }
        guard case .current = try await client.checkForUpdates(currentBuild: 101)
        else { throw IndependentDistributionError.invalidUpdateManifest }

        print(
            "distribution staging passed: activation=active "
                + "refresh=revoked device-limit=restricted deactivation=204 "
                + "update=arm64-signed unknown-key=generic-404"
        )
    }

    private static func loopbackTransport(
        _ request: DistributionHTTPRequest,
        baseURL: URL
    ) async throws -> DistributionHTTPResponse {
        var components = try required(
            URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        )
        components.path = request.url.path
        components.query = nil
        components.fragment = nil
        let transportURL = try required(components.url)
        var urlRequest = URLRequest(url: transportURL)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = 5
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: urlRequest)
        guard let response = response as? HTTPURLResponse else {
            throw IndependentDistributionError.invalidHTTPResponse
        }
        return DistributionHTTPResponse(
            data: data,
            statusCode: response.statusCode,
            finalURL: request.url
        )
    }

    private static func required<T>(_ value: T?) throws -> T {
        guard let value else {
            throw IndependentDistributionError.invalidHTTPResponse
        }
        return value
    }
}
