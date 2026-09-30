import Foundation

/// Per-process owner of the shared level and the rotating file sink.
///
/// The host app and both Network Extensions are separate processes, so each
/// writes its own file. Sharing one file across processes would need file
/// locking on the connection hot path, which is exactly what this design is
/// trying to avoid.
///
/// Everything degrades to "no file, os_log only" when the App Group is
/// unavailable. Diagnostics must never be able to prevent the product from
/// running.
public final class DiagnosticLogCenter: @unchecked Sendable {
    public static let current = DiagnosticLogCenter()

    public static let logsDirectoryName = "Logs"

    private let sink: RotatingLogSink?
    private let levelCache: DiagnosticLogLevelCache?
    private let lock = NSLock()
    private var logs: [String: DiagnosticLog] = [:]
    private var levelOverride: DiagnosticLogLevel?

    /// Derived from the bundle identifier so each process lands in its own
    /// file without any caller having to name itself.
    public let processName: String

    private init() {
        let identifier = Bundle.main.bundleIdentifier ?? "app"
        processName = Self.processName(for: identifier)

        let isRunningInTest = NSClassFromString("XCTestCase") != nil ||
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        if !isRunningInTest,
           let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppConstants.appGroup
        ) {
            let support = container.appendingPathComponent(
                "Library/Application Support/AetherRoute",
                isDirectory: true
            )
            sink = RotatingLogSink(
                configuration: .init(
                    directoryURL: support.appendingPathComponent(
                        Self.logsDirectoryName,
                        isDirectory: true
                    ),
                    baseName: processName
                )
            )
            levelCache = DiagnosticLogLevelCache(
                store: DiagnosticLogLevelStore(directoryURL: support)
            )
        } else {
            sink = nil
            levelCache = nil
        }
    }

    static func processName(for bundleIdentifier: String) -> String {
        if bundleIdentifier.hasSuffix(".transparent-proxy") {
            return "transparent-proxy"
        }
        if bundleIdentifier.hasSuffix(".tunnel") { return "tunnel" }
        return "app"
    }

    public var level: DiagnosticLogLevel {
        lock.lock()
        let override = levelOverride
        lock.unlock()
        return override ?? levelCache?.level() ?? .off
    }

    /// A Developer ID system extension runs as root, so its App Group
    /// container is not the one the app writes the level file into. The host
    /// sends the level in the launch snapshot instead; `nil` returns to the
    /// file-backed level.
    public func applyLevelOverride(_ level: DiagnosticLogLevel?) {
        lock.lock()
        defer { lock.unlock() }
        levelOverride = level
    }

    public func log(category: String) -> DiagnosticLog {
        lock.lock()
        if let existing = logs[category] {
            lock.unlock()
            return existing
        }
        lock.unlock()

        let created = DiagnosticLog(
            category: category,
            sink: sink,
            levelProvider: { [unowned self] in self.level }
        )
        lock.lock()
        defer { lock.unlock() }
        // Another thread may have created it while we were outside the lock.
        if let existing = logs[category] { return existing }
        logs[category] = created
        return created
    }
}
