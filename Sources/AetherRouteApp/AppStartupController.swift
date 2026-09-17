import AppKit
import AetherRouteKit
import Combine
import Foundation
import OSLog
import ServiceManagement

@MainActor
final class AppStartupController: ObservableObject {
    static let shared = AppStartupController()
    private static let logger = AppLog.logger(category: AppLog.Category.appLifecycle)

    @Published private(set) var isLaunchAtLoginEnabled: Bool = false
    @Published private(set) var serviceStatus: SMAppService.Status = .notRegistered
    @Published private(set) var errorMessage: String?

    private let isUIReviewMode: Bool

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
#if DEBUG || AETHERROUTE_UI_RESPONSIVENESS
        self.isUIReviewMode = environment["AETHERROUTE_UI_REVIEW"] != nil
#else
        self.isUIReviewMode = false
#endif
        refreshStatus()
    }

    func refreshStatus() {
        if isUIReviewMode {
            serviceStatus = .notRegistered
            isLaunchAtLoginEnabled = false
            return
        }
        serviceStatus = SMAppService.mainApp.status
        isLaunchAtLoginEnabled = (serviceStatus == .enabled)
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        errorMessage = nil
        if isUIReviewMode {
            isLaunchAtLoginEnabled = enabled
            serviceStatus = enabled ? .enabled : .notRegistered
            return
        }
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status != .notRegistered {
                    try SMAppService.mainApp.unregister()
                }
            }
            refreshStatus()
            Self.logger.info(
                "stage=startup launchAtLogin updated enabled=\(enabled, privacy: .public) status=\(self.serviceStatus.rawValue, privacy: .public)"
            )
        } catch {
            errorMessage = error.localizedDescription
            refreshStatus()
            Self.logger.error(
                "stage=startup launchAtLogin updateFailed error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }
}
