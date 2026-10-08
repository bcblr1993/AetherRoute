import AetherRouteKit
import Foundation

extension TunnelManager {
    static let trafficStatisticsPreferenceKey = "trafficStatisticsEnabled"
    /// How often the ledger is written while traffic flows.
    static let trafficLedgerSaveInterval: TimeInterval = 60

    /// Reads the saved ledger once, before the first sample is added or the
    /// statistics are shown. The file is small (31 days, bounded entries).
    func loadTrafficLedgerIfNeeded() {
        guard !isTrafficLedgerLoaded else { return }
        isTrafficLedgerLoaded = true
        guard !isUIReviewMode else { return }
        trafficLedger = (try? TrafficStatisticsStore.applicationSupport())?.load()
            ?? TrafficStatisticsLedger()
    }

    func setTrafficStatisticsEnabled(_ enabled: Bool) {
        isTrafficStatisticsEnabled = enabled
        userDefaults.set(enabled, forKey: Self.trafficStatisticsPreferenceKey)
        trafficAccumulator.reset()
        // The polling cadence depends on this setting.
        restartTelemetryPolling()
    }

    func clearTrafficStatistics() {
        isTrafficLedgerLoaded = true
        trafficLedger = TrafficStatisticsLedger()
        trafficAccumulator.reset()
        trafficLedgerSavedAt = nil
        hasUnsavedTrafficSamples = false
        Task.detached(priority: .utility) {
            try? TrafficStatisticsStore.applicationSupport().clear()
        }
    }

    func recordTrafficStatistics(_ snapshot: NetworkTelemetrySnapshot, now: Date = .now) {
        guard isTrafficStatisticsEnabled, !isUIReviewMode else { return }
        loadTrafficLedgerIfNeeded()
        let directory = SourceAppDirectory.shared
        let sample = trafficAccumulator.ingest(snapshot) { identifier, path in
            let app = directory.presentation(identifier: identifier, path: path)
            return .init(key: app.groupingKey, name: app.displayName)
        }
        guard !sample.isEmpty else { return }
        trafficLedger.add(sample, day: TrafficStatisticsLedger.dayKey(for: now))
        hasUnsavedTrafficSamples = true
        saveTrafficLedgerIfNeeded(now: now)
    }

    func saveTrafficLedgerIfNeeded(now: Date = .now, force: Bool = false) {
        // Never write a ledger that was not read first (it would replace the
        // saved history with an empty one) or one with nothing new.
        guard isTrafficStatisticsEnabled, !isUIReviewMode,
              isTrafficLedgerLoaded, hasUnsavedTrafficSamples
        else { return }
        if !force, let saved = trafficLedgerSavedAt,
           now.timeIntervalSince(saved) < Self.trafficLedgerSaveInterval {
            return
        }
        trafficLedgerSavedAt = now
        hasUnsavedTrafficSamples = false
        let ledger = trafficLedger
        Task.detached(priority: .utility) {
            try? TrafficStatisticsStore.applicationSupport().save(ledger)
        }
    }
}
