import AetherRouteKit
import AppKit
import SwiftUI

/// Second and third first-run pages, after the privacy disclosure: grants
/// both network engines' system permissions up front, then confirms that
/// everything is ready. The main window opens only after that, so connecting
/// or switching engines later never stops for a system prompt. Also shown as
/// a sheet from Overview when a permission was later withdrawn
/// (`isOnboarding == false`), without the dots or the final page.
struct NetworkSetupView: View {
    @EnvironmentObject private var tunnel: TunnelManager
    var isOnboarding = true
    var onClose: (() -> Void)?
    /// Page 3: everything is granted and the first run is about to end.
    @State private var showsCompletion = false

    var body: some View {
        ZStack {
            if showsCompletion {
                completionPage
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            } else {
                permissionsPage
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .animation(AetherVisual.animation(AetherVisual.gentleSpring), value: tunnel.networkSetupStates)
        .animation(AetherVisual.animation(AetherVisual.panelSpring), value: showsCompletion)
        .task { await tunnel.refreshNetworkSetupStatus() }
        // Switching the extension on happens in System Settings; coming back
        // re-reads what was granted.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await tunnel.refreshNetworkSetupStatus() }
        }
    }

    private var states: [NetworkSetupStepState] { tunnel.orderedNetworkSetupStates }

    private var primaryAction: NetworkSetupProgress.PrimaryAction {
        NetworkSetupProgress.primaryAction(for: states, isRunning: tunnel.isRunningNetworkSetup)
    }

    // MARK: Page 2 — permissions

    private var permissionsPage: some View {
        OnboardingPage(
            page: isOnboarding ? 1 : nil,
            title: AppLocalization.string("Allow AetherRoute to route your traffic?"),
            lead: AppLocalization.string("Grant this once, and connecting or switching engines later never stops for a prompt."),
            footnote: footnote,
            accessibilityIdentifier: "network-setup"
        ) {
            OnboardingNetworkIllustration()
        } content: {
            OnboardingCard(rows: tunnel.networkSetupEngines.map(engineRow))
        } actions: {
            HStack(spacing: AetherVisual.s3) {
                if !isOnboarding, let onClose {
                    Button(AppLocalization.string("Later"), action: onClose)
                        .aetherGlassButton()
                        .controlSize(.extraLarge)
                        .keyboardShortcut(.cancelAction)
                }
                OnboardingPrimaryButton(
                    title: primaryTitle,
                    isWorking: primaryAction == .waiting,
                    isEnabled: primaryAction != .waiting && primaryAction != .restartRequired,
                    identifier: "network-setup-primary",
                    action: performPrimaryAction
                )
            }
        }
    }

    private func engineRow(_ mode: NetworkEngineMode) -> OnboardingCardRow {
        let state = tunnel.networkSetupStates[mode] ?? .checking
        let runSetup = { Task { await tunnel.runNetworkSetup() } }
        let detail: String
        var isError = false
        let accessory: OnboardingCardRow.Accessory
        switch state {
        case .checking, .installingExtension:
            detail = mode.localizedDetail
            accessory = .waiting
        case .pending:
            detail = mode.localizedDetail
            accessory = .action(
                title: AppLocalization.string("Allow"),
                identifier: "network-setup-allow-\(mode.rawValue)",
                perform: { _ = runSetup() }
            )
        case .awaitingApproval:
            detail = AppLocalization.string("In System Settings › General › Login Items & Extensions › Network Extensions, switch on AetherRoute.")
            accessory = .action(
                title: AppLocalization.string("Open System Settings"),
                identifier: "network-setup-open-settings-\(mode.rawValue)",
                perform: { tunnel.openNetworkExtensionSettings() }
            )
        case .awaitingConfigurationConsent:
            detail = AppLocalization.string("Choose Allow when macOS asks to add the AetherRoute configuration.")
            accessory = .waiting
        case .ready:
            detail = mode.localizedDetail
            accessory = .granted
        case .rebootRequired:
            detail = AppLocalization.string("Available after this Mac restarts.")
            accessory = .restartNeeded
        case let .failed(reason, isRetryable):
            detail = reason
            isError = true
            accessory = isRetryable
                ? .retry(
                    title: AppLocalization.string("Retry"),
                    identifier: "network-setup-retry-\(mode.rawValue)",
                    perform: { _ = runSetup() }
                )
                : .unavailable
        }
        return OnboardingCardRow(
            id: "network-setup-\(mode.rawValue)",
            symbol: mode == .tun ? "bolt.shield" : "network",
            title: mode.localizedTitle,
            detail: detail,
            detailIsError: isError,
            accessory: accessory
        )
    }

    private func performPrimaryAction() {
        Task {
            switch primaryAction {
            case .start, .retry:
                await tunnel.runNetworkSetup()
            case .finish:
                if isOnboarding {
                    showsCompletion = true
                } else {
                    await tunnel.finishNetworkSetup()
                    onClose?()
                }
            case .waiting, .restartRequired:
                break
            }
        }
    }

    private var primaryTitle: String {
        switch primaryAction {
        case .start: AppLocalization.string("Start Setup")
        case .waiting: AppLocalization.string("Waiting for Permission…")
        case .retry: AppLocalization.string("Retry")
        case .finish: isOnboarding
            ? AppLocalization.string("Continue")
            : AppLocalization.string("Done")
        case .restartRequired: AppLocalization.string("Restart to Continue")
        }
    }

    private var footnote: String? {
        switch primaryAction {
        case .start:
            return AppLocalization.string("Nothing connects during setup. AetherRoute only asks macOS for permission.")
        case .restartRequired:
            return AppLocalization.string("macOS finishes installing the extension after a restart. Open AetherRoute again afterwards to continue.")
        case .finish:
            return unavailableEngineNote
        case .waiting, .retry:
            return nil
        }
    }

    private var unavailableEngineNote: String? {
        let unavailable = tunnel.networkSetupEngines.filter {
            tunnel.networkSetupStates[$0]?.isBlockedPermanently ?? false
        }
        guard let blocked = unavailable.first else { return nil }
        return String.localizedStringWithFormat(
            AppLocalization.string("%@ is not available on this Mac. You can still use the other engine."),
            blocked.localizedTitle
        )
    }

    // MARK: Page 3 — all set

    private var completionPage: some View {
        OnboardingPage(
            page: 2,
            title: AppLocalization.string("You're all set"),
            lead: AppLocalization.string("AetherRoute has every permission it needs. Turn on the switch to start routing your traffic."),
            footnote: unavailableEngineNote,
            accessibilityIdentifier: "onboarding-complete"
        ) {
            OnboardingDoneIllustration()
        } content: {
            OnboardingCard(rows: completionRows)
        } actions: {
            OnboardingPrimaryButton(
                title: AppLocalization.string("Start Using AetherRoute"),
                identifier: "onboarding-start-using",
                action: {
                    Task { await tunnel.finishNetworkSetup() }
                }
            )
        }
    }

    private var completionRows: [OnboardingCardRow] {
        var rows = [
            OnboardingCardRow(
                id: "completion-privacy",
                symbol: "hand.raised",
                title: AppLocalization.string("Privacy commitments"),
                detail: AppLocalization.string("Accepted"),
                accessory: .granted
            ),
        ]
        rows += tunnel.networkSetupEngines.map { mode in
            let isReady = tunnel.networkSetupStates[mode]?.isReady ?? false
            return OnboardingCardRow(
                id: "completion-\(mode.rawValue)",
                symbol: mode == .tun ? "bolt.shield" : "network",
                title: mode.localizedTitle,
                detail: isReady ? mode.localizedDetail : AppLocalization.string("Unavailable"),
                accessory: isReady ? .granted : .unavailable
            )
        }
        return rows
    }
}
