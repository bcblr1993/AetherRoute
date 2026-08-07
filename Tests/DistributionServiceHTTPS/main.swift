import Foundation

@main
enum DistributionServiceHTTPSVerifier {
    private static let productID = "com.aetherroute.desktop"

    static func main() async throws {
        guard CommandLine.arguments.count == 7,
              let licenseURL = URL(string: CommandLine.arguments[1]),
              let updateURL = URL(string: CommandLine.arguments[2]),
              let expectedBuild = Int(CommandLine.arguments[5]),
              expectedBuild > 1,
              let expectedDownloadURL = URL(string: CommandLine.arguments[6])
        else { throw IndependentDistributionError.invalidClientIdentity }

        let activationKey = try String(
            contentsOfFile: CommandLine.arguments[4],
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let configuration = try IndependentDistributionConfiguration(
            productID: productID,
            licenseServiceURL: licenseURL,
            updateManifestURL: updateURL,
            signingPublicKeyBase64: CommandLine.arguments[3]
        )
        let client = try IndependentDistributionClient.live(
            configuration: configuration
        )
        let deviceID = UUID().uuidString
        let active = try await client.activateLicense(
            key: activationKey,
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
            currentBuild: expectedBuild - 1
        ), manifest.build == expectedBuild,
              manifest.architecture == "arm64",
              manifest.downloadURL == expectedDownloadURL else {
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
        print(
            "Owner HTTPS distribution service passed native activate, refresh, "
                + "signed update, deactivate, and fail-closed verification."
        )
    }
}
