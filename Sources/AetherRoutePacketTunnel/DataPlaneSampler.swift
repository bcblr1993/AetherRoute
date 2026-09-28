import AetherRouteKit
import Darwin
import Foundation

/// Periodic data-plane sample for field investigations.
///
/// The Rust core is deliberately silent, so without this a stall that clears
/// when the user stops the tunnel leaves no trace: the counters live only in
/// memory and the app reads them on demand. One line per interval costs the
/// same at any traffic volume, which is what lets it run at the standard
/// level. Verbose additionally lists the live connections, because naming the
/// destinations and proxy chains is the point of an active investigation.
final class DataPlaneSampler: @unchecked Sendable {
    static let interval: TimeInterval = 30

    private static let log = DiagnosticLogCenter.current.log(
        category: "tunnel.data-plane"
    )

    private let queue = DispatchQueue(
        label: "com.aetherroute.packet-provider.data-plane-sampler",
        qos: .utility
    )
    private let core: @Sendable () -> (any CoreBridge)?
    // Accessed only on `queue`.
    private var timer: DispatchSourceTimer?

    init(core: @escaping @Sendable () -> (any CoreBridge)?) {
        self.core = core
    }

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(
                deadline: .now() + Self.interval,
                repeating: Self.interval,
                leeway: .seconds(2)
            )
            source.setEventHandler { [weak self] in self?.sample() }
            source.resume()
            timer = source
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
        }
    }

    private func sample() {
        let level = Self.log.level
        guard level.recordsAggregates, let core = core() else { return }
        let dataPlane = try? core.dataPlaneDiagnosticsSnapshot()
        let telemetry = try? core.telemetrySnapshot(
            maximumConnections: UInt16(NetworkTelemetryCodec.maximumConnections)
        )
        Self.log.aggregate(
            Self.summary(dataPlane: dataPlane, telemetry: telemetry)
        )
        guard level.recordsPerFlow, let telemetry else { return }
        let now = UInt64(Date().timeIntervalSince1970 * 1_000)
        for connection in telemetry.connections {
            Self.log.verbose(Self.describe(connection, now: now))
        }
    }

    static func summary(
        dataPlane: DataPlaneDiagnosticSnapshot?,
        telemetry: NetworkTelemetrySnapshot?,
        footprintBytes: UInt64? = currentFootprintBytes(),
        descriptorCount: Int? = currentDescriptorCount()
    ) -> String {
        var fields = ["stage=dataPlaneSample"]
        if let telemetry {
            fields += [
                "connections=\(telemetry.connections.count)",
                "upRate=\(telemetry.uploadBytesPerSecond)",
                "downRate=\(telemetry.downloadBytesPerSecond)",
                "upTotal=\(telemetry.uploadTotal)",
                "downTotal=\(telemetry.downloadTotal)",
                "coreMemory=\(telemetry.memoryBytes)",
            ]
        } else {
            fields.append("telemetry=unavailable")
        }
        if let dataPlane {
            fields += [
                "tcpConnectError=\(dataPlane.tcpConnectErrorCount)",
                "tcpBindFailed=\(dataPlane.tcpBindFailedCount)",
                "fakeIpMappingMissing=\(dataPlane.fakeIpMappingMissingCount)",
                "fakeIpReverseLookupFailed=\(dataPlane.fakeIpReverseLookupFailedCount)",
                "networkStateReset=\(dataPlane.networkStateResetCount)",
                "outboundInterface=\(dataPlane.outboundInterfaceIndex)",
            ]
        } else {
            fields.append("dataPlane=unavailable")
        }
        fields.append("footprint=\(footprintBytes.map(String.init) ?? "unknown")")
        fields.append("fds=\(descriptorCount.map(String.init) ?? "unknown")")
        return fields.joined(separator: " ")
    }

    static func describe(_ connection: ConnectionTelemetry, now: UInt64) -> String {
        let ageSeconds = now >= connection.startedAtUnixMilliseconds
            ? (now - connection.startedAtUnixMilliseconds) / 1_000
            : 0
        return "stage=dataPlaneConnection transport=\(connection.transport) "
            + "destination=\(connection.destination):\(connection.destinationPort) "
            + "chain=\(connection.proxyChain) rule=\(connection.rule) "
            + "up=\(connection.uploadTotal) down=\(connection.downloadTotal) "
            + "ageSeconds=\(ageSeconds)"
    }

    /// Physical footprint is the figure the system's memory limit acts on.
    static func currentFootprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size
        )
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info.phys_footprint : nil
    }

    static func currentDescriptorCount() -> Int? {
        let pid = getpid()
        let required = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard required > 0 else { return nil }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var buffer = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(required) / stride)
        let filled = buffer.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
        }
        return filled > 0 ? Int(filled) / stride : nil
    }
}
