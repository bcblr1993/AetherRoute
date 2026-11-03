import Foundation

struct TrafficHistory {
    static let window: TimeInterval = 30
    struct Sample: Equatable {
        let date: Date
        let download: Double
        let upload: Double
    }
    private(set) var samples: [Sample] = []

    /// Whether there are at least two samples with non-zero traffic so a live
    /// waveform needs continuous 12 FPS animation. When all samples in the
    /// window are 0 B/s, the curve is a flat baseline and does not need to
    /// redraw 12 times per second.
    var hasActiveTraffic: Bool {
        samples.count >= 2 && samples.contains { $0.download > 0 || $0.upload > 0 }
    }

    mutating func append(download: Double, upload: Double, at date: Date) {
        // A wall-clock correction must not leave future samples on the graph.
        if let last = samples.last, date < last.date { samples.removeAll() }
        samples.removeAll { date.timeIntervalSince($0.date) > Self.window }
        let sample = Sample(date: date, download: download, upload: upload)
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
}
