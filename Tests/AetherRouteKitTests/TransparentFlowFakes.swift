import AetherRouteKit
import Foundation

final class FakeTCPFlow: TransparentTCPFlowIO, @unchecked Sendable {
    struct ReadRequest {
        let maximumBytes: Int
        let token: FlowOperationToken
        let completion: TCPReadCompletion
    }

    struct WriteRequest {
        let data: Data
        let token: FlowOperationToken
        let completion: TCPWriteCompletion
    }

    struct FinishRequest {
        let token: FlowOperationToken
        let completion: TCPWriteCompletion
    }

    private let lock = NSLock()
    private var reads: [ReadRequest] = []
    private var writes: [WriteRequest] = []
    private var finishes: [FinishRequest] = []
    private var readCalls = 0
    private var writeCalls = 0
    private var finishCalls = 0
    private var cancellations = 0

    var readCallCount: Int { locked { readCalls } }
    var writeCallCount: Int { locked { writeCalls } }
    var finishCallCount: Int { locked { finishCalls } }
    var cancelCallCount: Int { locked { cancellations } }
    var firstReadToken: FlowOperationToken? { locked { reads.first?.token } }
    var writtenData: [Data] { locked { writes.map(\.data) } }

    func read(
        maximumBytes: Int,
        token: FlowOperationToken,
        completion: @escaping TCPReadCompletion
    ) {
        locked {
            readCalls += 1
            reads.append(
                ReadRequest(
                    maximumBytes: maximumBytes,
                    token: token,
                    completion: completion
                )
            )
        }
    }

    func write(
        _ data: Data,
        token: FlowOperationToken,
        completion: @escaping TCPWriteCompletion
    ) {
        locked {
            writeCalls += 1
            writes.append(
                WriteRequest(data: data, token: token, completion: completion)
            )
        }
    }

    func finishWriting(
        token: FlowOperationToken,
        completion: @escaping TCPWriteCompletion
    ) {
        locked {
            finishCalls += 1
            finishes.append(
                FinishRequest(token: token, completion: completion)
            )
        }
    }

    func cancel() {
        locked { cancellations += 1 }
    }

    @discardableResult
    func completeNextRead(
        _ result: Result<TCPReadResult, FlowIOError>,
        returnedToken: FlowOperationToken? = nil
    ) -> Bool {
        guard let request = pop(&reads) else { return false }
        request.completion(returnedToken ?? request.token, result)
        return true
    }

    @discardableResult
    func completeNextWrite(
        _ result: Result<Void, FlowIOError>
    ) -> Bool {
        guard let request = pop(&writes) else { return false }
        request.completion(request.token, result)
        return true
    }

    @discardableResult
    func completeNextFinish(
        _ result: Result<Void, FlowIOError>
    ) -> Bool {
        guard let request = pop(&finishes) else { return false }
        request.completion(request.token, result)
        return true
    }

    private func pop<Element>(_ values: inout [Element]) -> Element? {
        locked {
            guard !values.isEmpty else { return nil }
            return values.removeFirst()
        }
    }

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

final class FakeRustTCPSource: RustTCPSource, @unchecked Sendable {
    struct ReadRequest {
        let maximumBytes: Int
        let token: FlowOperationToken
        let completion: TCPReadCompletion
    }

    private let lock = NSLock()
    private var reads: [ReadRequest] = []
    private var readCalls = 0
    private var cancellations = 0

    var readCallCount: Int { locked { readCalls } }
    var cancelCallCount: Int { locked { cancellations } }
    var firstReadToken: FlowOperationToken? { locked { reads.first?.token } }

    func read(
        maximumBytes: Int,
        token: FlowOperationToken,
        completion: @escaping TCPReadCompletion
    ) {
        locked {
            readCalls += 1
            reads.append(
                ReadRequest(
                    maximumBytes: maximumBytes,
                    token: token,
                    completion: completion
                )
            )
        }
    }

    func cancel() {
        locked { cancellations += 1 }
    }

    @discardableResult
    func completeNextRead(
        _ result: Result<TCPReadResult, FlowIOError>,
        returnedToken: FlowOperationToken? = nil
    ) -> Bool {
        let request: ReadRequest? = locked {
            guard !reads.isEmpty else { return nil }
            return reads.removeFirst()
        }
        guard let request else { return false }
        request.completion(returnedToken ?? request.token, result)
        return true
    }

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

final class FakeRustTCPSink: RustTCPSink, @unchecked Sendable {
    struct WriteRequest {
        let data: Data
        let token: FlowOperationToken
        let completion: TCPWriteCompletion
    }

    struct FinishRequest {
        let token: FlowOperationToken
        let completion: TCPWriteCompletion
    }

    private let lock = NSLock()
    private var writes: [WriteRequest] = []
    private var finishes: [FinishRequest] = []
    private var writeCalls = 0
    private var finishCalls = 0
    private var cancellations = 0

    var writeCallCount: Int { locked { writeCalls } }
    var finishCallCount: Int { locked { finishCalls } }
    var cancelCallCount: Int { locked { cancellations } }
    var writtenData: [Data] { locked { writes.map(\.data) } }

    func write(
        _ data: Data,
        token: FlowOperationToken,
        completion: @escaping TCPWriteCompletion
    ) {
        locked {
            writeCalls += 1
            writes.append(
                WriteRequest(data: data, token: token, completion: completion)
            )
        }
    }

    func finishWriting(
        token: FlowOperationToken,
        completion: @escaping TCPWriteCompletion
    ) {
        locked {
            finishCalls += 1
            finishes.append(
                FinishRequest(token: token, completion: completion)
            )
        }
    }

    func cancel() {
        locked { cancellations += 1 }
    }

    @discardableResult
    func completeNextWrite(
        _ result: Result<Void, FlowIOError>
    ) -> Bool {
        let request: WriteRequest? = locked {
            guard !writes.isEmpty else { return nil }
            return writes.removeFirst()
        }
        guard let request else { return false }
        request.completion(request.token, result)
        return true
    }

    @discardableResult
    func completeNextFinish(
        _ result: Result<Void, FlowIOError>
    ) -> Bool {
        let request: FinishRequest? = locked {
            guard !finishes.isEmpty else { return nil }
            return finishes.removeFirst()
        }
        guard let request else { return false }
        request.completion(request.token, result)
        return true
    }

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

final class FakeUDPFlow: TransparentUDPFlowIO, @unchecked Sendable {
    struct ReadRequest {
        let maximumDatagrams: Int
        let maximumBytes: Int
        let token: FlowOperationToken
        let completion: UDPReadCompletion
    }

    struct WriteRequest {
        let datagrams: [UDPDatagram]
        let token: FlowOperationToken
        let completion: UDPWriteCompletion
    }

    private let lock = NSLock()
    private var reads: [ReadRequest] = []
    private var writes: [WriteRequest] = []
    private var readCalls = 0
    private var writeCalls = 0
    private var cancellations = 0

    var readCallCount: Int { locked { readCalls } }
    var writeCallCount: Int { locked { writeCalls } }
    var cancelCallCount: Int { locked { cancellations } }
    var firstReadToken: FlowOperationToken? { locked { reads.first?.token } }
    var firstReadLimits: (Int, Int)? {
        locked { reads.first.map { ($0.maximumDatagrams, $0.maximumBytes) } }
    }
    var writtenDatagrams: [[UDPDatagram]] {
        locked { writes.map(\.datagrams) }
    }

    func readDatagrams(
        maximumDatagrams: Int,
        maximumBytes: Int,
        token: FlowOperationToken,
        completion: @escaping UDPReadCompletion
    ) {
        locked {
            readCalls += 1
            reads.append(
                ReadRequest(
                    maximumDatagrams: maximumDatagrams,
                    maximumBytes: maximumBytes,
                    token: token,
                    completion: completion
                )
            )
        }
    }

    func writeDatagrams(
        _ datagrams: [UDPDatagram],
        token: FlowOperationToken,
        completion: @escaping UDPWriteCompletion
    ) {
        locked {
            writeCalls += 1
            writes.append(
                WriteRequest(
                    datagrams: datagrams,
                    token: token,
                    completion: completion
                )
            )
        }
    }

    func cancel() {
        locked { cancellations += 1 }
    }

    @discardableResult
    func completeNextRead(
        _ result: Result<UDPReadResult, FlowIOError>,
        returnedToken: FlowOperationToken? = nil
    ) -> Bool {
        let request: ReadRequest? = locked {
            guard !reads.isEmpty else { return nil }
            return reads.removeFirst()
        }
        guard let request else { return false }
        request.completion(returnedToken ?? request.token, result)
        return true
    }

    @discardableResult
    func completeNextWrite(
        _ result: Result<Void, FlowIOError>
    ) -> Bool {
        let request: WriteRequest? = locked {
            guard !writes.isEmpty else { return nil }
            return writes.removeFirst()
        }
        guard let request else { return false }
        request.completion(request.token, result)
        return true
    }

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

final class FakeRustUDPSource: RustUDPSource, @unchecked Sendable {
    struct ReadRequest {
        let maximumDatagrams: Int
        let maximumBytes: Int
        let token: FlowOperationToken
        let completion: UDPReadCompletion
    }

    private let lock = NSLock()
    private var reads: [ReadRequest] = []
    private var readCalls = 0
    private var cancellations = 0

    var readCallCount: Int { locked { readCalls } }
    var cancelCallCount: Int { locked { cancellations } }
    var firstReadToken: FlowOperationToken? { locked { reads.first?.token } }
    var firstReadLimits: (Int, Int)? {
        locked { reads.first.map { ($0.maximumDatagrams, $0.maximumBytes) } }
    }

    func readDatagrams(
        maximumDatagrams: Int,
        maximumBytes: Int,
        token: FlowOperationToken,
        completion: @escaping UDPReadCompletion
    ) {
        locked {
            readCalls += 1
            reads.append(
                ReadRequest(
                    maximumDatagrams: maximumDatagrams,
                    maximumBytes: maximumBytes,
                    token: token,
                    completion: completion
                )
            )
        }
    }

    func cancel() {
        locked { cancellations += 1 }
    }

    @discardableResult
    func completeNextRead(
        _ result: Result<UDPReadResult, FlowIOError>,
        returnedToken: FlowOperationToken? = nil
    ) -> Bool {
        let request: ReadRequest? = locked {
            guard !reads.isEmpty else { return nil }
            return reads.removeFirst()
        }
        guard let request else { return false }
        request.completion(returnedToken ?? request.token, result)
        return true
    }

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

final class FakeRustUDPSink: RustUDPSink, @unchecked Sendable {
    struct WriteRequest {
        let datagrams: [UDPDatagram]
        let token: FlowOperationToken
        let completion: UDPWriteCompletion
    }

    private let lock = NSLock()
    private var writes: [WriteRequest] = []
    private var writeCalls = 0
    private var cancellations = 0

    var writeCallCount: Int { locked { writeCalls } }
    var cancelCallCount: Int { locked { cancellations } }
    var writtenDatagrams: [[UDPDatagram]] {
        locked { writes.map(\.datagrams) }
    }

    func writeDatagrams(
        _ datagrams: [UDPDatagram],
        token: FlowOperationToken,
        completion: @escaping UDPWriteCompletion
    ) {
        locked {
            writeCalls += 1
            writes.append(
                WriteRequest(
                    datagrams: datagrams,
                    token: token,
                    completion: completion
                )
            )
        }
    }

    func cancel() {
        locked { cancellations += 1 }
    }

    @discardableResult
    func completeNextWrite(
        _ result: Result<Void, FlowIOError>
    ) -> Bool {
        let request: WriteRequest? = locked {
            guard !writes.isEmpty else { return nil }
            return writes.removeFirst()
        }
        guard let request else { return false }
        request.completion(request.token, result)
        return true
    }

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

final class FlowTerminationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedValues: [FlowLifecycle] = []

    var values: [FlowLifecycle] {
        lock.lock()
        defer { lock.unlock() }
        return recordedValues
    }

    func record(_ lifecycle: FlowLifecycle) {
        lock.lock()
        recordedValues.append(lifecycle)
        lock.unlock()
    }
}

func eventually(
    timeout: Duration = .seconds(2),
    _ condition: @escaping @Sendable () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return condition()
}

func eventually(
    _ machine: TCPFlowStateMachine,
    timeout: Duration = .seconds(2),
    _ condition: @escaping @Sendable (TCPFlowSnapshot) -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition(await machine.snapshot()) { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return condition(await machine.snapshot())
}

func eventually(
    _ machine: UDPFlowStateMachine,
    timeout: Duration = .seconds(2),
    _ condition: @escaping @Sendable (UDPFlowSnapshot) -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition(await machine.snapshot()) { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return condition(await machine.snapshot())
}
