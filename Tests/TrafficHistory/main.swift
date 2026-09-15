import Foundation

@main struct TrafficHistoryTests {
    static func main() {
        let origin = Date(timeIntervalSince1970: 1_000)
        var history = TrafficHistory()
        for i in 0...60 {
            history.append(download: Double(i), upload: 0, at: origin.addingTimeInterval(Double(i)))
        }
        precondition(history.samples.count == 31)
        precondition(history.samples.first?.download == 30)
        var background = TrafficHistory()
        for i in stride(from: 0, through: 60, by: 10) {
            background.append(download: Double(i), upload: 0, at: origin.addingTimeInterval(Double(i)))
        }
        precondition(background.samples.map(\.download) == [30, 40, 50, 60])
        let now = origin.addingTimeInterval(60)
        precondition(TrafficHistory.position(of: background.samples[1], at: now) > 0.33)
        precondition(TrafficHistory.position(of: background.samples[1], at: now) < 0.34)
        precondition(background.visible(at: origin.addingTimeInterval(91)).isEmpty)
        background.append(download: 9, upload: 7, at: origin.addingTimeInterval(120))
        precondition(background.samples.count == 1, "A long gap must not fabricate 30 seconds of samples")
        background.append(download: 10, upload: 8, at: origin.addingTimeInterval(120.2))
        precondition(background.samples.count == 1 && background.samples[0].download == 10)
        background.append(download: 2, upload: 0, at: origin)
        precondition(background.samples.count == 1 && background.samples[0].date == origin)
        precondition(background.visible(at: origin.addingTimeInterval(-1)).isEmpty)
        print("Traffic history passed: 1s/10s samples, 30s retention, time axis, gaps, coalescing, clock rollback.")
    }
}
