import AetherRouteKit
import Foundation
import OSLog

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
        if !enabled { saveTrafficLedgerIfNeeded(force: true) }
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
        trafficLedgerRevision &+= 1
        guard !isUIReviewMode else { return }
        trafficStatisticsWriter.clear { succeeded in
            if !succeeded {
                Task { @MainActor in
                    Self.runtimeLogger.error("stage=clearTrafficStatistics failed")
                }
            }
        }
    }

    func recordTrafficStatistics(_ snapshot: NetworkTelemetrySnapshot, now: Date = .now) {
        guard isTrafficStatisticsEnabled, !isUIReviewMode else { return }
        loadTrafficLedgerIfNeeded()
        let directory = SourceAppDirectory.shared
        let sample = trafficAccumulator.ingest(
            snapshot, sessionStartedAt: manager?.connection.connectedDate
        ) { identifier, path in
            let app = directory.presentation(identifier: identifier, path: path)
            return .init(key: app.groupingKey, name: app.displayName)
        }
        guard !sample.isEmpty else { return }
        trafficLedger.add(sample, day: TrafficStatisticsLedger.dayKey(for: now))
        hasUnsavedTrafficSamples = true
        trafficLedgerRevision &+= 1
        saveTrafficLedgerIfNeeded(now: now)
    }

    func saveTrafficLedgerIfNeeded(now: Date = .now, force: Bool = false) {
        // Never write a ledger that was not read first (it would replace the
        // saved history with an empty one) or one with nothing new.
        guard !isUIReviewMode,
              isTrafficLedgerLoaded, hasUnsavedTrafficSamples
        else { return }
        if !force, let saved = trafficLedgerSavedAt,
           now.timeIntervalSince(saved) < Self.trafficLedgerSaveInterval {
            return
        }
        trafficLedgerSavedAt = now
        let ledger = trafficLedger
        let revision = trafficLedgerRevision
        trafficStatisticsWriter.save(ledger) { [weak self] succeeded in
            Task { @MainActor [weak self] in
                guard let self, self.trafficLedgerRevision == revision else { return }
                if succeeded {
                    self.hasUnsavedTrafficSamples = false
                } else {
                    self.trafficLedgerSavedAt = nil
                    Self.runtimeLogger.error("stage=saveTrafficStatistics failed")
                }
            }
        }
    }
}
