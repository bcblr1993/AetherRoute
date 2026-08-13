import AetherRouteFlowABI
import AetherRouteKit
import Foundation

struct FlowCoreABIHandle: @unchecked Sendable, Hashable {
    let rawValue: UnsafeMutableRawPointer
}

struct FlowCoreABIUDPDatagram: Sendable, Equatable {
    let payload: Data
    let remoteEndpoint: Data
}

struct FlowCoreABITCPReadResponse: Sendable {
    let token: UInt64
    let status: Int32
    let data: Data?
    let endOfStream: Bool
    let malformed: Bool
}

struct FlowCoreABIUDPReadResponse: Sendable {
    let token: UInt64
    let status: Int32
    let datagrams: [FlowCoreABIUDPDatagram]
    let endOfStream: Bool
    let malformed: Bool
}

protocol FlowCoreABIBackend: AnyObject, Sendable {
    func engineCreate(
        profile: Data,
        workingDirectory: Data,
        configuration: FlowCoreEngineConfiguration
    ) -> (status: Int32, handle: FlowCoreABIHandle?)

    func engineDestroy(_ engine: FlowCoreABIHandle) -> Int32

    func selectorSnapshot(
        engine: FlowCoreABIHandle,
        group: Data
    ) -> (status: Int32, snapshot: Data?)

    func selectorSelect(
        engine: FlowCoreABIHandle,
        group: Data,
        member: Data
    ) -> Int32

    func selectorLatency(
        engine: FlowCoreABIHandle,
        group: Data,
        url: Data,
        timeoutMilliseconds: UInt32
    ) -> (status: Int32, latencies: Data?)

    func telemetrySnapshot(
        engine: FlowCoreABIHandle,
        maximumConnections: UInt32
    ) -> (status: Int32, snapshot: Data?)

    func tcpCreate(
        engine: FlowCoreABIHandle,
        source: Data?,
        destination: Data
    ) -> (status: Int32, handle: FlowCoreABIHandle?)

    func udpCreate(
        engine: FlowCoreABIHandle,
        source: Data
    ) -> (status: Int32, handle: FlowCoreABIHandle?)

    func activate(_ flow: FlowCoreABIHandle) -> Int32

    func tcpWrite(
        _ flow: FlowCoreABIHandle,
        data: Data,
        token: UInt64,
        completion: @escaping @Sendable (UInt64, Int32) -> Void
    ) -> Int32

    func tcpFinishWrite(
        _ flow: FlowCoreABIHandle,
        token: UInt64,
        completion: @escaping @Sendable (UInt64, Int32) -> Void
    ) -> Int32

    func tcpRead(
        _ flow: FlowCoreABIHandle,
        maximumBytes: Int,
        token: UInt64,
        completion: @escaping @Sendable (FlowCoreABITCPReadResponse) -> Void
    ) -> Int32

    func udpWrite(
        _ flow: FlowCoreABIHandle,
        datagrams: [FlowCoreABIUDPDatagram],
        token: UInt64,
        completion: @escaping @Sendable (UInt64, Int32) -> Void
    ) -> Int32

    func udpRead(
        _ flow: FlowCoreABIHandle,
        maximumDatagrams: Int,
        maximumBytes: Int,
        token: UInt64,
        completion: @escaping @Sendable (FlowCoreABIUDPReadResponse) -> Void
    ) -> Int32

    func cancel(_ flow: FlowCoreABIHandle) -> Int32
    func destroy(_ flow: FlowCoreABIHandle) -> Int32
}

enum FlowCoreABIStatus {
    static let success: Int32 = 0
    static let invalidArgument: Int32 = 1
    static let invalidProfile: Int32 = 2
    static let unsupportedProfile: Int32 = 3
    static let invalidState: Int32 = 4
    static let backpressure: Int32 = 5
    static let tooLarge: Int32 = 6
    static let closed: Int32 = 7
    static let cancelled: Int32 = 8
    static let startupFailed: Int32 = 9
    static let internalError: Int32 = 255
}

final class LiveFlowCoreABIBackend: FlowCoreABIBackend, @unchecked Sendable {
    private let table: aetherroute_flow_abi_v3_t

    init() throws {
        var table = aetherroute_flow_abi_v3_t()
        table.struct_size = UInt32(
            MemoryLayout<aetherroute_flow_abi_v3_t>.size
        )
        guard aetherroute_flow_abi_load_v3(&table) == 1 else {
            throw FlowCoreEngineError.flowABIUnavailable
        }
        self.table = table
    }

    func engineCreate(
        profile: Data,
        workingDirectory: Data,
        configuration: FlowCoreEngineConfiguration
    ) -> (status: Int32, handle: FlowCoreABIHandle?) {
        guard let function = table.v2.engine_create else {
            return (FlowCoreABIStatus.internalError, nil)
        }
        var options = clash_flow_engine_options_v1_t(
            struct_size: UInt32(
                MemoryLayout<clash_flow_engine_options_v1_t>.size
            ),
            worker_threads: UInt32(configuration.workerThreads),
            queue_depth: UInt32(configuration.queueDepth),
            maximum_tcp_chunk_bytes: UInt32(
                configuration.maximumTCPChunkBytes
            ),
            maximum_udp_payload_bytes: UInt32(
                configuration.maximumUDPPayloadBytes
            )
        )
        var output: UnsafeMutableRawPointer?
        let status = profile.withUnsafeBytes { profileBytes in
            workingDirectory.withUnsafeBytes { directoryBytes in
                function(
                    profileBytes.bindMemory(to: UInt8.self).baseAddress,
                    profileBytes.count,
                    directoryBytes.bindMemory(to: UInt8.self).baseAddress,
                    directoryBytes.count,
                    &options,
                    &output
                )
            }
        }
        guard status == FlowCoreABIStatus.success, let output else {
            return (status, nil)
        }
        if let routingMode = configuration.routingMode {
            guard let setRoutingMode = table.engine_set_routing_mode else {
                _ = table.v2.engine_destroy?(output)
                return (FlowCoreABIStatus.internalError, nil)
            }
            let modeStatus = setRoutingMode(
                output,
                routingMode.packetFlowABIValue
            )
            guard modeStatus == FlowCoreABIStatus.success else {
                _ = table.v2.engine_destroy?(output)
                return (modeStatus, nil)
            }
        }
        return (
            FlowCoreABIStatus.success,
            FlowCoreABIHandle(rawValue: output)
        )
    }

    func engineDestroy(_ engine: FlowCoreABIHandle) -> Int32 {
        guard let function = table.v2.engine_destroy else {
            return FlowCoreABIStatus.internalError
        }
        return function(engine.rawValue)
    }

    func selectorSnapshot(
        engine: FlowCoreABIHandle,
        group: Data
    ) -> (status: Int32, snapshot: Data?) {
        guard let function = table.v2.selector_snapshot else {
            return (FlowCoreABIStatus.internalError, nil)
        }
        var required = 0
        let queryStatus = group.withUnsafeBytes { groupBytes in
            function(
                engine.rawValue,
                groupBytes.bindMemory(to: UInt8.self).baseAddress,
                groupBytes.count,
                nil,
                0,
                &required
            )
        }
        guard queryStatus == FlowCoreABIStatus.success else {
            return (queryStatus, nil)
        }
        guard (12...(1_024 * 1_024)).contains(required) else {
            return (FlowCoreABIStatus.tooLarge, nil)
        }
        var snapshot = Data(count: required)
        let copyStatus = group.withUnsafeBytes { groupBytes in
            snapshot.withUnsafeMutableBytes { snapshotBytes in
                function(
                    engine.rawValue,
                    groupBytes.bindMemory(to: UInt8.self).baseAddress,
                    groupBytes.count,
                    snapshotBytes.bindMemory(to: UInt8.self).baseAddress,
                    snapshotBytes.count,
                    &required
                )
            }
        }
        guard
            copyStatus == FlowCoreABIStatus.success,
            required == snapshot.count
        else {
            return (copyStatus, nil)
        }
        return (copyStatus, snapshot)
    }

    func selectorSelect(
        engine: FlowCoreABIHandle,
        group: Data,
        member: Data
    ) -> Int32 {
        guard let function = table.v2.selector_select else {
            return FlowCoreABIStatus.internalError
        }
        return group.withUnsafeBytes { groupBytes in
            member.withUnsafeBytes { memberBytes in
                function(
                    engine.rawValue,
                    groupBytes.bindMemory(to: UInt8.self).baseAddress,
                    groupBytes.count,
                    memberBytes.bindMemory(to: UInt8.self).baseAddress,
                    memberBytes.count
                )
            }
        }
    }

    func selectorLatency(
        engine: FlowCoreABIHandle,
        group: Data,
        url: Data,
        timeoutMilliseconds: UInt32
    ) -> (status: Int32, latencies: Data?) {
        guard let function = table.v2.selector_latency else {
            return (FlowCoreABIStatus.internalError, nil)
        }
        var required = 0
        var latencies = Data(
            count: ProxySelectionProviderMessageCodec.maximumMessageBytes
        )
        let copyStatus = group.withUnsafeBytes { groupBytes in
            url.withUnsafeBytes { urlBytes in
                latencies.withUnsafeMutableBytes { outputBytes in
                    function(
                        engine.rawValue,
                        groupBytes.bindMemory(to: UInt8.self).baseAddress,
                        groupBytes.count,
                        urlBytes.bindMemory(to: UInt8.self).baseAddress,
                        urlBytes.count,
                        timeoutMilliseconds,
                        outputBytes.bindMemory(to: UInt8.self).baseAddress,
                        outputBytes.count,
                        &required
                    )
                }
            }
        }
        guard
            copyStatus == FlowCoreABIStatus.success,
            (8...latencies.count).contains(required)
        else {
            return (copyStatus, nil)
        }
        latencies.count = required
        return (copyStatus, latencies)
    }

    func telemetrySnapshot(
        engine: FlowCoreABIHandle,
        maximumConnections: UInt32
    ) -> (status: Int32, snapshot: Data?) {
        guard let function = table.v2.telemetry_snapshot else {
            return (FlowCoreABIStatus.internalError, nil)
        }
        var required = 0
        var snapshot = Data(count: NetworkTelemetryCodec.maximumMessageBytes)
        let copyStatus = snapshot.withUnsafeMutableBytes { outputBytes in
            function(
                engine.rawValue,
                maximumConnections,
                outputBytes.bindMemory(to: UInt8.self).baseAddress,
                outputBytes.count,
                &required
            )
        }
        guard
            copyStatus == FlowCoreABIStatus.success,
            (48...snapshot.count).contains(required)
        else { return (copyStatus, nil) }
        snapshot.count = required
        return (copyStatus, snapshot)
    }

    func tcpCreate(
        engine: FlowCoreABIHandle,
        source: Data?,
        destination: Data
    ) -> (status: Int32, handle: FlowCoreABIHandle?) {
        guard let function = table.v2.tcp_create else {
            return (FlowCoreABIStatus.internalError, nil)
        }
        let source = source ?? Data()
        var output: UnsafeMutableRawPointer?
        let status = source.withUnsafeBytes { sourceBytes in
            destination.withUnsafeBytes { destinationBytes in
                function(
                    engine.rawValue,
                    sourceBytes.bindMemory(to: UInt8.self).baseAddress,
                    sourceBytes.count,
                    destinationBytes.bindMemory(to: UInt8.self).baseAddress,
                    destinationBytes.count,
                    &output
                )
            }
        }
        return (status, output.map(FlowCoreABIHandle.init(rawValue:)))
    }

    func udpCreate(
        engine: FlowCoreABIHandle,
        source: Data
    ) -> (status: Int32, handle: FlowCoreABIHandle?) {
        guard let function = table.v2.udp_create else {
            return (FlowCoreABIStatus.internalError, nil)
        }
        var output: UnsafeMutableRawPointer?
        let status = source.withUnsafeBytes { sourceBytes in
            function(
                engine.rawValue,
                sourceBytes.bindMemory(to: UInt8.self).baseAddress,
                sourceBytes.count,
                &output
            )
        }
        return (status, output.map(FlowCoreABIHandle.init(rawValue:)))
    }

    func activate(_ flow: FlowCoreABIHandle) -> Int32 {
        table.v2.activate?(flow.rawValue) ?? FlowCoreABIStatus.internalError
    }

    func tcpWrite(
        _ flow: FlowCoreABIHandle,
        data: Data,
        token: UInt64,
        completion: @escaping @Sendable (UInt64, Int32) -> Void
    ) -> Int32 {
        guard let function = table.v2.tcp_write else {
            return FlowCoreABIStatus.internalError
        }
        let context = FlowCoreCompletionContext(
            expectedToken: token,
            completion: completion
        )
        let opaque = Unmanaged.passRetained(context).toOpaque()
        let status = data.withUnsafeBytes { bytes in
            function(
                flow.rawValue,
                bytes.bindMemory(to: UInt8.self).baseAddress,
                bytes.count,
                token,
                flowCoreCompletionCallback,
                opaque
            )
        }
        if status != FlowCoreABIStatus.success {
            _ = Unmanaged<FlowCoreCompletionContext>
                .fromOpaque(opaque)
                .takeRetainedValue()
        }
        return status
    }

    func tcpFinishWrite(
        _ flow: FlowCoreABIHandle,
        token: UInt64,
        completion: @escaping @Sendable (UInt64, Int32) -> Void
    ) -> Int32 {
        guard let function = table.v2.tcp_finish_write else {
            return FlowCoreABIStatus.internalError
        }
        let context = FlowCoreCompletionContext(
            expectedToken: token,
            completion: completion
        )
        let opaque = Unmanaged.passRetained(context).toOpaque()
        let status = function(
            flow.rawValue,
            token,
            flowCoreCompletionCallback,
            opaque
        )
        if status != FlowCoreABIStatus.success {
            _ = Unmanaged<FlowCoreCompletionContext>
                .fromOpaque(opaque)
                .takeRetainedValue()
        }
        return status
    }

    func tcpRead(
        _ flow: FlowCoreABIHandle,
        maximumBytes: Int,
        token: UInt64,
        completion: @escaping @Sendable (FlowCoreABITCPReadResponse) -> Void
    ) -> Int32 {
        guard let function = table.v2.tcp_read else {
            return FlowCoreABIStatus.internalError
        }
        let context = FlowCoreTCPReadContext(
            expectedToken: token,
            maximumBytes: maximumBytes,
            completion: completion
        )
        let opaque = Unmanaged.passRetained(context).toOpaque()
        let status = function(
            flow.rawValue,
            maximumBytes,
            token,
            flowCoreTCPReadCallback,
            opaque
        )
        if status != FlowCoreABIStatus.success {
            _ = Unmanaged<FlowCoreTCPReadContext>
                .fromOpaque(opaque)
                .takeRetainedValue()
        }
        return status
    }

    func udpWrite(
        _ flow: FlowCoreABIHandle,
        datagrams: [FlowCoreABIUDPDatagram],
        token: UInt64,
        completion: @escaping @Sendable (UInt64, Int32) -> Void
    ) -> Int32 {
        guard let function = table.v2.udp_write else {
            return FlowCoreABIStatus.internalError
        }

        let payloads = datagrams.map { $0.payload as NSData }
        let endpoints = datagrams.map { $0.remoteEndpoint as NSData }
        let descriptors = zip(payloads, endpoints).map { payload, endpoint in
            clash_flow_datagram_v1_t(
                payload: payload.length == 0
                    ? nil
                    : payload.bytes.assumingMemoryBound(to: UInt8.self),
                payload_length: payload.length,
                remote_endpoint: endpoint.bytes.assumingMemoryBound(
                    to: UInt8.self
                ),
                remote_endpoint_length: endpoint.length
            )
        }
        let context = FlowCoreCompletionContext(
            expectedToken: token,
            completion: completion
        )
        let opaque = Unmanaged.passRetained(context).toOpaque()
        let status = descriptors.withUnsafeBufferPointer { buffer in
            function(
                flow.rawValue,
                buffer.baseAddress,
                buffer.count,
                token,
                flowCoreCompletionCallback,
                opaque
            )
        }
        withExtendedLifetime(payloads) {}
        withExtendedLifetime(endpoints) {}
        if status != FlowCoreABIStatus.success {
            _ = Unmanaged<FlowCoreCompletionContext>
                .fromOpaque(opaque)
                .takeRetainedValue()
        }
        return status
    }

    func udpRead(
        _ flow: FlowCoreABIHandle,
        maximumDatagrams: Int,
        maximumBytes: Int,
        token: UInt64,
        completion: @escaping @Sendable (FlowCoreABIUDPReadResponse) -> Void
    ) -> Int32 {
        guard let function = table.v2.udp_read else {
            return FlowCoreABIStatus.internalError
        }
        let context = FlowCoreUDPReadContext(
            expectedToken: token,
            maximumDatagrams: maximumDatagrams,
            maximumBytes: maximumBytes,
            completion: completion
        )
        let opaque = Unmanaged.passRetained(context).toOpaque()
        let status = function(
            flow.rawValue,
            maximumDatagrams,
            maximumBytes,
            token,
            flowCoreUDPReadCallback,
            opaque
        )
        if status != FlowCoreABIStatus.success {
            _ = Unmanaged<FlowCoreUDPReadContext>
                .fromOpaque(opaque)
                .takeRetainedValue()
        }
        return status
    }

    func cancel(_ flow: FlowCoreABIHandle) -> Int32 {
        table.v2.cancel?(flow.rawValue) ?? FlowCoreABIStatus.internalError
    }

    func destroy(_ flow: FlowCoreABIHandle) -> Int32 {
        table.v2.destroy?(flow.rawValue) ?? FlowCoreABIStatus.internalError
    }
}

final class FlowCoreCompletionContext: @unchecked Sendable {
    let expectedToken: UInt64
    let completion: @Sendable (UInt64, Int32) -> Void

    init(
        expectedToken: UInt64,
        completion: @escaping @Sendable (UInt64, Int32) -> Void
    ) {
        self.expectedToken = expectedToken
        self.completion = completion
    }
}

final class FlowCoreTCPReadContext: @unchecked Sendable {
    let expectedToken: UInt64
    let maximumBytes: Int
    let completion: @Sendable (FlowCoreABITCPReadResponse) -> Void

    init(
        expectedToken: UInt64,
        maximumBytes: Int,
        completion: @escaping @Sendable (FlowCoreABITCPReadResponse) -> Void
    ) {
        self.expectedToken = expectedToken
        self.maximumBytes = maximumBytes
        self.completion = completion
    }
}

final class FlowCoreUDPReadContext: @unchecked Sendable {
    let expectedToken: UInt64
    let maximumDatagrams: Int
    let maximumBytes: Int
    let completion: @Sendable (FlowCoreABIUDPReadResponse) -> Void

    init(
        expectedToken: UInt64,
        maximumDatagrams: Int,
        maximumBytes: Int,
        completion: @escaping @Sendable (FlowCoreABIUDPReadResponse) -> Void
    ) {
        self.expectedToken = expectedToken
        self.maximumDatagrams = maximumDatagrams
        self.maximumBytes = maximumBytes
        self.completion = completion
    }
}

func flowCoreCompletionCallback(
    token: UInt64,
    status: Int32,
    context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    let retained = Unmanaged<FlowCoreCompletionContext>
        .fromOpaque(context)
        .takeRetainedValue()
    retained.completion(token, status)
}

func flowCoreTCPReadCallback(
    token: UInt64,
    status: Int32,
    data: UnsafePointer<UInt8>?,
    dataLength: Int,
    endOfStream: Int32,
    context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    let retained = Unmanaged<FlowCoreTCPReadContext>
        .fromOpaque(context)
        .takeRetainedValue()

    var malformed = token != retained.expectedToken
        || (endOfStream != 0 && endOfStream != 1)
    var copied: Data?
    if status == FlowCoreABIStatus.success {
        if endOfStream == 1 {
            malformed = malformed || dataLength != 0
        } else if dataLength <= 0 || dataLength > retained.maximumBytes {
            malformed = true
        } else if let data {
            // The C buffer is borrowed only for this callback. Copy before
            // invoking any Swift closure or dispatching to another queue.
            copied = Data(bytes: data, count: dataLength)
        } else {
            malformed = true
        }
    }
    retained.completion(
        FlowCoreABITCPReadResponse(
            token: token,
            status: status,
            data: copied,
            endOfStream: endOfStream == 1,
            malformed: malformed
        )
    )
}

func flowCoreUDPReadCallback(
    token: UInt64,
    status: Int32,
    datagrams: UnsafePointer<clash_flow_datagram_v1_t>?,
    datagramCount: Int,
    endOfStream: Int32,
    context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    let retained = Unmanaged<FlowCoreUDPReadContext>
        .fromOpaque(context)
        .takeRetainedValue()

    var malformed = token != retained.expectedToken
        || (endOfStream != 0 && endOfStream != 1)
    var copied: [FlowCoreABIUDPDatagram] = []
    if status == FlowCoreABIStatus.success {
        if endOfStream == 1 {
            malformed = malformed || datagramCount != 0
        } else if datagramCount <= 0
            || datagramCount > retained.maximumDatagrams
            || datagrams == nil
        {
            malformed = true
        } else if let datagrams {
            copied.reserveCapacity(datagramCount)
            var aggregateBytes = 0
            for index in 0..<datagramCount {
                let descriptor = datagrams[index]
                let payloadLength = descriptor.payload_length
                let endpointLength = descriptor.remote_endpoint_length
                guard
                    payloadLength <= UDPBatchPolicy.maximumPayloadBytes,
                    payloadLength
                        <= retained.maximumBytes - aggregateBytes,
                    (1...FlowEndpointCodec.maximumEncodedBytes)
                        .contains(endpointLength),
                    let endpointPointer = descriptor.remote_endpoint
                else {
                    malformed = true
                    copied.removeAll(keepingCapacity: false)
                    break
                }
                let payload: Data
                if payloadLength == 0 {
                    payload = Data()
                } else if let payloadPointer = descriptor.payload {
                    payload = Data(bytes: payloadPointer, count: payloadLength)
                } else {
                    malformed = true
                    copied.removeAll(keepingCapacity: false)
                    break
                }
                let endpoint = Data(
                    bytes: endpointPointer,
                    count: endpointLength
                )
                copied.append(
                    FlowCoreABIUDPDatagram(
                        payload: payload,
                        remoteEndpoint: endpoint
                    )
                )
                aggregateBytes += payloadLength
            }
        }
    }
    retained.completion(
        FlowCoreABIUDPReadResponse(
            token: token,
            status: status,
            datagrams: copied,
            endOfStream: endOfStream == 1,
            malformed: malformed
        )
    )
}
