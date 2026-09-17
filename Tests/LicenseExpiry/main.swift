import AetherRouteKit
import CryptoKit
import Foundation
import Synchronization

// Only localization is stubbed; all licensing, signature, storage, access and
// controller paths under test are production code. No network is contacted.
enum AppLocalization {
    static func string(_ value: String) -> String { value }
}
final class TestClock: Sendable {
    let value: Mutex<Date>
    init(_ date: Date) { value = Mutex(date) }
    func now() -> Date { value.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { value.withLock { $0.addTimeInterval(seconds) } }
}
@main
struct LicenseExpiryRegression {
    @MainActor static func main() async throws {
        let clock = TestClock(Date())
        let key = Curve25519.Signing.PrivateKey()
        let device = "11111111-2222-3333-4444-555555555555"
        let entitlement = LicenseEntitlement(productID: "com.example.aetherroute", licenseID: "license-1", deviceID: device,
                                             state: .active, issuedAt: clock.now().addingTimeInterval(-60), expiresAt: clock.now().addingTimeInterval(120))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payload = try encoder.encode(entitlement)
        let receipt = try encoder.encode(SignedDistributionEnvelope(payload: payload.base64EncodedString(), signature: key.signature(for: payload).base64EncodedString()))
        let configuration = try IndependentDistributionConfiguration(productID: entitlement.productID,
            licenseServiceURL: URL(string: "https://license.example/v1/license")!,
            updateManifestURL: URL(string: "https://license.example/update")!,
            signingPublicKeyBase64: key.publicKey.rawRepresentation.base64EncodedString())
        let client = try IndependentDistributionClient(configuration: configuration, transport: { _ in
            throw URLError(.notConnectedToInternet)
        }, now: { clock.now() })
        let store = InMemoryDistributionCredentialStore(deviceID: device, receipt: receipt)
        let controller = IndependentDistributionController(client: client, credentialStore: store, now: { clock.now() })
        controller.loadLocalReceipt()
        precondition(controller.connectionAccess.permitsNewConnection(at: clock.now()))
        await controller.refreshLicense()
        precondition(controller.connectionAccess.permitsNewConnection(at: clock.now()), "Unexpired receipt must survive transient offline refresh")
        clock.advance(180)
        precondition(!controller.connectionAccess.permitsNewConnection(at: clock.now()), "Admission must reject expiry before any timer runs")
        await controller.refreshLicense()
        precondition(controller.connectionAccess == .restricted(.expired), "Offline expired refresh must revoke old authorization")

        // Simulate sleep crossing expiry without a network refresh.
        let secondClock = TestClock(entitlement.issuedAt.addingTimeInterval(60))
        let secondClient = try IndependentDistributionClient(configuration: configuration, transport: { _ in throw URLError(.timedOut) }, now: { secondClock.now() })
        let second = IndependentDistributionController(client: secondClient, credentialStore: store, now: { secondClock.now() })
        second.loadLocalReceipt()
        secondClock.advance(86_400)
        second.revalidateLicense()
        precondition(second.connectionAccess == .restricted(.expired))
        let rejectedClient = try IndependentDistributionClient(configuration: configuration,
            transport: { _ in throw IndependentDistributionError.httpStatus(403) }, now: { secondClock.now() })
        secondClock.advance(-86_400)
        let rejected = IndependentDistributionController(client: rejectedClient, credentialStore: store, now: { secondClock.now() })
        rejected.loadLocalReceipt()
        await rejected.refreshLicense()
        precondition(rejected.connectionAccess == .activationRequired, "A definitive rejection is not offline grace")
        print("License expiry: offline grace, expiry admission, failed refresh and wake revalidation passed")
    }
}
