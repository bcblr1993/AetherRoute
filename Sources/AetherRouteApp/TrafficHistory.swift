import Darwin
import Foundation

/// Reads the current process's physical memory footprint (`phys_footprint`),
/// matching the "Memory" column in macOS Activity Monitor.
enum ProcessMemoryFootprint {
    static func currentBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info.phys_footprint : 0
    }
}

struct TrafficHistory {
    static let window: TimeInterval = 30
    struct Sample: Equatable {
        let date: Date
        let download: Double
        let upload: Double
        let coreMemoryBytes: UInt64
        let appMemoryBytes: UInt64

        init(
            date: Date,
            download: Double,
            upload: Double,
            coreMemoryBytes: UInt64 = 0,
            appMemoryBytes: UInt64 = 0
        ) {
            self.date = date
            self.download = download
            self.upload = upload
            self.coreMemoryBytes = coreMemoryBytes
            self.appMemoryBytes = appMemoryBytes
        }
    }
    private(set) var samples: [Sample] = []

    /// Whether there are at least two samples with non-zero traffic so a live
    /// waveform needs continuous 12 FPS animation. When all samples in the
    /// window are 0 B/s, the curve is a flat baseline and does not need to
    /// redraw 12 times per second.
    var hasActiveTraffic: Bool {
        samples.count >= 2 && samples.contains { $0.download > 0 || $0.upload > 0 }
    }

    mutating func append(
        download: Double,
        upload: Double,
        coreMemoryBytes: UInt64 = 0,
        appMemoryBytes: UInt64 = 0,
        at date: Date
    ) {
        // A wall-clock correction must not leave future samples on the graph.
        if let last = samples.last, date < last.date { samples.removeAll() }
        samples.removeAll { date.timeIntervalSince($0.date) > Self.window }
        let sample = Sample(
            date: date,
            download: download,
            upload: upload,
            coreMemoryBytes: coreMemoryBytes,
            appMemoryBytes: appMemoryBytes
        )
        // Foreground activation can request an extra snapshot. Coalesce within
        // a second to keep memory bounded without inventing historical zeros.
        if let last = samples.last,
           floor(last.date.timeIntervalSince1970) == floor(date.timeIntervalSince1970) {
            samples[samples.count - 1] = sample
        } else {
            samples.append(sample)
        }
    }

    func visible(at date: Date) -> [Sample] {
        samples.filter { (0...Self.window).contains(date.timeIntervalSince($0.date)) }
    }

    static func position(of sample: Sample, at date: Date) -> Double {
        max(0, min(1, 1 - date.timeIntervalSince(sample.date) / window))
    }

    static func peakCoreMemory(in samples: [Sample]) -> UInt64 {
        samples.map(\.coreMemoryBytes).max() ?? 0
    }

    static func peakAppMemory(in samples: [Sample]) -> UInt64 {
        samples.map(\.appMemoryBytes).max() ?? 0
    }

    /// Maps a memory footprint series into `0...1` with vertical breathing room
    /// (`0.25...0.80`) so a steady footprint draws a calm centered band (`0.5`)
    /// while rises and drops remain clearly visible.
    static func normalizedMemorySeries(_ values: [UInt64]) -> [Double] {
        guard !values.isEmpty else { return [] }
        let nonZero = values.filter { $0 > 0 }
        guard let minVal = nonZero.min(), let maxVal = nonZero.max() else {
            return Array(repeating: 0, count: values.count)
        }
        guard maxVal > minVal else {
            return values.map { $0 > 0 ? 0.5 : 0 }
        }
        let span = Double(maxVal - minVal)
        return values.map { value in
            guard value > 0 else { return 0 }
            let ratio = Double(value - minVal) / span
            return 0.25 + ratio * 0.55
        }
    }
}
