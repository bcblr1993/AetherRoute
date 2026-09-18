import AppKit
import AetherRouteKit
import Foundation
import Network
@preconcurrency import SystemConfiguration

/// Observes environment transitions without changing network state. The first
/// NWPath snapshot is treated as a baseline; only later changes are forwarded.
@MainActor
final class AppRuntimeEnvironmentController: ObservableObject {
    private let tunnel: TunnelManager
    private let pathQueue = DispatchQueue(
        label: "com.example.aetherroute.runtime-path",
        qos: .utility
    )
    private var workspaceObservers: [NSObjectProtocol] = []
#if AETHERROUTE_QA_AUTOMATION
    private var qaPowerObservers: [NSObjectProtocol] = []
#endif
    private var pathMonitor: NWPathMonitor?
    private let uplinkStoreHolder = HostUplinkStoreHolder()
    private var hostUplinkContext: HostUplinkObserverContext?
    private var pathBaseline: NetworkPathFingerprint?

    private final class HostUplinkStoreHolder: @unchecked Sendable {
        var store: SCDynamicStore?
        deinit {
            if let store {
                SCDynamicStoreSetDispatchQueue(store, nil)
            }
        }
    }

    private final class HostUplinkObserverContext: @unchecked Sendable {
        weak var controller: AppRuntimeEnvironmentController?
        init(_ controller: AppRuntimeEnvironmentController) { self.controller = controller }
    }

    init(
        tunnel: TunnelManager,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        self.tunnel = tunnel
#if DEBUG || AETHERROUTE_PERFORMANCE_MEASUREMENT
        guard environment["AETHERROUTE_UI_REVIEW"] == nil else {
            return
        }
#if AETHERROUTE_PERFORMANCE_MEASUREMENT
        guard environment["AETHERROUTE_PERFORMANCE_MEASUREMENT"] == nil else {
            return
        }
#endif
#endif

        // Locking the session or turning off a display leaves networking active.
        // Only actual system sleep/wake may pause monitoring and reset connections.
        workspaceObservers = [
            workspaceCenter.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.tunnel.handleRuntimeEnvironmentEvent(
                        .systemWillSleep
                    )
                }
            },
            workspaceCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.tunnel.handleRuntimeEnvironmentEvent(
                        .systemDidWake
                    )
                }
            },
        ]

#if AETHERROUTE_QA_AUTOMATION
        // A frozen VM cannot deliver actual NSWorkspace power notifications.
        // This explicitly opted-in QA bridge exercises the same handlers and
        // is absent from production builds. Screen lock is never a power event.
        if environment["AETHERROUTE_QA_POWER_EVENTS"] == "1" {
            let events: [(String, RuntimeEnvironmentEvent)] = [
                ("com.aetherroute.qa.systemWillSleep", .systemWillSleep),
                ("com.aetherroute.qa.systemDidWake", .systemDidWake),
            ]
            qaPowerObservers = events.map { name, event in
                DistributedNotificationCenter.default().addObserver(
                    forName: Notification.Name(name), object: nil, queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        await self?.tunnel.handleRuntimeEnvironmentEvent(event)
                    }
                }
            }
        }
#endif

        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let fingerprint = NetworkPathFingerprint(path)
            Task { @MainActor [weak self] in
                self?.receivePath(fingerprint)
            }
        }
        monitor.start(queue: pathQueue)

        let observerContext = HostUplinkObserverContext(self)
        hostUplinkContext = observerContext
        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(observerContext).toOpaque(),
            retain: { pointer in
                _ = Unmanaged<HostUplinkObserverContext>.fromOpaque(pointer).retain()
                return pointer
            },
            release: { pointer in
                Unmanaged<HostUplinkObserverContext>.fromOpaque(pointer).release()
            },
            copyDescription: nil
        )
        let store = SCDynamicStoreCreate(
            nil,
            "AetherRoute host link observer" as CFString,
            { _, _, info in
                guard let info else { return }
                let holder = Unmanaged<HostUplinkObserverContext>.fromOpaque(info).takeUnretainedValue()
                DispatchQueue.main.async {
                    holder.controller?.evaluatePathChange()
                }
            },
            &context
        )
        if let store {
            SCDynamicStoreSetNotificationKeys(
                store,
                nil,
                [
                    "State:/Network/Interface/en[0-9]+/(Link|IPv4|IPv6)",
                    "State:/Network/Interface/pdp_ip[0-9]+/(Link|IPv4|IPv6)",
                    "State:/Network/Global/IPv4",
                ] as CFArray
            )
            SCDynamicStoreSetDispatchQueue(store, .main)
            uplinkStoreHolder.store = store
        }
    }

    private func evaluatePathChange() {
        guard let current = pathMonitor?.currentPath else { return }
        let fingerprint = NetworkPathFingerprint(current)
        receivePath(fingerprint)
    }

    private func receivePath(_ fingerprint: NetworkPathFingerprint) {
        guard let baseline = pathBaseline else {
            pathBaseline = fingerprint
            return
        }
        guard baseline != fingerprint else { return }
        pathBaseline = fingerprint
        Task {
            await tunnel.handleRuntimeEnvironmentEvent(.networkPathChanged)
        }
    }

    deinit {
        pathMonitor?.cancel()
    }
}

private struct NetworkPathFingerprint: Sendable, Equatable {
    private enum Status: Sendable {
        case satisfied
        case unsatisfied
        case requiresConnection
        case unknown
    }

    private let status: Status
    private let usesWiFi: Bool
    private let usesWiredEthernet: Bool
    private let usesCellular: Bool
    private let usesOther: Bool
    private let isExpensive: Bool
    private let isConstrained: Bool
    private let physicalSignature: String

    init(_ path: NWPath) {
        status = switch path.status {
        case .satisfied: .satisfied
        case .unsatisfied: .unsatisfied
        case .requiresConnection: .requiresConnection
        @unknown default: .unknown
        }
        usesWiFi = path.usesInterfaceType(.wifi)
        usesWiredEthernet = path.usesInterfaceType(.wiredEthernet)
        usesCellular = path.usesInterfaceType(.cellular)
        usesOther = path.usesInterfaceType(.other)
        isExpensive = path.isExpensive
        isConstrained = path.isConstrained

        if let store = SCDynamicStoreCreate(nil, "AetherRoute path fingerprint" as CFString, nil, nil) {
            let uplink = PhysicalUplinkDetector.currentPhysicalUplink(
                store: store,
                cachedPathInterfaces: path.availableInterfaces
            )
            physicalSignature = PhysicalUplinkDetector.pathSignature(store: store, uplink: uplink)
        } else {
            physicalSignature = ""
        }
    }
}
