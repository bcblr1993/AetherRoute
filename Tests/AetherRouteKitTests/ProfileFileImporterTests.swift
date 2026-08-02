import Foundation
import Darwin
import XCTest
@testable import AetherRouteKit

final class ProfileFileImporterTests: XCTestCase {
    func testCancellationBeforeValidationDoesNotCommitProfile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let profileURL = directory.appendingPathComponent("cancelled.yaml")
        let store = makeStore(directory: directory.appendingPathComponent("store"))
        let loader = ControlledProfileLoader(data: Self.fixture(nodeCount: 1))
        let task = Task { @Sendable in
            try await ProfileFileImporter.importProfile(
                from: profileURL,
                into: store,
                loadData: { url in try loader.load(url) }
            )
        }

        XCTAssertTrue(loader.waitUntilStarted(timeout: 1))
        task.cancel()
        loader.finish()
        do {
            _ = try await task.value
            XCTFail("Cancelled import unexpectedly committed")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertTrue(try store.loadOrMigrate().profiles.isEmpty)
    }

    func testFiveThousandNodeImportMeetsReleaseBudget() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let profileURL = directory.appendingPathComponent("five-thousand.yaml")
        try Self.fixture(nodeCount: 5_000).write(to: profileURL)
        let store = makeStore(directory: directory.appendingPathComponent("store"))
        let baseline = Self.residentMemoryBytes()
        let sampler = ResidentMemorySampler(baseline: baseline)
        sampler.start()
        let clock = ContinuousClock()
        let started = clock.now
        let catalog = try await ProfileFileImporter.importProfile(
            from: profileURL,
            into: store
        )
        let elapsed = started.duration(to: clock.now)
        let peakGrowth = sampler.stopAndPeakGrowth()
        let elapsedSeconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000_000

        print(
            String(
                format:
                    "large_import_nodes=5000 elapsed_seconds=%.6f peak_rss_growth_bytes=%llu",
                elapsedSeconds,
                peakGrowth
            )
        )

        XCTAssertEqual(catalog.profiles.count, 1)
        XCTAssertEqual(catalog.activeProfile?.profile.name, "five-thousand")
        XCTAssertLessThan(elapsed, .seconds(2))
        if Self.isAddressSanitized {
            // ASan reserves redzones and a quarantine around allocations, so
            // process RSS is not comparable with the Release-build budget.
            // The dedicated Release gate enforces 100 MiB; this run still
            // proves the full import path under memory instrumentation.
            XCTAssertGreaterThan(peakGrowth, 0)
        } else {
            XCTAssertLessThanOrEqual(peakGrowth, 100 * 1_024 * 1_024)
        }
    }

    private func makeStore(directory: URL) -> ProfileCatalogStore {
        ProfileCatalogStore(
            directoryURL: directory,
            keyStore: InMemoryProfileKeyStore(
                keys: [
                    EncryptedProfileCodec.defaultKeyID:
                        Data(repeating: 0xA5, count: 32),
                ]
            )
        )
    }

    private static func fixture(nodeCount: Int) -> Data {
        Data(
            (["proxies:"] + (0..<nodeCount).map {
                "  - {name: node-\($0), type: socks5, server: 127.0.0.1, port: 1080}"
            } + ["rules:", "  - MATCH,DIRECT"])
                .joined(separator: "\n")
                .utf8
        )
    }

    fileprivate static func residentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size
                / MemoryLayout<natural_t>.size
        )
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }
        return status == KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }

    private static var isAddressSanitized: Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["ASAN_OPTIONS"] != nil
            || environment["DYLD_INSERT_LIBRARIES"]?
                .contains("libclang_rt.asan") == true
        {
            return true
        }
        guard let process = dlopen(nil, RTLD_NOW) else { return false }
        defer { dlclose(process) }
        return dlsym(process, "__asan_init") != nil
    }
}

private final class ControlledProfileLoader: @unchecked Sendable {
    private let data: Data
    private let started = DispatchSemaphore(value: 0)
    private let finishSignal = DispatchSemaphore(value: 0)

    init(data: Data) {
        self.data = data
    }

    func load(_ url: URL) throws -> Data {
        _ = url
        started.signal()
        finishSignal.wait()
        return data
    }

    func waitUntilStarted(timeout: TimeInterval) -> Bool {
        started.wait(timeout: .now() + timeout) == .success
    }

    func finish() {
        finishSignal.signal()
    }
}

private final class ResidentMemorySampler: @unchecked Sendable {
    private let lock = NSLock()
    private let baseline: UInt64
    private var peak: UInt64
    private var running = true
    private let queue = DispatchQueue(label: "com.aetherroute.tests.import-memory")

    init(baseline: UInt64) {
        self.baseline = baseline
        self.peak = baseline
    }

    func start() {
        queue.async { [self] in
            while lock.withLock({ running }) {
                let current = ProfileFileImporterTests.residentMemoryBytes()
                lock.withLock { peak = max(peak, current) }
                Thread.sleep(forTimeInterval: 0.001)
            }
        }
    }

    func stopAndPeakGrowth() -> UInt64 {
        lock.withLock { running = false }
        queue.sync {}
        return lock.withLock { peak > baseline ? peak - baseline : 0 }
    }
}
