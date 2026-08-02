import AetherRouteKit
import Foundation
import XCTest

final class ProxySelectionStoreTests: XCTestCase {
    func testVerifiedSelectionRoundTripsAndIsBoundToProfile() throws {
        let fixture = try makeFixture()
        try fixture.store.recordVerified(
            snapshot: .init(
                selectedMember: "Edge B",
                members: ["Edge A", "Edge B"]
            ),
            group: "Route",
            profileYAML: "proxies: [a]"
        )

        XCTAssertEqual(
            try fixture.store.selections(
                forProfileYAML: "proxies: [a]"
            ),
            ["Route": "Edge B"]
        )
        XCTAssertTrue(
            try fixture.store.selections(
                forProfileYAML: "proxies: [b]"
            ).isEmpty
        )
    }

    func testCiphertextHidesNamesAndUsesFreshNonce() throws {
        let fixture = try makeFixture()
        let snapshot = ProxySelectionState(
            selectedMember: "private-edge-sentinel",
            members: ["private-edge-sentinel"]
        )
        try fixture.store.recordVerified(
            snapshot: snapshot,
            group: "private-group-sentinel",
            profileYAML: "secret-profile-sentinel"
        )
        let first = try Data(contentsOf: fixture.fileURL)
        try fixture.store.recordVerified(
            snapshot: snapshot,
            group: "private-group-sentinel",
            profileYAML: "secret-profile-sentinel"
        )
        let second = try Data(contentsOf: fixture.fileURL)

        XCTAssertNotEqual(first, second)
        for sentinel in [
            "private-edge-sentinel",
            "private-group-sentinel",
            "secret-profile-sentinel",
        ] {
            XCTAssertFalse(String(decoding: second, as: UTF8.self).contains(sentinel))
        }
    }

    func testTamperingAndWrongKeyAreRejected() throws {
        let fixture = try makeFixture()
        try fixture.store.recordVerified(
            snapshot: .init(selectedMember: "A", members: ["A"]),
            group: "Route",
            profileYAML: "profile"
        )
        var data = try Data(contentsOf: fixture.fileURL)
        data[data.index(before: data.endIndex)] ^= 0x01
        try data.write(to: fixture.fileURL, options: .atomic)
        XCTAssertThrowsError(
            try fixture.store.selections(forProfileYAML: "profile")
        )

        let wrongStore = ProxySelectionStore(
            directoryURL: fixture.directory,
            keyStore: InMemoryProfileKeyStore(
                keys: ["profile-master-key.v1": Data(repeating: 0x55, count: 32)]
            )
        )
        XCTAssertThrowsError(
            try wrongStore.selections(forProfileYAML: "profile")
        )
    }

    func testUnverifiedAndInvalidNamesAreRejectedBeforeCreatingFile() throws {
        let fixture = try makeFixture()
        XCTAssertThrowsError(
            try fixture.store.recordVerified(
                snapshot: .init(selectedMember: nil, members: ["A"]),
                group: "Route",
                profileYAML: "profile"
            )
        )
        XCTAssertThrowsError(
            try fixture.store.recordVerified(
                snapshot: .init(selectedMember: "A", members: ["A"]),
                group: "bad\0group",
                profileYAML: "profile"
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.fileURL.path))
    }

    private func makeFixture() throws -> (
        store: ProxySelectionStore,
        directory: URL,
        fileURL: URL
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let keyStore = InMemoryProfileKeyStore(
            keys: ["profile-master-key.v1": Data(repeating: 0x2a, count: 32)]
        )
        return (
            ProxySelectionStore(
                directoryURL: directory,
                keyStore: keyStore
            ),
            directory,
            directory.appendingPathComponent("proxy-selections.v1.json")
        )
    }
}
