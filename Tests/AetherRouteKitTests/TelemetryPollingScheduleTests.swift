import Testing
@testable import AetherRouteKit

@Suite("Telemetry polling schedule")
struct TelemetryPollingScheduleTests {
    /// Runs the schedule for `seconds` and returns when each action happened.
    private func timeline(_ cadence: TelemetryCadence, seconds: Int) -> (telemetry: [Int], health: [Int]) {
        var schedule = TelemetryPollingSchedule(cadence: cadence, healthIntervalSeconds: 15)
        var clock = 0
        var telemetry: [Int] = []
        var health: [Int] = []
        while clock < seconds {
            let step = schedule.next()
            #expect(step.sleepSeconds > 0)
            clock += step.sleepSeconds
            if step.refreshesTelemetry { telemetry.append(clock) }
            if step.checksRouteHealth { health.append(clock) }
        }
        return (telemetry, health)
    }

    @Test("the strongest demand across surfaces decides the cadence")
    func strongestDemandWins() {
        #expect(TelemetryCadence.resolve(realtimeSources: 1, backgroundSources: 2) == .realtime)
        #expect(TelemetryCadence.resolve(realtimeSources: 0, backgroundSources: 1) == .background)
        #expect(TelemetryCadence.resolve(realtimeSources: 0, backgroundSources: 0) == .healthOnly)
    }

    @Test("frontmost: traffic every 3 s, route health every 15 s")
    func realtimeCadence() {
        let result = timeline(.realtime, seconds: 30)
        #expect(result.telemetry == [3, 6, 9, 12, 15, 18, 21, 24, 27, 30])
        #expect(result.health == [15, 30])
    }

    @Test("visible behind another app: traffic every 10 s, route health still every 15 s")
    func backgroundCadenceKeepsHealthInterval() {
        let result = timeline(.background, seconds: 60)
        #expect(result.telemetry == [10, 20, 30, 40, 50, 60])
        #expect(result.health == [15, 30, 45, 60])
    }

    @Test("nothing visible: no traffic polling, route health every 15 s")
    func healthOnlyCadence() {
        let result = timeline(.healthOnly, seconds: 45)
        #expect(result.telemetry.isEmpty)
        #expect(result.health == [15, 30, 45])
    }
}
