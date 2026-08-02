import Foundation

@main
enum DistributionServiceInterop {
    private static let productID = "com.aetherroute.desktop"
    private static let deviceID = "11111111-2222-4333-8444-555555555555"

    static func main() async throws {
        guard CommandLine.arguments.count == 4,
              let port = UInt16(CommandLine.arguments[1]),
              let baseURL = URL(string: "http://127.0.0.1:\(port)"),
              let licenseURL = URL(string: "https://staging.invalid/v1/license"),
              let updateURL = URL(string: "https://staging.invalid/v1/update")
        else { throw IndependentDistributionError.invalidClientIdentity }

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
            }
        )
        let active = try await client.activateLicense(
            key: CommandLine.arguments[3],
            deviceID: deviceID,
            appVersion: "1.0.0",
            appBuild: "100"
        )
        guard active.entitlement.state == .active else {
            throw IndependentDistributionError.invalidEntitlement
        }
        let refreshed = try await client.refreshLicense(
            signedReceipt: active.signedReceipt,
            deviceID: deviceID,
            appVersion: "1.0.0",
            appBuild: "100"
        )
        guard refreshed.entitlement.state == .active else {
            throw IndependentDistributionError.invalidEntitlement
        }
        guard case let .available(manifest) = try await client.checkForUpdates(
            currentBuild: 100
        ), manifest.build == 101, manifest.architecture == "arm64" else {
            throw IndependentDistributionError.invalidUpdateManifest
        }
        try await client.deactivateLicense(
            signedReceipt: refreshed.signedReceipt,
            deviceID: deviceID,
            appVersion: "1.0.0",
            appBuild: "100"
        )
        do {
            _ = try await client.refreshLicense(
                signedReceipt: refreshed.signedReceipt,
                deviceID: deviceID,
                appVersion: "1.0.0",
                appBuild: "100"
            )
            throw IndependentDistributionError.invalidEntitlement
        } catch let error as IndependentDistributionError {
            guard error == .httpStatus(403) else { throw error }
        }
        print("Go distribution service interop passed: activate refresh update deactivate fail-closed")
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
