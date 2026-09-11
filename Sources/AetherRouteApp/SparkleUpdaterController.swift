import AppKit
import Combine
import Foundation
import Sparkle
import SwiftUI

@MainActor
final class SparkleUpdaterController: NSObject, ObservableObject {
    static let shared = SparkleUpdaterController()

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = true
    @Published private(set) var lastUpdateCheckDate: Date?

    private var updaterController: SPUStandardUpdaterController?
    private var cancellables = Set<AnyCancellable>()

    override private init() {
        super.init()

        // SPUStandardUpdaterController manages the complete lifecycle of SPUUpdater
        // and provides standard user-facing update UI.
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        self.updaterController = controller

        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] canCheck in
                self?.canCheckForUpdates = canCheck
            }
            .store(in: &cancellables)

        controller.updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] autoCheck in
                self?.automaticallyChecksForUpdates = autoCheck
            }
            .store(in: &cancellables)

        controller.updater.publisher(for: \.lastUpdateCheckDate)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] lastDate in
                self?.lastUpdateCheckDate = lastDate
            }
            .store(in: &cancellables)
    }

    var updater: SPUUpdater? {
        updaterController?.updater
    }

    func checkForUpdates() {
        guard let updater = updaterController?.updater, updater.canCheckForUpdates else {
            return
        }
        updater.checkForUpdates()
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        updaterController?.updater.automaticallyChecksForUpdates = enabled
    }
}

extension SparkleUpdaterController: SPUUpdaterDelegate {
    // SPUUpdaterDelegate hooks can be extended here for custom telemetry if desired.
}

/// A standard Check for Updates button suitable for SwiftUI Menu commands.
struct CheckForUpdatesCommandButton: View {
    @ObservedObject var controller = SparkleUpdaterController.shared

    var body: some View {
        Button(AppLocalization.string("Check for Updates…")) {
            controller.checkForUpdates()
        }
        .disabled(!controller.canCheckForUpdates)
    }
}
