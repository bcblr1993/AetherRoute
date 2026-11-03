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
        var realtime3s = TrafficHistory()
        for i in stride(from: 0, through: 60, by: 3) {
            realtime3s.append(download: Double(i), upload: 0, at: origin.addingTimeInterval(Double(i)))
        }
        precondition(realtime3s.samples.count == 11)
        precondition(realtime3s.samples.first?.download == 30)
        precondition(realtime3s.samples.last?.download == 60)
        precondition(background.visible(at: origin.addingTimeInterval(-1)).isEmpty)

        var idleHistory = TrafficHistory()
        precondition(!idleHistory.hasActiveTraffic, "Empty history must report no active traffic")
        idleHistory.append(download: 0, upload: 0, at: origin)
        idleHistory.append(download: 0, upload: 0, at: origin.addingTimeInterval(3))
        precondition(!idleHistory.hasActiveTraffic, "Zero-rate history samples must report no active traffic so 12 FPS TimelineView pauses")
        idleHistory.append(download: 512, upload: 0, at: origin.addingTimeInterval(6))
        precondition(idleHistory.hasActiveTraffic, "Non-zero rate sample must activate traffic history animation")
        print("Traffic history passed: 1s/3s/10s samples, 30s retention, time axis, gaps, coalescing, clock rollback, active-traffic detection.")
    }
}
