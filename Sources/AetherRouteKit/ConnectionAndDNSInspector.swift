import Darwin
import Foundation

public enum ConnectionRouteDecisionStage: String, CaseIterable, Equatable, Sendable {
    case routingMode
    case hostsResolution
    case applicationRule
    case customDestinationRule
    case profileRule
    case outboundChain
}

public enum ConnectionRouteDecisionStatus: String, Equatable, Sendable {
    case matched
    case passed
    case skipped
}

public struct ConnectionRouteDecisionStep: Identifiable, Equatable, Sendable {
    public var id: ConnectionRouteDecisionStage { stage }
    public let stage: ConnectionRouteDecisionStage
    public let status: ConnectionRouteDecisionStatus
    public let summary: String
    public let detail: String?

    public init(
        stage: ConnectionRouteDecisionStage,
        status: ConnectionRouteDecisionStatus,
        summary: String,
        detail: String? = nil
    ) {
        self.stage = stage
        self.status = status
        self.summary = summary
        self.detail = detail
    }
}

public struct ConnectionRouteDecisionTrace: Equatable, Sendable {
    public let steps: [ConnectionRouteDecisionStep]
    public let resolvedHostAlias: String?
    public let matchedApplicationRule: CustomRule?
    public let matchedCustomRule: CustomRule?
    public let matchedRuleOrder: Int?
    public let matchedRuleSummary: String
    public let outboundHops: [String]

    public init(
        steps: [ConnectionRouteDecisionStep],
        resolvedHostAlias: String?,
        matchedApplicationRule: CustomRule?,
        matchedCustomRule: CustomRule?,
        matchedRuleOrder: Int?,
        matchedRuleSummary: String,
        outboundHops: [String]
    ) {
        self.steps = steps
        self.resolvedHostAlias = resolvedHostAlias
        self.matchedApplicationRule = matchedApplicationRule
        self.matchedCustomRule = matchedCustomRule
        self.matchedRuleOrder = matchedRuleOrder
        self.matchedRuleSummary = matchedRuleSummary
        self.outboundHops = outboundHops
    }

    public static func evaluate(
        connection: ConnectionTelemetry,
        routingMode: RoutingMode,
        customHosts: [CustomHostMapping] = [],
        customRules: [CustomRule] = [],
        summary: ProfileConfigurationSummary? = nil
    ) -> ConnectionRouteDecisionTrace {
        let host = DNSLookupInspector.normalizeHost(connection.destination) ?? ""
        let targetDestination: String = {
            let trimmed = connection.destination.trimmingCharacters(in: .whitespacesAndNewlines)
            if connection.destinationPort > 0, !trimmed.contains(":") {
                return "\(trimmed):\(connection.destinationPort)"
            }
            return trimmed
        }()
        let parsedHops = connection.proxyChain
            .components(separatedBy: "→")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let hops = parsedHops.isEmpty && !connection.proxyChain.isEmpty ? [connection.proxyChain] : parsedHops

        // Step 1: Routing Mode
        let isLoopbackTarget = RouteMatchEngine.isLoopbackOrLocalhostDestination(targetDestination)
            || (!host.isEmpty && RouteMatchEngine.isLoopbackOrLocalhostDestination(host))
        let modeStep: ConnectionRouteDecisionStep
        switch routingMode {
        case .rule:
            modeStep = ConnectionRouteDecisionStep(
                stage: .routingMode,
                status: .passed,
                summary: "Rule mode",
                detail: isLoopbackTarget
                    ? "Loopback / RFC 6761 localhost traffic is pinned to DIRECT before user rules"
                    : "Evaluates local hosts, custom rules, and profile rules in order"
            )
        case .global:
            modeStep = ConnectionRouteDecisionStep(
                stage: .routingMode,
                status: .matched,
                summary: isLoopbackTarget ? "Global mode (Loopback DIRECT)" : "Global mode",
                detail: isLoopbackTarget
                    ? "Loopback / RFC 6761 localhost traffic stays on DIRECT and never enters the global proxy group"
                    : "All traffic routes through the global proxy group without consulting rules"
            )
        case .direct:
            modeStep = ConnectionRouteDecisionStep(
                stage: .routingMode,
                status: .matched,
                summary: "Direct mode",
                detail: "All traffic connects directly without consulting rules"
            )
        }

        // Step 2: Local Hosts Resolution
        let activeHosts = Dictionary(
            customHosts.filter(\.isEnabled).map { ($0.domain.lowercased(), $0.ip) },
            uniquingKeysWith: { _, last in last }
        )
        let resolvedHost = host.isEmpty ? "" : ProfileHostsInspector.resolveAlias(host, in: activeHosts)
        let resolvedAlias: String? = (!host.isEmpty && resolvedHost != host) ? resolvedHost : nil
        let hostsStep: ConnectionRouteDecisionStep
        if let resolvedAlias {
            hostsStep = ConnectionRouteDecisionStep(
                stage: .hostsResolution,
                status: .matched,
                summary: "\(host) → \(resolvedAlias)",
                detail: "Matched custom local host mapping"
            )
        } else {
            hostsStep = ConnectionRouteDecisionStep(
                stage: .hostsResolution,
                status: .passed,
                summary: "No custom host mapping matched",
                detail: activeHosts.isEmpty ? nil : "\(activeHosts.count) active host mappings checked"
            )
        }

        // Step 3: Application Rules
        let enabledAppRules = customRules.filter { $0.isEnabled && $0.kind == .application }
        var matchedAppRule: CustomRule?
        if routingMode == .rule {
            matchedAppRule = enabledAppRules.first { rule in
                let parts = rule.value.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
                let bundleID = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let bundlePath = parts.count > 1
                    ? (parts[1].removingPercentEncoding ?? parts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                    : ""
                if !bundleID.isEmpty,
                   !connection.sourceAppIdentifier.isEmpty,
                   bundleID.caseInsensitiveCompare(connection.sourceAppIdentifier) == .orderedSame {
                    return true
                }
                if !bundlePath.isEmpty,
                   !connection.sourceAppPath.isEmpty,
                   connection.sourceAppPath.hasPrefix(bundlePath) {
                    return true
                }
                return false
            }
        }
        let appRuleStep: ConnectionRouteDecisionStep
        if routingMode != .rule {
            appRuleStep = ConnectionRouteDecisionStep(
                stage: .applicationRule,
                status: .skipped,
                summary: "Skipped outside Rule mode"
            )
        } else if let matchedAppRule {
            let appTitle = Self.applicationName(matchedAppRule.value)
            appRuleStep = ConnectionRouteDecisionStep(
                stage: .applicationRule,
                status: .matched,
                summary: "\(appTitle) → \(matchedAppRule.target.rawString)",
                detail: "Matched application routing rule"
            )
        } else {
            appRuleStep = ConnectionRouteDecisionStep(
                stage: .applicationRule,
                status: .passed,
                summary: "No application rule matched",
                detail: enabledAppRules.isEmpty ? nil : "\(enabledAppRules.count) application rules checked"
            )
        }

        // Step 4: Custom Destination Rules
        let enabledDestRules = customRules.filter { $0.isEnabled && $0.kind != .application }
        var matchedDestRule: CustomRule?
        if routingMode == .rule && matchedAppRule == nil {
            let syntheticSummaries = enabledDestRules.enumerated().map { idx, rule in
                RuleConfigurationSummary(
                    id: idx,
                    order: idx + 1,
                    kind: rule.kind.rawValue,
                    criteria: rule.value,
                    target: rule.target.rawString,
                    isCustom: true,
                    noResolve: rule.noResolve
                )
            }
            if let hit = RouteMatchEngine.evaluate(
                destination: targetDestination,
                against: syntheticSummaries,
                totalRuleCount: syntheticSummaries.count
            ), hit.order >= 1, hit.order <= enabledDestRules.count {
                matchedDestRule = enabledDestRules[hit.order - 1]
            } else if let resolvedAlias,
                      let aliasHit = RouteMatchEngine.evaluate(
                          destination: resolvedAlias,
                          against: syntheticSummaries,
                          totalRuleCount: syntheticSummaries.count
                      ),
                      aliasHit.order >= 1, aliasHit.order <= enabledDestRules.count {
                matchedDestRule = enabledDestRules[aliasHit.order - 1]
            }
        }
        let customDestStep: ConnectionRouteDecisionStep
        if routingMode != .rule {
            customDestStep = ConnectionRouteDecisionStep(
                stage: .customDestinationRule,
                status: .skipped,
                summary: "Skipped outside Rule mode"
            )
        } else if matchedAppRule != nil {
            customDestStep = ConnectionRouteDecisionStep(
                stage: .customDestinationRule,
                status: .skipped,
                summary: "Bypassed by earlier application rule"
            )
        } else if let matchedDestRule {
            customDestStep = ConnectionRouteDecisionStep(
                stage: .customDestinationRule,
                status: .matched,
                summary: "\(matchedDestRule.kind.rawValue) \(matchedDestRule.value) → \(matchedDestRule.target.rawString)",
                detail: "Matched high-priority custom destination rule"
            )
        } else {
            customDestStep = ConnectionRouteDecisionStep(
                stage: .customDestinationRule,
                status: .passed,
                summary: "No custom destination rule matched",
                detail: enabledDestRules.isEmpty ? nil : "\(enabledDestRules.count) custom destination rules checked"
            )
        }

        // Step 5: Profile Rule Evaluation
        let ruleKindDisplay = ClashRuleKindName.display(connection.rule)
        let rulePayloadTrimmed = connection.rulePayload.trimmingCharacters(in: .whitespacesAndNewlines)
        let formattedRuleSummary = rulePayloadTrimmed.isEmpty ? ruleKindDisplay : "\(ruleKindDisplay) \(rulePayloadTrimmed)"
        var matchedOrder: Int?
        if routingMode == .rule, let allRules = summary?.allRules {
            if let exact = allRules.first(where: { rule in
                let kindMatches = rule.kind.caseInsensitiveCompare(ruleKindDisplay) == .orderedSame
                    || (rulePayloadTrimmed.isEmpty
                        && (ruleKindDisplay == "MATCH" || ruleKindDisplay == "FINAL")
                        && (rule.kind.uppercased() == "MATCH" || rule.kind.uppercased() == "FINAL"))
                guard kindMatches else { return false }
                let criteria = (rule.criteria ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return criteria.caseInsensitiveCompare(rulePayloadTrimmed) == .orderedSame
            }) {
                matchedOrder = exact.order
            } else if let previewHit = RouteMatchEngine.evaluate(
                destination: targetDestination,
                against: allRules,
                totalRuleCount: summary?.ruleCount
            ) {
                matchedOrder = previewHit.order
            }
        }
        let profileRuleStep: ConnectionRouteDecisionStep
        if routingMode != .rule {
            profileRuleStep = ConnectionRouteDecisionStep(
                stage: .profileRule,
                status: .skipped,
                summary: "Skipped outside Rule mode"
            )
        } else if matchedAppRule != nil || matchedDestRule != nil {
            profileRuleStep = ConnectionRouteDecisionStep(
                stage: .profileRule,
                status: .skipped,
                summary: "Bypassed by earlier custom rule",
                detail: matchedOrder.map { "Rule #\($0)" }
            )
        } else {
            profileRuleStep = ConnectionRouteDecisionStep(
                stage: .profileRule,
                status: .matched,
                summary: matchedOrder.map { "Rule #\($0) · \(formattedRuleSummary)" } ?? formattedRuleSummary,
                detail: "Authoritative engine rule match"
            )
        }

        // Step 6: Outbound Hop Chain
        let timingDetail: String?
        if let timing = ConnectionTimingBreakdown.resolve(for: connection) {
            timingDetail = "DNS \(timing.dnsMilliseconds) ms · Handshake \(timing.connectMilliseconds) ms · Total \(timing.totalMilliseconds) ms"
        } else {
            timingDetail = hops.count > 1 ? "\(hops.count)-hop outbound path" : nil
        }
        let outboundStep = ConnectionRouteDecisionStep(
            stage: .outboundChain,
            status: .matched,
            summary: hops.isEmpty ? connection.proxyChain : hops.joined(separator: " → "),
            detail: timingDetail
        )

        return ConnectionRouteDecisionTrace(
            steps: [
                modeStep,
                hostsStep,
                appRuleStep,
                customDestStep,
                profileRuleStep,
                outboundStep,
            ],
            resolvedHostAlias: resolvedAlias,
            matchedApplicationRule: matchedAppRule,
            matchedCustomRule: matchedDestRule,
            matchedRuleOrder: matchedOrder,
            matchedRuleSummary: formattedRuleSummary,
            outboundHops: hops
        )
    }

    private static func applicationName(_ payload: String) -> String {
        guard let separator = payload.firstIndex(of: ";") else { return payload }
        let identifier = String(payload[..<separator])
        let path = String(payload[payload.index(after: separator)...])
            .removingPercentEncoding ?? ""
        if !path.isEmpty {
            let name = (path as NSString).lastPathComponent
            return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        }
        return identifier.isEmpty ? payload : identifier
    }
}

public struct DNSLookupReport: Equatable, Sendable {
    public let query: String
    public let normalizedHost: String
    public let matchedCustomHostIP: String?
    public let effectiveMode: DNSResolutionMode
    public let respectsRules: Bool
    public let matchedRouteTarget: String?
    public let matchedRuleOrder: Int?
    public let matchedRuleSummary: String?
    public let resolvedAddresses: [String]
    public let containsFakeIPAddress: Bool
    public let latencyMilliseconds: Int?

    public init(
        query: String,
        normalizedHost: String,
        matchedCustomHostIP: String?,
        effectiveMode: DNSResolutionMode,
        respectsRules: Bool,
        matchedRouteTarget: String?,
        matchedRuleOrder: Int?,
        matchedRuleSummary: String?,
        resolvedAddresses: [String],
        containsFakeIPAddress: Bool,
        latencyMilliseconds: Int?
    ) {
        self.query = query
        self.normalizedHost = normalizedHost
        self.matchedCustomHostIP = matchedCustomHostIP
        self.effectiveMode = effectiveMode
        self.respectsRules = respectsRules
        self.matchedRouteTarget = matchedRouteTarget
        self.matchedRuleOrder = matchedRuleOrder
        self.matchedRuleSummary = matchedRuleSummary
        self.resolvedAddresses = resolvedAddresses
        self.containsFakeIPAddress = containsFakeIPAddress
        self.latencyMilliseconds = latencyMilliseconds
    }
}

public enum DNSLookupInspector {
    public static func normalizeHost(_ query: String) -> String? {
        let raw = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !raw.isEmpty, !raw.contains(where: { $0.isWhitespace }) else { return nil }
        var ipv4 = in_addr()
        if raw.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 { return raw }
        var ipv6 = in6_addr()
        if raw.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 { return raw }

        let value = raw.contains("://") ? raw : "https://" + raw
        guard let url = URLComponents(string: value),
              url.user == nil,
              url.password == nil,
              var host = url.host,
              !host.isEmpty else {
            return nil
        }
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        if host.hasSuffix(".") {
            host.removeLast()
        }
        guard !host.isEmpty else { return nil }
        return host
    }

    /// Checks whether an IPv4 (`198.18.0.0/15`) or IPv6 (`fc00::/18`) literal
    /// falls within the standard Fake-IP address pools used by the engine.
    public static func isFakeIPAddress(_ address: String) -> Bool {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        var ipv4 = in_addr()
        if trimmed.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            let bytes = withUnsafeBytes(of: ipv4) { Array($0) }
            return bytes.count == 4 && bytes[0] == 198 && (bytes[1] & 0xfe) == 18
        }
        var ipv6 = in6_addr()
        if trimmed.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
            let bytes = withUnsafeBytes(of: ipv6) { Array($0) }
            return bytes.count == 16 && bytes[0] == 0xfc && (bytes[1] & 0xc0) == 0x00
        }
        return false
    }

    public static func evaluate(
        query: String,
        summary: ProfileConfigurationSummary?,
        customHosts: [CustomHostMapping] = [],
        dnsModeOverride: DNSResolutionMode? = nil,
        geoSiteData: Data? = nil,
        resolvedAddresses: [String] = [],
        latencyMilliseconds: Int? = nil
    ) -> DNSLookupReport? {
        guard let host = normalizeHost(query) else { return nil }
        let activeHosts = Dictionary(
            customHosts.filter(\.isEnabled).map { ($0.domain.lowercased(), $0.ip) },
            uniquingKeysWith: { _, last in last }
        )
        let resolvedHost = ProfileHostsInspector.resolveAlias(host, in: activeHosts)
        let matchedCustomIP: String? = resolvedHost != host ? resolvedHost : nil

        let effectiveMode = dnsModeOverride ?? summary?.dns.mode ?? .normal
        let respectsRules = summary?.dns.respectsRules ?? false

        var routeMatch: RouteMatchResult?
        if let summary {
            let directMatch = RouteMatchEngine.evaluate(
                destination: host,
                against: summary.allRules,
                totalRuleCount: summary.ruleCount,
                geoSiteData: geoSiteData
            )
            if let matchedCustomIP {
                let aliasMatch = RouteMatchEngine.evaluate(
                    destination: matchedCustomIP,
                    against: summary.allRules,
                    totalRuleCount: summary.ruleCount,
                    geoSiteData: geoSiteData
                )
                if let aliasMatch, let directMatch {
                    routeMatch = aliasMatch.order < directMatch.order ? aliasMatch : directMatch
                } else {
                    routeMatch = aliasMatch ?? directMatch
                }
            } else {
                routeMatch = directMatch
            }
        }

        let matchedRuleSummary: String? = routeMatch.map { match in
            if let criteria = match.matchedRule.criteria, !criteria.isEmpty {
                return "\(match.matchedRule.kind) \(criteria)"
            }
            return match.matchedRule.kind
        }

        let effectiveAddresses = resolvedAddresses.isEmpty
            ? (matchedCustomIP.map { [$0] } ?? [])
            : resolvedAddresses
        let hasFakeIP = effectiveAddresses.contains(where: isFakeIPAddress)

        return DNSLookupReport(
            query: query,
            normalizedHost: host,
            matchedCustomHostIP: matchedCustomIP,
            effectiveMode: effectiveMode,
            respectsRules: respectsRules,
            matchedRouteTarget: routeMatch?.target,
            matchedRuleOrder: routeMatch?.order,
            matchedRuleSummary: matchedRuleSummary,
            resolvedAddresses: effectiveAddresses,
            containsFakeIPAddress: hasFakeIP,
            latencyMilliseconds: latencyMilliseconds
        )
    }

    public static func resolveSystemAddresses(
        for host: String
    ) async -> (addresses: [String], latencyMilliseconds: Int) {
        let normalized = normalizeHost(host) ?? host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return ([], 0) }
        return await Task.detached(priority: .userInitiated) {
            let start = CFAbsoluteTimeGetCurrent()
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_STREAM
            var res: UnsafeMutablePointer<addrinfo>?
            let status = normalized.withCString { cHost in
                getaddrinfo(cHost, nil, &hints, &res)
            }
            let elapsedMs = max(0, Int(((CFAbsoluteTimeGetCurrent() - start) * 1_000.0).rounded()))
            guard status == 0, let first = res else {
                if let res { freeaddrinfo(res) }
                return ([], elapsedMs)
            }
            defer { freeaddrinfo(first) }
            var addresses: [String] = []
            var seen = Set<String>()
            var cursor: UnsafeMutablePointer<addrinfo>? = first
            while let info = cursor {
                if let addr = info.pointee.ai_addr {
                    var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    let nameStatus = getnameinfo(
                        addr,
                        info.pointee.ai_addrlen,
                        &hostBuffer,
                        socklen_t(hostBuffer.count),
                        nil,
                        0,
                        NI_NUMERICHOST
                    )
                    if nameStatus == 0 {
                        let endIndex = hostBuffer.firstIndex(of: 0) ?? hostBuffer.count
                        let ip = String(
                            decoding: hostBuffer[..<endIndex].map(UInt8.init(bitPattern:)),
                            as: UTF8.self
                        )
                        if !ip.isEmpty, seen.insert(ip).inserted {
                            addresses.append(ip)
                        }
                    }
                }
                cursor = info.pointee.ai_next
            }
            return (addresses, elapsedMs)
        }.value
    }
}

public enum RouteTraceNetwork: String, CaseIterable, Codable, Equatable, Sendable {
    case tcp
    case udp
}

public struct RouteTraceRequest: Codable, Equatable, Sendable {
    public var host: String
    public var ip: String?
    public var port: Int
    public var network: RouteTraceNetwork
    public var processPath: String?

    public init(
        host: String,
        ip: String? = nil,
        port: Int = 443,
        network: RouteTraceNetwork = .tcp,
        processPath: String? = nil
    ) {
        self.host = host
        self.ip = ip
        self.port = port
        self.network = network
        self.processPath = processPath
    }
}

public enum RouteTraceSource: String, Codable, Equatable, Sendable {
    case liveProvider
    case staticFallback
}

public struct RouteTraceResult: Codable, Equatable, Sendable {
    public let routingMode: RoutingMode
    public let matchedRuleKind: String
    public let matchedRuleCriteria: String?
    public let matchedRuleOrder: Int?
    public let targetOutbound: String
    public let outboundChain: [String]
    public let resolvedHostAlias: String?
    public let dnsAddresses: [String]
    public let dnsLatencyMilliseconds: Int?
    public let isFakeIP: Bool
    public let source: RouteTraceSource

    public init(
        routingMode: RoutingMode,
        matchedRuleKind: String,
        matchedRuleCriteria: String?,
        matchedRuleOrder: Int?,
        targetOutbound: String,
        outboundChain: [String],
        resolvedHostAlias: String? = nil,
        dnsAddresses: [String] = [],
        dnsLatencyMilliseconds: Int? = nil,
        isFakeIP: Bool = false,
        source: RouteTraceSource
    ) {
        self.routingMode = routingMode
        self.matchedRuleKind = matchedRuleKind
        self.matchedRuleCriteria = matchedRuleCriteria
        self.matchedRuleOrder = matchedRuleOrder
        self.targetOutbound = targetOutbound
        self.outboundChain = outboundChain
        self.resolvedHostAlias = resolvedHostAlias
        self.dnsAddresses = dnsAddresses
        self.dnsLatencyMilliseconds = dnsLatencyMilliseconds
        self.isFakeIP = isFakeIP
        self.source = source
    }
}

public enum RouteSimulationInspector {
    public static func evaluate(
        request: RouteTraceRequest,
        routingMode: RoutingMode,
        profileYAML: String? = nil,
        summary: ProfileConfigurationSummary?,
        proxySelections: [String: String] = [:],
        customRules: [CustomRule] = [],
        customHosts: [CustomHostMapping] = [],
        asnLookup: (@Sendable (String) -> String?)? = nil,
        geoSiteData: Data? = nil,
        resolvedAddresses: [String] = [],
        dnsLatencyMilliseconds: Int? = nil,
        source: RouteTraceSource = .staticFallback
    ) -> RouteTraceResult {
        _ = profileYAML
        let rawHost = request.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedHost = DNSLookupInspector.normalizeHost(rawHost) ?? rawHost.lowercased()
        let rawIP = request.ip?.trimmingCharacters(in: .whitespacesAndNewlines)
        let explicitIP = (rawIP?.isEmpty == false) ? rawIP : nil
        let hostAsIP = isIPAddress(normalizedHost) ? normalizedHost : nil

        let activeHosts = Dictionary(
            customHosts.filter(\.isEnabled).map { ($0.domain.lowercased(), $0.ip) },
            uniquingKeysWith: { _, last in last }
        )
        let alias = ProfileHostsInspector.resolveAlias(normalizedHost, in: activeHosts)
        let resolvedHostAlias: String? = alias != normalizedHost ? alias : nil

        let effectiveAddresses: [String]
        if !resolvedAddresses.isEmpty {
            effectiveAddresses = resolvedAddresses
        } else if let explicitIP {
            effectiveAddresses = [explicitIP]
        } else if let resolvedHostAlias, isIPAddress(resolvedHostAlias) {
            effectiveAddresses = [resolvedHostAlias]
        } else if let hostAsIP {
            effectiveAddresses = [hostAsIP]
        } else {
            effectiveAddresses = []
        }

        let effectiveIP = explicitIP
            ?? hostAsIP
            ?? (resolvedHostAlias.flatMap { isIPAddress($0) ? $0 : nil })
            ?? effectiveAddresses.first(where: { isIPAddress($0) })
        let isFakeIP = effectiveAddresses.contains(where: DNSLookupInspector.isFakeIPAddress)

        if routingMode == .direct {
            return RouteTraceResult(
                routingMode: routingMode,
                matchedRuleKind: "DIRECT-MODE",
                matchedRuleCriteria: nil,
                matchedRuleOrder: nil,
                targetOutbound: "DIRECT",
                outboundChain: ["DIRECT"],
                resolvedHostAlias: resolvedHostAlias,
                dnsAddresses: effectiveAddresses,
                dnsLatencyMilliseconds: dnsLatencyMilliseconds,
                isFakeIP: isFakeIP,
                source: source
            )
        }

        if routingMode == .global {
            let chain = resolveOutboundChain(
                startingAt: "GLOBAL",
                summary: summary,
                proxySelections: proxySelections
            )
            return RouteTraceResult(
                routingMode: routingMode,
                matchedRuleKind: "GLOBAL-MODE",
                matchedRuleCriteria: nil,
                matchedRuleOrder: nil,
                targetOutbound: "GLOBAL",
                outboundChain: chain,
                resolvedHostAlias: resolvedHostAlias,
                dnsAddresses: effectiveAddresses,
                dnsLatencyMilliseconds: dnsLatencyMilliseconds,
                isFakeIP: isFakeIP,
                source: source
            )
        }

        // Custom rules (application then destination)
        let context = TraceEvaluationContext(
            host: hostAsIP == nil ? normalizedHost : "",
            resolvedHostAlias: resolvedHostAlias,
            ip: effectiveIP,
            nonNoResolveIP: effectiveIP ?? resolvedAddresses.first(where: { isIPAddress($0) }),
            port: request.port,
            network: request.network,
            processPath: request.processPath?.trimmingCharacters(in: .whitespacesAndNewlines),
            asnLookup: asnLookup,
            geoSiteData: geoSiteData
        )

        let enabledCustomRules = customRules.filter(\.isEnabled)
        for rule in enabledCustomRules where rule.kind == .application {
            if matchesCustomApplicationRule(rule, processPath: context.processPath) {
                let target = rule.target.rawString
                return RouteTraceResult(
                    routingMode: routingMode,
                    matchedRuleKind: rule.kind.rawValue,
                    matchedRuleCriteria: rule.value,
                    matchedRuleOrder: nil,
                    targetOutbound: target,
                    outboundChain: resolveOutboundChain(startingAt: target, summary: summary, proxySelections: proxySelections),
                    resolvedHostAlias: resolvedHostAlias,
                    dnsAddresses: effectiveAddresses,
                    dnsLatencyMilliseconds: dnsLatencyMilliseconds,
                    isFakeIP: isFakeIP,
                    source: source
                )
            }
        }

        for (index, rule) in enabledCustomRules.enumerated() where rule.kind != .application {
            let synthetic = RuleConfigurationSummary(
                id: index,
                order: index + 1,
                kind: rule.kind.rawValue,
                criteria: rule.value,
                target: rule.target.rawString,
                isCustom: true,
                noResolve: rule.noResolve
            )
            if matchesRule(synthetic, context: context) {
                let target = rule.target.rawString
                return RouteTraceResult(
                    routingMode: routingMode,
                    matchedRuleKind: rule.kind.rawValue,
                    matchedRuleCriteria: rule.value,
                    matchedRuleOrder: nil,
                    targetOutbound: target,
                    outboundChain: resolveOutboundChain(startingAt: target, summary: summary, proxySelections: proxySelections),
                    resolvedHostAlias: resolvedHostAlias,
                    dnsAddresses: effectiveAddresses,
                    dnsLatencyMilliseconds: dnsLatencyMilliseconds,
                    isFakeIP: isFakeIP,
                    source: source
                )
            }
        }

        if let allRules = summary?.allRules {
            for rule in allRules {
                if matchesRule(rule, context: context) {
                    let kindDisplay = ClashRuleKindName.display(rule.kind)
                    let chain = resolveOutboundChain(
                        startingAt: rule.target,
                        summary: summary,
                        proxySelections: proxySelections
                    )
                    return RouteTraceResult(
                        routingMode: routingMode,
                        matchedRuleKind: kindDisplay,
                        matchedRuleCriteria: rule.criteria,
                        matchedRuleOrder: rule.order,
                        targetOutbound: rule.target,
                        outboundChain: chain,
                        resolvedHostAlias: resolvedHostAlias,
                        dnsAddresses: effectiveAddresses,
                        dnsLatencyMilliseconds: dnsLatencyMilliseconds,
                        isFakeIP: isFakeIP,
                        source: source
                    )
                }
            }
        }

        return RouteTraceResult(
            routingMode: routingMode,
            matchedRuleKind: "UNMATCHED",
            matchedRuleCriteria: nil,
            matchedRuleOrder: nil,
            targetOutbound: "DIRECT",
            outboundChain: ["DIRECT"],
            resolvedHostAlias: resolvedHostAlias,
            dnsAddresses: effectiveAddresses,
            dnsLatencyMilliseconds: dnsLatencyMilliseconds,
            isFakeIP: isFakeIP,
            source: source
        )
    }

    private struct TraceEvaluationContext {
        let host: String
        let resolvedHostAlias: String?
        let ip: String?
        let nonNoResolveIP: String?
        let port: Int
        let network: RouteTraceNetwork
        let processPath: String?
        let asnLookup: (@Sendable (String) -> String?)?
        let geoSiteData: Data?
    }

    private static func matchesCustomApplicationRule(_ rule: CustomRule, processPath: String?) -> Bool {
        guard let processPath, !processPath.isEmpty else { return false }
        let components = rule.value.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
        let bundleID = components.first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rulePath = components.count > 1
            ? (String(components[1]).removingPercentEncoding ?? String(components[1]))
            : ""
        if !rulePath.isEmpty && (processPath == rulePath || processPath.hasPrefix(rulePath + "/")) {
            return true
        }
        if !bundleID.isEmpty && processPath.localizedCaseInsensitiveContains(bundleID) {
            return true
        }
        return false
    }

    private static func matchesRule(_ rule: RuleConfigurationSummary, context: TraceEvaluationContext) -> Bool {
        let kind = rule.kind.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let criteria = (rule.criteria ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        switch kind {
        case "MATCH", "FINAL":
            return true
        case "NETWORK":
            return criteria.caseInsensitiveCompare(context.network.rawValue) == .orderedSame
        case "PROCESS-PATH":
            guard let processPath = context.processPath, !processPath.isEmpty, !criteria.isEmpty else {
                return false
            }
            return processPath == criteria
        case "PROCESS-NAME":
            guard let processPath = context.processPath, !processPath.isEmpty, !criteria.isEmpty else {
                return false
            }
            let base = (processPath as NSString).lastPathComponent
            return base.caseInsensitiveCompare(criteria) == .orderedSame
        case "DST-PORT", "SRC-PORT":
            return matchesPortExpression(criteria, port: context.port)
        case "DOMAIN-REGEX":
            guard !criteria.isEmpty, !context.host.isEmpty else { return false }
            return matchesRegex(pattern: criteria, against: context.host)
        case "DOMAIN-WILDCARD":
            guard !criteria.isEmpty, !context.host.isEmpty else { return false }
            return matchesWildcard(pattern: criteria, against: context.host)
        case "IP-ASN":
            let targetIP = rule.noResolve ? context.ip : (context.ip ?? context.nonNoResolveIP)
            guard let targetIP, let asnLookup = context.asnLookup,
                  let resolvedASN = asnLookup(targetIP)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !resolvedASN.isEmpty else {
                return false
            }
            let expected = normalizedASN(criteria)
            let actual = normalizedASN(resolvedASN)
            return !expected.isEmpty && expected == actual
        case "AND", "OR", "NOT":
            return matchesLogicalRule(kind: kind, criteria: criteria, noResolve: rule.noResolve, context: context)
        case "DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD", "GEOSITE":
            var candidates: [String] = []
            if !context.host.isEmpty { candidates.append(context.host) }
            if let alias = context.resolvedHostAlias, !alias.isEmpty, !isIPAddress(alias) {
                candidates.append(alias)
            }
            for candidate in candidates {
                let single = RuleConfigurationSummary(
                    id: rule.id,
                    order: rule.order,
                    kind: kind,
                    criteria: criteria,
                    target: rule.target,
                    isCustom: rule.isCustom,
                    noResolve: rule.noResolve
                )
                if RouteMatchEngine.evaluate(
                    destination: "\(candidate):\(context.port)",
                    against: [single],
                    totalRuleCount: 1,
                    geoSiteData: context.geoSiteData
                ) != nil {
                    return true
                }
            }
            return false
        case "IP-CIDR", "IP-CIDR6", "GEOIP", "SRC-IP-CIDR":
            let targetIP = rule.noResolve ? context.ip : (context.ip ?? context.nonNoResolveIP)
            guard let targetIP, !targetIP.isEmpty else { return false }
            let normalizedKind = kind == "SRC-IP-CIDR" ? "IP-CIDR" : kind
            let single = RuleConfigurationSummary(
                id: rule.id,
                order: rule.order,
                kind: normalizedKind,
                criteria: criteria,
                target: rule.target,
                isCustom: rule.isCustom,
                noResolve: rule.noResolve
            )
            return RouteMatchEngine.evaluate(
                destination: targetIP,
                against: [single],
                totalRuleCount: 1,
                geoSiteData: context.geoSiteData
            ) != nil
        default:
            return false
        }
    }

    private static func matchesLogicalRule(
        kind: String,
        criteria: String,
        noResolve: Bool,
        context: TraceEvaluationContext
    ) -> Bool {
        let inner = unwrapOuterParentheses(criteria)
        let childrenRaw = splitTopLevelComma(inner)
        guard !childrenRaw.isEmpty else { return false }

        if kind == "NOT" {
            guard childrenRaw.count == 1,
                  let childRule = parseEmbeddedRule(childrenRaw[0], noResolve: noResolve) else {
                return false
            }
            return !matchesRule(childRule, context: context)
        }

        let childRules = childrenRaw.compactMap { parseEmbeddedRule($0, noResolve: noResolve) }
        guard childRules.count == childrenRaw.count else { return false }

        switch kind {
        case "AND":
            return childRules.allSatisfy { matchesRule($0, context: context) }
        case "OR":
            return childRules.contains { matchesRule($0, context: context) }
        default:
            return false
        }
    }

    private static func parseEmbeddedRule(_ raw: String, noResolve: Bool) -> RuleConfigurationSummary? {
        let unwrapped = unwrapOuterParentheses(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        let parts = splitTopLevelComma(unwrapped)
        guard let kind = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines), !kind.isEmpty else {
            return nil
        }
        let childCriteria = parts.count > 1
            ? parts.dropFirst().joined(separator: ", ").trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        return RuleConfigurationSummary(
            id: 0,
            order: 0,
            kind: kind,
            criteria: childCriteria,
            target: "EMBEDDED",
            isCustom: false,
            noResolve: noResolve
        )
    }

    private static func unwrapOuterParentheses(_ text: String) -> String {
        var current = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while current.hasPrefix("(") && current.hasSuffix(")") {
            var depth = 0
            var wrapsEntireString = true
            let lastIndex = current.index(before: current.endIndex)
            for idx in current.indices {
                let ch = current[idx]
                if ch == "(" { depth += 1 }
                else if ch == ")" { depth -= 1 }
                if depth == 0 && idx != lastIndex {
                    wrapsEntireString = false
                    break
                }
            }
            guard wrapsEntireString && depth == 0 else { break }
            current = String(current.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return current
    }

    private static func splitTopLevelComma(_ text: String) -> [String] {
        var result: [String] = []
        var depth = 0
        var start = text.startIndex
        for idx in text.indices {
            let ch = text[idx]
            if ch == "(" { depth += 1 }
            else if ch == ")" { depth = max(0, depth - 1) }
            else if ch == "," && depth == 0 {
                let segment = String(text[start..<idx]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !segment.isEmpty { result.append(segment) }
                start = text.index(after: idx)
            }
        }
        let tail = String(text[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { result.append(tail) }
        return result
    }

    private static func matchesPortExpression(_ criteria: String, port: Int) -> Bool {
        for token in criteria.split(whereSeparator: { $0 == "/" || $0 == "," || $0 == " " }) {
            let part = String(token)
            if let exact = Int(part), exact == port {
                return true
            }
            let bounds = part.split(separator: "-", maxSplits: 1)
            if bounds.count == 2, let low = Int(bounds[0]), let high = Int(bounds[1]), low <= high {
                if (low...high).contains(port) {
                    return true
                }
            }
        }
        return false
    }

    private static func matchesRegex(pattern: String, against host: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return false
        }
        let range = NSRange(host.startIndex..<host.endIndex, in: host)
        return regex.firstMatch(in: host, options: [], range: range) != nil
    }

    private static func matchesWildcard(pattern: String, against host: String) -> Bool {
        var regexPattern = "^"
        var idx = pattern.startIndex
        while idx < pattern.endIndex {
            let ch = pattern[idx]
            if ch == "*" {
                let next = pattern.index(after: idx)
                if next < pattern.endIndex && pattern[next] == "*" {
                    regexPattern += ".*"
                    idx = pattern.index(after: next)
                    continue
                } else {
                    regexPattern += "[^.]*"
                }
            } else if ch == "?" {
                regexPattern += "[^.]"
            } else if ch == "+" {
                regexPattern += "[^.]+"
            } else {
                regexPattern += NSRegularExpression.escapedPattern(for: String(ch))
            }
            idx = pattern.index(after: idx)
        }
        regexPattern += "$"
        return matchesRegex(pattern: regexPattern, against: host)
    }

    private static func normalizedASN(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if trimmed.hasPrefix("AS") {
            return String(trimmed.dropFirst(2))
        }
        return trimmed
    }

    private static func isIPAddress(_ candidate: String) -> Bool {
        var ipv4 = in_addr()
        if candidate.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 { return true }
        var ipv6 = in6_addr()
        if candidate.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 { return true }
        return false
    }

    private static func resolveOutboundChain(
        startingAt target: String,
        summary: ProfileConfigurationSummary?,
        proxySelections: [String: String]
    ) -> [String] {
        var chain: [String] = []
        var visited = Set<String>()
        var cursor = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cursor.isEmpty else { return [] }

        while !cursor.isEmpty, chain.count < 12, visited.insert(cursor).inserted {
            chain.append(cursor)
            let upper = cursor.uppercased()
            if upper == "DIRECT" || upper == "REJECT" || upper == "REJECT-DROP" || upper == "PASS" {
                break
            }
            if let selected = proxySelections[cursor]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !selected.isEmpty {
                cursor = selected
                continue
            }
            if let group = summary?.proxyGroups.first(where: { $0.name == cursor }),
               let firstMember = group.members.first,
               !firstMember.isEmpty {
                cursor = firstMember
                continue
            }
            break
        }
        return chain
    }
}
