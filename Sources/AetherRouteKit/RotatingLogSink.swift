import Foundation

public struct RotatingLogSinkStatistics: Sendable, Equatable {
    public let written: Int
    public let dropped: Int
    public let rotations: Int
}

/// Bounded, rotating, append-only file sink.
///
/// Two properties matter more than throughput here:
///
/// 1. `append` must never block. It runs on the connection hot path, so it
///    only takes a lock, appends to a bounded array, and returns. All file I/O
///    happens on a private serial queue.
/// 2. Disk use must be bounded regardless of how long the product runs.
///    `maximumFileBytes * maximumFileCount` is a hard ceiling per process.
///
/// Under sustained pressure the sink drops the oldest pending records and
/// counts them rather than growing memory or stalling the caller. A dropped
/// count is recorded so a gap in the log is visible instead of silent.
public final class RotatingLogSink: @unchecked Sendable {
    public struct Configuration: Sendable {
        public let directoryURL: URL
        public let baseName: String
        public let maximumFileBytes: Int
        public let maximumFileCount: Int
        public let maximumPendingRecords: Int

        public init(
            directoryURL: URL,
            baseName: String,
            maximumFileBytes: Int = 4 * 1_024 * 1_024,
            maximumFileCount: Int = 4,
            maximumPendingRecords: Int = 2_000
        ) {
            self.directoryURL = directoryURL
            self.baseName = baseName
            self.maximumFileBytes = max(1, maximumFileBytes)
            self.maximumFileCount = max(1, maximumFileCount)
            self.maximumPendingRecords = max(1, maximumPendingRecords)
        }
    }

    private let configuration: Configuration
    private let fileManager: FileManager
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var pending: [String] = []
    private var draining = false
    private var written = 0
    private var dropped = 0
    private var rotations = 0

    public init(
        configuration: Configuration,
        fileManager: FileManager = .default
    ) {
        self.configuration = configuration
        self.fileManager = fileManager
        queue = DispatchQueue(
            label: "com.aetherroute.desktop.log-sink.\(configuration.baseName)",
            qos: .utility
        )
    }

    public var currentFileURL: URL {
        configuration.directoryURL.appendingPathComponent(
            "\(configuration.baseName).log",
            isDirectory: false
        )
    }

    public func statistics() -> RotatingLogSinkStatistics {
        lock.lock()
        defer { lock.unlock() }
        return RotatingLogSinkStatistics(
            written: written,
            dropped: dropped,
            rotations: rotations
        )
    }

    /// Non-blocking. Safe to call from any thread, including a flow callback.
    public func append(_ line: String) {
        var shouldSchedule = false
        lock.lock()
        if pending.count >= configuration.maximumPendingRecords {
            // Drop oldest: the newest records describe the current problem.
            pending.removeFirst()
            dropped += 1
        }
        pending.append(line)
        if !draining {
            draining = true
            shouldSchedule = true
        }
        lock.unlock()

        guard shouldSchedule else { return }
        queue.async { [weak self] in self?.drain() }
    }

    /// Drains and calls back once the queue is empty. Tests use this; the
    /// product never needs to wait on logging.
    public func flush(completion: @escaping @Sendable () -> Void) {
        queue.async { [weak self] in
            self?.drain()
            completion()
        }
    }

    private func drain() {
        while true {
            lock.lock()
            let batch = pending
            pending.removeAll(keepingCapacity: true)
            if batch.isEmpty {
                draining = false
                lock.unlock()
                return
            }
            lock.unlock()

            write(batch)
        }
    }

    private func write(_ batch: [String]) {
        guard !batch.isEmpty else { return }
        try? fileManager.createDirectory(
            at: configuration.directoryURL,
            withIntermediateDirectories: true
        )

        // A batch can exceed the per-file ceiling on its own, so it is split
        // against the remaining capacity instead of written whole. Checking the
        // size only once per batch let a single drain blow straight past the
        // cap, which defeats the point of a bounded sink.
        var currentSize = fileSize(of: currentFileURL)
        var chunk = Data()
        var chunkCount = 0

        for line in batch {
            let record = Data((line + "\n").utf8)
            // `currentSize + chunk.count` is what the file will hold once the
            // pending chunk lands. Testing `currentSize` alone never rotated a
            // batch written into a fresh file, because it stayed zero for the
            // whole loop. The second clause keeps an empty file from rotating
            // forever when a single record exceeds the ceiling.
            if currentSize + chunk.count > 0,
               currentSize + chunk.count + record.count
               > configuration.maximumFileBytes {
                flush(chunk, records: chunkCount)
                chunk.removeAll(keepingCapacity: true)
                chunkCount = 0
                rotate()
                currentSize = 0
            }
            chunk.append(record)
            chunkCount += 1
        }
        flush(chunk, records: chunkCount)
    }

    private func flush(_ payload: Data, records: Int) {
        guard !payload.isEmpty else { return }
        let url = currentFileURL
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            lock.lock(); dropped += records; lock.unlock()
            return
        }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: payload)
            lock.lock(); written += records; lock.unlock()
        } catch {
            lock.lock(); dropped += records; lock.unlock()
        }
    }

    private func fileSize(of url: URL) -> Int {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? Int) ?? 0
    }

    private func rotate() {
        // Discard the oldest, then shift every survivor one slot older.
        let oldest = rotatedURL(index: configuration.maximumFileCount - 1)
        try? fileManager.removeItem(at: oldest)
        var index = configuration.maximumFileCount - 1
        while index > 1 {
            let source = rotatedURL(index: index - 1)
            let destination = rotatedURL(index: index)
            if fileManager.fileExists(atPath: source.path) {
                try? fileManager.moveItem(at: source, to: destination)
            }
            index -= 1
        }
        if configuration.maximumFileCount > 1 {
            try? fileManager.moveItem(at: currentFileURL, to: rotatedURL(index: 1))
        } else {
            try? fileManager.removeItem(at: currentFileURL)
        }
        lock.lock()
        rotations += 1
        lock.unlock()
    }

    private func rotatedURL(index: Int) -> URL {
        configuration.directoryURL.appendingPathComponent(
            "\(configuration.baseName).\(index).log",
            isDirectory: false
        )
    }
}
