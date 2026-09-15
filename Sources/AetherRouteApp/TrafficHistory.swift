import Foundation

struct TrafficHistory {
    static let window: TimeInterval = 30
    struct Sample: Equatable {
        let date: Date
        let download: Double
        let upload: Double
    }
    private(set) var samples: [Sample] = []

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
