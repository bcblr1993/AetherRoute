import AetherRouteKit
import AppKit
import SwiftUI

/// Second first-run page, after the privacy disclosure: grants both network
/// engines' system permissions up front. The main window opens only when
/// every engine is ready, so connecting or switching engines later never
/// stops for a system prompt. Also shown as a sheet from Overview when a
/// permission was later withdrawn (`isOnboarding == false`).
struct NetworkSetupView: View {
    @EnvironmentObject private var tunnel: TunnelManager
    var isOnboarding = true
    var onClose: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(spacing: AetherVisual.s6) {
                header
                VStack(spacing: AetherVisual.s3) {
                    ForEach(tunnel.networkSetupEngines) { mode in
                        NetworkSetupEngineCard(
                            mode: mode,
                            state: tunnel.networkSetupStates[mode] ?? .checking
                        )
                    }
                }
                // Once everything is granted the "what you will be asked"
                // steps are history.
                if primaryAction != .finish {
                    NetworkSetupGuide(activeStep: activeGuideStep)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, AetherVisual.s6)
            .padding(.top, isOnboarding ? AetherVisual.onboardingTopPadding : AetherVisual.s6)
            .padding(.bottom, AetherVisual.s6)
            .frame(maxWidth: AetherVisual.formMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            actionBar
                .frame(maxWidth: .infinity)
                .padding(.horizontal, AetherVisual.s6)
                .padding(.vertical, AetherVisual.s4)
                .background(.regularMaterial)
                .overlay(alignment: .top) { Divider() }
        }
        .animation(AetherVisual.animation(AetherVisual.gentleSpring), value: tunnel.networkSetupStates)
        .task { await tunnel.refreshNetworkSetupStatus() }
        // Switching the extension on happens in System Settings; coming back
        // re-reads what was granted.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await tunnel.refreshNetworkSetupStatus() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("network-setup")
    }

    private var states: [NetworkSetupStepState] { tunnel.orderedNetworkSetupStates }

    private var primaryAction: NetworkSetupProgress.PrimaryAction {
        NetworkSetupProgress.primaryAction(for: states, isRunning: tunnel.isRunningNetworkSetup)
    }

    /// Which of the two things the user has to do is happening now.
    private var activeGuideStep: NetworkSetupGuide.Step? {
        if states.contains(.awaitingApproval) || states.contains(.installingExtension) { return .approveExtension }
        if states.contains(.awaitingConfigurationConsent) { return .allowConfiguration }
        return nil
    }

    private var header: some View {
        VStack(spacing: AetherVisual.s3) {
            ZStack(alignment: .bottomTrailing) {
                AetherRouteBrandTile(size: 72)
                Image(systemName: "lock.shield.fill")
                    .font(.title2)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.accentColor)
                    .padding(AetherVisual.sMicro)
                    .background(Color(nsColor: .windowBackgroundColor), in: Circle())
                    .offset(x: AetherVisual.s1, y: AetherVisual.s1)
            }
            .accessibilityHidden(true)

            VStack(spacing: AetherVisual.s2) {
                if isOnboarding {
                    Text(AppLocalization.string("Step 2 of 2"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AetherVisual.secondaryText)
                }
                Text(AppLocalization.string("Set Up Network Permissions"))
                    .font(.largeTitle.weight(.bold))
                Text(AppLocalization.string("AetherRoute needs two macOS permissions for each network engine. Grant them once now, and connecting or switching engines later will never stop for a prompt."))
                    .font(.subheadline)
                    .foregroundStyle(AetherVisual.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var actionBar: some View {
        VStack(spacing: AetherVisual.s2) {
            HStack(spacing: AetherVisual.s3) {
                if !isOnboarding, let onClose {
                    Button(AppLocalization.string("Later"), action: onClose)
                        .controlSize(.large)
                        .keyboardShortcut(.cancelAction)
                }
                if states.contains(.awaitingApproval) {
                    Button(AppLocalization.string("Open System Settings"), systemImage: "gearshape") {
                        tunnel.openNetworkExtensionSettings()
                    }
                    .controlSize(.large)
                    .accessibilityIdentifier("network-setup-open-settings")
                }
                primaryButton
            }
            if let footnote {
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(AetherVisual.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
    }

    private var primaryButton: some View {
        Button {
            Task {
                switch primaryAction {
                case .start, .retry:
                    await tunnel.runNetworkSetup()
                case .finish:
                    await tunnel.finishNetworkSetup()
                    onClose?()
                case .waiting, .restartRequired:
                    break
                }
            }
        } label: {
            HStack(spacing: AetherVisual.s2) {
                if primaryAction == .waiting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: primarySymbol)
                }
                Text(primaryTitle)
            }
            .font(.title3.weight(.semibold))
            .frame(minWidth: 220)
            .padding(.vertical, AetherVisual.s1)
            .contentTransition(.opacity)
        }
        .aetherGlassButton(prominent: true)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
        .disabled(primaryAction == .waiting || primaryAction == .restartRequired)
        .accessibilityIdentifier("network-setup-primary")
    }

    private var primaryTitle: String {
        switch primaryAction {
        case .start: AppLocalization.string("Start Setup")
        case .waiting: AppLocalization.string("Waiting for Permission…")
        case .retry: AppLocalization.string("Retry")
        case .finish: isOnboarding
            ? AppLocalization.string("Start Using AetherRoute")
            : AppLocalization.string("Done")
        case .restartRequired: AppLocalization.string("Restart to Continue")
        }
    }

    private var primarySymbol: String {
        switch primaryAction {
        case .start: "checkmark.shield.fill"
        case .retry: "arrow.clockwise"
        case .finish: "arrow.right.circle.fill"
        case .waiting, .restartRequired: "arrow.clockwise.circle"
        }
    }

    private var footnote: String? {
        switch primaryAction {
        case .start:
            return AppLocalization.string("Nothing connects during setup. AetherRoute only asks macOS for permission.")
        case .restartRequired:
            return AppLocalization.string("macOS finishes installing the extension after a restart. Open AetherRoute again afterwards to continue.")
        case .finish:
            let unavailable = tunnel.networkSetupEngines.filter {
                tunnel.networkSetupStates[$0]?.isBlockedPermanently ?? false
            }
            guard let blocked = unavailable.first else { return nil }
            return String.localizedStringWithFormat(
                AppLocalization.string("%@ is not available on this Mac. You can still use the other engine."),
                blocked.localizedTitle
            )
        case .waiting, .retry:
            return nil
        }
    }
}

/// One engine's row: what it does and where its permission stands.
private struct NetworkSetupEngineCard: View {
    let mode: NetworkEngineMode
    let state: NetworkSetupStepState

    var body: some View {
        HStack(alignment: .top, spacing: AetherVisual.s4) {
            AetherIconTile(
                symbol: mode == .tun ? "bolt.shield.fill" : "network",
                color: .blue,
                size: AetherVisual.sheetIconSize
            )
            VStack(alignment: .leading, spacing: AetherVisual.s1) {
                HStack(alignment: .firstTextBaseline) {
                    Text(mode.localizedTitle)
                        .font(.headline)
                    Spacer(minLength: AetherVisual.s2)
                    NetworkSetupStatusBadge(state: state)
                }
                Text(mode.localizedDetail)
                    .font(.subheadline)
                    .foregroundStyle(AetherVisual.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let hint {
                    Text(hint)
                        .font(.callout)
                        .foregroundStyle(hintColor)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, AetherVisual.s1)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .padding(AetherVisual.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .aetherPanel()
        .overlay {
            RoundedRectangle(cornerRadius: AetherVisual.panelRadius, style: .continuous)
                .stroke(borderColor, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("network-setup-\(mode.rawValue)")
    }

    private var hint: String? {
        switch state {
        case .awaitingApproval:
            AppLocalization.string("In System Settings › General › Login Items & Extensions › Network Extensions, switch on AetherRoute.")
        case .awaitingConfigurationConsent:
            AppLocalization.string("Choose Allow when macOS asks to add the AetherRoute configuration.")
        case let .failed(reason, _):
            reason
        case .rebootRequired:
            AppLocalization.string("Available after this Mac restarts.")
        default:
            nil
        }
    }

    private var hintColor: Color {
        if case .failed = state { return .red }
        return .primary
    }

    private var borderColor: Color {
        switch state {
        case .ready: AetherVisual.tintBorder(.green)
        case .awaitingApproval, .awaitingConfigurationConsent: AetherVisual.tintBorder(.accentColor)
        case .failed: AetherVisual.tintBorder(.red)
        default: Color.clear
        }
    }
}

private struct NetworkSetupStatusBadge: View {
    let state: NetworkSetupStepState

    var body: some View {
        HStack(spacing: AetherVisual.sCompact) {
            if showsSpinner {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: symbol)
                    .symbolEffect(.bounce, value: state == .ready)
            }
            Text(title)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, AetherVisual.pillHorizontalPadding)
        .padding(.vertical, AetherVisual.pillVerticalPadding)
        .background(AetherVisual.tintFill(color), in: Capsule())
        .contentTransition(.opacity)
    }

    private var showsSpinner: Bool {
        state == .checking || state == .installingExtension || state == .awaitingConfigurationConsent
    }

    private var title: String {
        switch state {
        case .checking: AppLocalization.string("Checking")
        case .pending: AppLocalization.string("Not set up")
        case .installingExtension: AppLocalization.string("Installing")
        case .awaitingApproval: AppLocalization.string("Waiting for you")
        case .awaitingConfigurationConsent: AppLocalization.string("Waiting for you")
        case .ready: AppLocalization.string("Ready")
        case .rebootRequired: AppLocalization.string("Restart needed")
        case let .failed(_, isRetryable): isRetryable
            ? AppLocalization.string("Not finished")
            : AppLocalization.string("Unavailable")
        }
    }

    private var symbol: String {
        switch state {
        case .ready: "checkmark.circle.fill"
        case .awaitingApproval: "hand.tap.fill"
        case .rebootRequired: "arrow.clockwise.circle"
        case .failed: "exclamationmark.triangle.fill"
        default: "circle.dashed"
        }
    }

    private var color: Color {
        switch state {
        case .ready: .green
        case .awaitingApproval, .awaitingConfigurationConsent: .accentColor
        case .rebootRequired: .orange
        case .failed: .red
        default: .secondary
        }
    }
}

/// The two things only the user can do, with the current one highlighted.
struct NetworkSetupGuide: View {
    enum Step: Int, CaseIterable {
        case approveExtension = 1
        case allowConfiguration = 2
    }

    let activeStep: Step?

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s3) {
            Text(AppLocalization.string("What you will be asked"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AetherVisual.secondaryText)
            ForEach(Step.allCases, id: \.self) { step in
                HStack(alignment: .top, spacing: AetherVisual.s3) {
                    Text(verbatim: "\(step.rawValue)")
                        .font(.callout.weight(.bold).monospacedDigit())
                        .foregroundStyle(step == activeStep ? AnyShapeStyle(Color.white) : AnyShapeStyle(AetherVisual.secondaryText))
                        .frame(width: AetherVisual.s5, height: AetherVisual.s5)
                        .background(step == activeStep ? Color.accentColor : AetherVisual.neutralFill, in: Circle())
                    VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                        Text(title(step))
                            .font(.callout.weight(.semibold))
                        Text(detail(step))
                            .font(.caption)
                            .foregroundStyle(AetherVisual.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .opacity(activeStep == nil || step == activeStep ? 1 : 0.55)
            }
        }
        .padding(AetherVisual.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .aetherPanel()
        .animation(AetherVisual.animation(AetherVisual.gentleSpring), value: activeStep)
    }

    private func title(_ step: Step) -> String {
        switch step {
        case .approveExtension: AppLocalization.string("Switch on the network extensions")
        case .allowConfiguration: AppLocalization.string("Allow the configurations")
        }
    }

    private func detail(_ step: Step) -> String {
        switch step {
        case .approveExtension:
            AppLocalization.string("macOS opens Login Items & Extensions. Under Network Extensions, switch on both AetherRoute entries. You may need your password or Touch ID.")
        case .allowConfiguration:
            AppLocalization.string("macOS asks whether AetherRoute may add proxy and VPN configurations. Choose Allow for each.")
        }
    }
}
