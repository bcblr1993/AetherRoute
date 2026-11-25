import Darwin
import Foundation

private final class AetherRouteIdentityBundleMarker: NSObject {}

public enum AppConstants {
    public static let appGroupInfoKey = "AetherRouteAppGroup"
    public static let keychainAccessGroupInfoKey =
        "AetherRouteKeychainAccessGroup"
    public static let keychainAccessGroupSuffixInfoKey =
        "AetherRouteKeychainAccessGroupSuffix"
    public static let sharedKeychainAccessGroupInfoKey =
        "AetherRouteSharedKeychainAccessGroup"
    public static let sharedKVSIdentifierInfoKey =
        "AetherRouteSharedKVSIdentifier"
    public static let tunnelBundleIdentifierInfoKey =
        "AetherRouteTunnelBundleIdentifier"
    public static let transparentProxyBundleIdentifierInfoKey =
        "AetherRouteTransparentProxyBundleIdentifier"
    public static let profileArchiveTypeIdentifierInfoKey =
        "AetherRouteProfileArchiveTypeIdentifier"

    public static let appGroup = requiredIdentityValue(appGroupInfoKey)
    public static let keychainAccessGroupSuffix = requiredIdentityValue(
        keychainAccessGroupSuffixInfoKey
    )
    public static let tunnelBundleIdentifier = requiredIdentityValue(
        tunnelBundleIdentifierInfoKey
    )
    public static let transparentProxyBundleIdentifier = requiredIdentityValue(
        transparentProxyBundleIdentifierInfoKey
    )
    public static let profileArchiveTypeIdentifier = requiredIdentityValue(
        profileArchiveTypeIdentifierInfoKey
    )
    public static let localizedDescription = "AetherRoute"
    public static let transparentProxyLocalizedDescription =
        "AetherRoute (Transparent Proxy)"

    static func optionalIdentityValue(
        _ key: String,
        bundle: Bundle = Bundle(for: AetherRouteIdentityBundleMarker.self)
    ) -> String? {
        guard let value = bundle.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty,
              value == value.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ),
              !value.contains("$("),
              !value.contains("${") else {
            return nil
        }
        return value
    }

    private static func requiredIdentityValue(
        _ key: String,
        bundle: Bundle = Bundle(for: AetherRouteIdentityBundleMarker.self)
    ) -> String {
        guard let value = optionalIdentityValue(key, bundle: bundle) else {
            preconditionFailure(
                "Required build identity value \(key) is missing or unresolved."
            )
        }
        return value
    }

    /// Returns the fully qualified Keychain access group produced by Xcode's
    /// `$(AppIdentifierPrefix)` expansion in the current host or extension.
    ///
    /// `Bundle.main` is intentional: AetherRouteKit is shared by the app and
    /// both Network Extension processes, and each executable carries the same
    /// Info.plist key with its own build-time expansion.
    public static func keychainAccessGroup(
        bundle: Bundle = .main
    ) throws -> String {
        try keychainAccessGroup(
            infoDictionary: bundle.infoDictionary ?? [:]
        )
    }

    static func keychainAccessGroup(
        infoDictionary: [String: Any]
    ) throws -> String {
        guard let value = infoDictionary[keychainAccessGroupInfoKey] as? String
        else {
            throw KeychainAccessGroupResolutionError.missingInfoValue
        }
        return try validateKeychainAccessGroup(value)
    }

    public static let sharedKeychainAccessGroupSuffix = "com.aetherroute.shared"

    static func validateKeychainAccessGroup(_ value: String) throws -> String {
        guard !value.isEmpty else {
            throw KeychainAccessGroupResolutionError.emptyValue
        }
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            throw KeychainAccessGroupResolutionError.invalidValue(value)
        }
        guard !value.contains("$("), !value.contains("${") else {
            throw KeychainAccessGroupResolutionError.unresolvedBuildSetting(
                value
            )
        }

        let localSuffix = ".\(keychainAccessGroupSuffix)"
        let sharedSuffix = ".\(sharedKeychainAccessGroupSuffix)"
        let matchedSuffix: String
        if value.hasSuffix(localSuffix) {
            matchedSuffix = localSuffix
        } else if value.hasSuffix(sharedSuffix) {
            matchedSuffix = sharedSuffix
        } else {
            throw KeychainAccessGroupResolutionError.unexpectedSuffix(value)
        }

        let prefix = value.dropLast(matchedSuffix.count)
        let validPrefixCharacters = CharacterSet(
            charactersIn:
                "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
        )
        guard !prefix.isEmpty,
              prefix.unicodeScalars.allSatisfy({ scalar in
                  validPrefixCharacters.contains(scalar)
              }) else {
            throw KeychainAccessGroupResolutionError.invalidValue(value)
        }
        return value
    }

    /// Returns the fully qualified cross-platform shared Keychain access group
    /// (e.g. `$(AppIdentifierPrefix)com.aetherroute.shared`) for multi-device sync.
    public static func sharedKeychainAccessGroup(
        bundle: Bundle = .main
    ) throws -> String {
        try sharedKeychainAccessGroup(
            infoDictionary: bundle.infoDictionary ?? [:]
        )
    }

    static func sharedKeychainAccessGroup(
        infoDictionary: [String: Any]
    ) throws -> String {
        if let value = infoDictionary[sharedKeychainAccessGroupInfoKey] as? String,
           !value.isEmpty,
           !value.contains("$("),
           !value.contains("${") {
            return try validateKeychainAccessGroup(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return try keychainAccessGroup(infoDictionary: infoDictionary)
    }

    public static func sharedKVSIdentifier(
        bundle: Bundle = .main
    ) -> String? {
        if let value = (bundle.infoDictionary ?? [:])[sharedKVSIdentifierInfoKey] as? String,
           !value.isEmpty,
           !value.contains("$("),
           !value.contains("${") {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }
}

public enum KeychainAccessGroupResolutionError: LocalizedError, Equatable,
    Sendable
{
    case missingInfoValue
    case emptyValue
    case unresolvedBuildSetting(String)
    case unexpectedSuffix(String)
    case invalidValue(String)

    public var errorDescription: String? {
        switch self {
        case .missingInfoValue:
            "The shared Keychain access group is missing from this executable's Info.plist."
        case .emptyValue:
            "The shared Keychain access group is empty. A signed build with an App Identifier Prefix is required."
        case let .unresolvedBuildSetting(value):
            "The shared Keychain access group contains an unresolved build setting: \(value)"
        case let .unexpectedSuffix(value):
            "The shared Keychain access group has an unexpected suffix: \(value)"
        case let .invalidValue(value):
            "The shared Keychain access group is invalid: \(value)"
        }
    }
}

public enum RoutingMode: String, CaseIterable, Codable, Sendable {
    case rule
    case global
    case direct

    public var title: String {
        switch self {
        case .rule: "Rule"
        case .global: "Global"
        case .direct: "Direct"
        }
    }

    public var packetFlowABIValue: Int32 {
        switch self {
        case .rule: 0
        case .global: 1
        case .direct: 2
        }
    }
}

public struct TunnelConfiguration: Codable, Equatable, Sendable {
    /// Synthetic resolver address routed into `NEPacketTunnelFlow`.
    ///
    /// NetworkExtension may bind public DNS server addresses to the underlying
    /// interface, bypassing the packet-flow DNS hijack. The core intercepts
    /// port 53 at this address and applies the active profile's real DNS,
    /// fake-IP, fallback, and routing policies.
    public static let packetFlowDNSServers = ["198.18.0.2"]

    public var mode: RoutingMode
    public var mtu: Int
    public var ipv4Address: String
    public var ipv4SubnetMask: String
    public var ipv6Address: String
    public var ipv6PrefixLength: Int
    /// Claiming the IPv6 default route is only safe when the active profile
    /// says its outbounds can carry IPv6. A profile that omits the top-level
    /// `ipv6` switch is IPv4-only, exactly as the protocol core reads it, and
    /// installing `::/0` for it black-holes every flow the system's Happy
    /// Eyeballs prefers over IPv6 instead of letting it fall back to IPv4.
    public var enableIPv6: Bool
    public var dnsServers: [String]
    public var excludeLocalNetworks: Bool
    public var localProxy: LocalProxySettings
    public var controlledListeners: [ControlledListenerSpec]

    public init(
        mode: RoutingMode = .rule,
        mtu: Int = 1_500,
        ipv4Address: String = "198.18.0.1",
        ipv4SubnetMask: String = "255.255.0.0",
        ipv6Address: String = "fd00:a37e:0:1::1",
        ipv6PrefixLength: Int = 64,
        enableIPv6: Bool = false,
        dnsServers: [String] = TunnelConfiguration.packetFlowDNSServers,
        excludeLocalNetworks: Bool = true,
        localProxy: LocalProxySettings = LocalProxySettings(),
        controlledListeners: [ControlledListenerSpec] = []
    ) {
        self.mode = mode
        self.mtu = mtu
        self.ipv4Address = ipv4Address
        self.ipv4SubnetMask = ipv4SubnetMask
        self.ipv6Address = ipv6Address
        self.ipv6PrefixLength = ipv6PrefixLength
        self.enableIPv6 = enableIPv6
        self.dnsServers = dnsServers
        self.excludeLocalNetworks = excludeLocalNetworks
        self.localProxy = localProxy
        self.controlledListeners = controlledListeners
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.mode = try container.decode(RoutingMode.self, forKey: .mode)
        self.mtu = try container.decode(Int.self, forKey: .mtu)
        self.ipv4Address = try container.decode(String.self, forKey: .ipv4Address)
        self.ipv4SubnetMask = try container.decode(String.self, forKey: .ipv4SubnetMask)
        self.ipv6Address = try container.decode(String.self, forKey: .ipv6Address)
        self.ipv6PrefixLength = try container.decode(Int.self, forKey: .ipv6PrefixLength)
        self.enableIPv6 = try container.decode(Bool.self, forKey: .enableIPv6)
        self.dnsServers = try container.decode([String].self, forKey: .dnsServers)
        self.excludeLocalNetworks = try container.decode(Bool.self, forKey: .excludeLocalNetworks)
        self.localProxy = try container.decode(LocalProxySettings.self, forKey: .localProxy)
        self.controlledListeners = try container.decodeIfPresent(
            [ControlledListenerSpec].self,
            forKey: .controlledListeners
        ) ?? []
    }

    public func validated() throws -> Self {
        guard (1_280...9_000).contains(mtu) else {
            throw TunnelConfigurationError.invalidMTU(mtu)
        }
        guard IPv4Address(ipv4Address) != nil else {
            throw TunnelConfigurationError.invalidIPv4Address(ipv4Address)
        }
        guard IPv4Address(ipv4SubnetMask) != nil else {
            throw TunnelConfigurationError.invalidSubnetMask(ipv4SubnetMask)
        }
        guard IPv6Address(ipv6Address) != nil else {
            throw TunnelConfigurationError.invalidIPv6Address(ipv6Address)
        }
        guard (1...128).contains(ipv6PrefixLength) else {
            throw TunnelConfigurationError.invalidIPv6PrefixLength(
                ipv6PrefixLength
            )
        }
        guard !dnsServers.isEmpty,
              dnsServers.allSatisfy({
                  IPv4Address($0) != nil || IPv6Address($0) != nil
              }) else {
            throw TunnelConfigurationError.invalidDNSServers
        }
        do {
            _ = try localProxy.validated()
            _ = try ExternalControllerSettings(
                controlledListenersEnabled: !controlledListeners.isEmpty,
                controlledListeners: controlledListeners
            ).validated(localProxy: localProxy)
        } catch {
            throw TunnelConfigurationError.invalidLocalProxy
        }
        return self
    }
}

public enum TunnelConfigurationError: LocalizedError, Equatable {
    case invalidMTU(Int)
    case invalidIPv4Address(String)
    case invalidSubnetMask(String)
    case invalidIPv6Address(String)
    case invalidIPv6PrefixLength(Int)
    case invalidDNSServers
    case invalidLocalProxy

    public var errorDescription: String? {
        switch self {
        case let .invalidMTU(value): "MTU \(value) is outside the supported range."
        case let .invalidIPv4Address(value): "\(value) is not a valid IPv4 address."
        case let .invalidSubnetMask(value): "\(value) is not a valid IPv4 subnet mask."
        case let .invalidIPv6Address(value): "\(value) is not a valid IPv6 address."
        case let .invalidIPv6PrefixLength(value):
            "IPv6 prefix length \(value) is outside the supported range."
        case .invalidDNSServers:
            "At least one valid IPv4 or IPv6 DNS server is required."
        case .invalidLocalProxy:
            "The local proxy settings are invalid."
        }
    }
}

private struct IPv6Address {
    init?(_ value: String) {
        var address = in6_addr()
        guard value.withCString({ pointer in
            inet_pton(AF_INET6, pointer, &address)
        }) == 1 else {
            return nil
        }
    }
}

private struct IPv4Address {
    init?(_ value: String) {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4,
              components.allSatisfy({ part in
                  guard let octet = UInt8(part), String(octet) == part else { return false }
                  return true
              }) else {
            return nil
        }
    }
}

/// Bounded O(1) ring buffer for Packet Tunnel egress packets with poison-packet
/// isolation. Prevents O(N) front-insertions and 500Hz infinite livelocks when
/// `NEPacketTunnelFlow.writePackets` rejects a malformed or unsupported packet
/// (such as an IPv6 packet on an IPv4-only utun interface).
public struct PacketTunnelOutputRingBuffer: Sendable {
    public struct WriteSlice: Sendable {
        public let packets: [Data]
        public let protocols: [NSNumber]
        public let isSinglePacketIsolation: Bool
    }

    public enum WriteDisposition: Equatable, Sendable {
        case continueImmediately
        case retryAfterBackoff
        case drained
    }

    public static let maximumIPPacketBytes = 65_535
    private static let ipv4Protocol = NSNumber(value: AF_INET)
    private static let ipv6Protocol = NSNumber(value: AF_INET6)

    public let capacity: Int
    public let maxBatchRetries: Int

    private var packetRing: [Data?]
    private var protocolRing: [NSNumber?]
    private var head: Int = 0
    public private(set) var count: Int = 0
    public private(set) var isFlushScheduled: Bool = false
    private var retryAttempt: Int = 0
    private var isolatingRemainingCount: Int = 0
    public private(set) var droppedPoisonPacketCount: UInt64 = 0
    public private(set) var droppedDisabledIPv6PacketCount: UInt64 = 0

    public init(capacity: Int = 4_096, maxBatchRetries: Int = 2) {
        let safeCapacity = max(1, capacity)
        self.capacity = safeCapacity
        self.maxBatchRetries = max(0, maxBatchRetries)
        self.packetRing = Array(repeating: nil, count: safeCapacity)
        self.protocolRing = Array(repeating: nil, count: safeCapacity)
    }

    /// Enqueues an outgoing IP packet. Returns `true` when the caller must
    /// schedule `flushPendingPackets()` on the packet output queue.
    public mutating func enqueue(
        packet: Data,
        ipVersion: UInt8,
        enableIPv6: Bool
    ) -> Bool {
        guard !packet.isEmpty, packet.count <= Self.maximumIPPacketBytes else {
            return false
        }
        guard ipVersion == 4 || ipVersion == 6 else {
            return false
        }
        if ipVersion == 6 && !enableIPv6 {
            droppedDisabledIPv6PacketCount &+= 1
            return false
        }
        let proto = ipVersion == 6 ? Self.ipv6Protocol : Self.ipv4Protocol

        if count == capacity {
            // Drop oldest packet in O(1) under extreme high-water mark.
            packetRing[head] = nil
            protocolRing[head] = nil
            head = (head + 1) % capacity
            count -= 1
            retryAttempt = 0
            if isolatingRemainingCount > 0 {
                isolatingRemainingCount -= 1
            }
        }

        let tail = (head + count) % capacity
        packetRing[tail] = packet
        protocolRing[tail] = proto
        count += 1

        if !isFlushScheduled {
            isFlushScheduled = true
            return true
        }
        return false
    }

    /// Peeks the next write slice without removing it from the ring buffer.
    public mutating func nextWriteSlice(maxBatchSize: Int = 32) -> WriteSlice? {
        guard count > 0 else {
            isFlushScheduled = false
            retryAttempt = 0
            isolatingRemainingCount = 0
            return nil
        }
        let isIsolating = isolatingRemainingCount > 0
        let sliceCount = isIsolating ? 1 : min(count, max(1, maxBatchSize))
        var packets: [Data] = []
        var protocols: [NSNumber] = []
        packets.reserveCapacity(sliceCount)
        protocols.reserveCapacity(sliceCount)
        for offset in 0..<sliceCount {
            let idx = (head + offset) % capacity
            if let pkt = packetRing[idx], let proto = protocolRing[idx] {
                packets.append(pkt)
                protocols.append(proto)
            }
        }
        guard !packets.isEmpty else {
            clear()
            return nil
        }
        return WriteSlice(
            packets: packets,
            protocols: protocols,
            isSinglePacketIsolation: isIsolating || packets.count == 1
        )
    }

    /// Commits or retries the peeked slice after `packetFlow.writePackets`.
    public mutating func completeWriteSlice(
        succeeded: Bool,
        sliceCount: Int
    ) -> WriteDisposition {
        let effectiveSliceCount = min(max(0, sliceCount), count)
        guard effectiveSliceCount > 0 else {
            isFlushScheduled = false
            retryAttempt = 0
            isolatingRemainingCount = 0
            return .drained
        }

        if succeeded {
            consumeFromHead(effectiveSliceCount)
            retryAttempt = 0
            if isolatingRemainingCount > 0 {
                isolatingRemainingCount = max(0, isolatingRemainingCount - effectiveSliceCount)
            }
            if count == 0 {
                isFlushScheduled = false
                return .drained
            }
            return .continueImmediately
        }

        // Write failed (`writePackets` returned false).
        if isolatingRemainingCount > 0 || effectiveSliceCount == 1 {
            if retryAttempt < maxBatchRetries {
                retryAttempt += 1
                isFlushScheduled = true
                return .retryAfterBackoff
            }
            // Retries exhausted on this single packet -> isolate and drop poison packet!
            consumeFromHead(1)
            droppedPoisonPacketCount &+= 1
            retryAttempt = 0
            if isolatingRemainingCount > 0 {
                isolatingRemainingCount -= 1
            }
            if count == 0 {
                isFlushScheduled = false
                return .drained
            }
            return .continueImmediately
        } else {
            if retryAttempt < maxBatchRetries {
                retryAttempt += 1
                isFlushScheduled = true
                return .retryAfterBackoff
            }
            // Multi-packet batch failed repeatedly: switch to single-packet isolation
            // across this batch so valid packets are delivered and only the poison packet is dropped.
            isolatingRemainingCount = effectiveSliceCount
            retryAttempt = 0
            isFlushScheduled = true
            return .continueImmediately
        }
    }

    public mutating func clear() {
        for i in 0..<count {
            let idx = (head + i) % capacity
            packetRing[idx] = nil
            protocolRing[idx] = nil
        }
        head = 0
        count = 0
        isFlushScheduled = false
        retryAttempt = 0
        isolatingRemainingCount = 0
    }

    private mutating func consumeFromHead(_ k: Int) {
        let clamped = min(k, count)
        for _ in 0..<clamped {
            packetRing[head] = nil
            protocolRing[head] = nil
            head = (head + 1) % capacity
            count -= 1
        }
        if count == 0 {
            head = 0
        }
    }
}

/// FIFO async operation gate used by Network Extension providers to serialize
/// callback-based multi-step operations (such as `.reloadProfile`) without
/// blocking their control message DispatchQueue.
public final class AsyncSerialOperationGate: @unchecked Sendable {
    private final class CompletionOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var callback: (@Sendable () -> Void)?

        init(_ callback: @escaping @Sendable () -> Void) {
            self.callback = callback
        }

        func finish() {
            lock.lock()
            let cb = callback
            callback = nil
            lock.unlock()
            cb?()
        }
    }

    private let lock = NSLock()
    private var isRunning = false
    private var waiters: [@Sendable (@escaping @Sendable () -> Void) -> Void] = []

    public init() {}

    public func enqueue(
        _ operation: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void
    ) {
        let shouldStartImmediately: Bool = {
            lock.lock()
            defer { lock.unlock() }
            if isRunning {
                waiters.append(operation)
                return false
            }
            isRunning = true
            return true
        }()

        if shouldStartImmediately {
            startOperation(operation)
        }
    }

    public func run(
        _ operation: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void
    ) async {
        await withCheckedContinuation { continuation in
            enqueue { done in
                operation {
                    done()
                    continuation.resume()
                }
            }
        }
    }

    private func startOperation(
        _ operation: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void
    ) {
        let once = CompletionOnce { [weak self] in
            self?.advance()
        }
        operation {
            once.finish()
        }
    }

    private func advance() {
        let next: (@Sendable (@escaping @Sendable () -> Void) -> Void)? = {
            lock.lock()
            defer { lock.unlock() }
            if waiters.isEmpty {
                isRunning = false
                return nil
            }
            return waiters.removeFirst()
        }()

        if let next {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.startOperation(next)
            }
        }
    }
}
