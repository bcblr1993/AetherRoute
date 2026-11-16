import Foundation

/// Something an override could not do, shown next to it instead of failing
/// the connection.
public enum ProfileOverrideDiagnostic: Equatable, Sendable {
    /// No node matched the group's rules; it falls back to DIRECT.
    case noMatchingNodes(group: String)
    /// The group's name is already a node or group in the profile.
    case nameConflict(group: String)
    /// The group to list this one in is not in the profile.
    case parentGroupMissing(group: String, parent: String)
    /// The first-hop dialer proxy named by a chained proxy is not in the profile.
    case dialerProxyMissing(chain: String, dialer: String)
    /// The existing target node named by a chained proxy is not in the profile.
    case targetNodeMissing(chain: String, target: String)
    /// A group could not be rewritten safely (anchors, nested mappings…),
    /// so it was left exactly as the profile has it.
    case groupNotEditable(group: String)
    /// The profile is written in a form the compiler does not edit.
    case unsupportedProfileLayout
}

/// The profile with an override applied.
public struct ProfileOverrideResult: Equatable, Sendable {
    public let yaml: String
    public let diagnostics: [ProfileOverrideDiagnostic]
    /// Each custom group's members, in profile order, for previews.
    public let customGroupMembers: [String: [String]]
    /// Nodes taken out of every group by the hidden keywords.
    public let hiddenNodes: [String]
    /// Each emitted chained proxy's name → its first-hop `dialerProxy`.
    public let chainedProxies: [String: String]
    /// Auto-generated `select` group holding chained proxies with `parentGroup == nil`.
    public let standaloneChainedProxyGroupName: String?

    public init(
        yaml: String,
        diagnostics: [ProfileOverrideDiagnostic],
        customGroupMembers: [String: [String]],
        hiddenNodes: [String],
        chainedProxies: [String: String] = [:],
        standaloneChainedProxyGroupName: String? = nil
    ) {
        self.yaml = yaml
        self.diagnostics = diagnostics
        self.customGroupMembers = customGroupMembers
        self.hiddenNodes = hiddenNodes
        self.chainedProxies = chainedProxies
        self.standaloneChainedProxyGroupName = standaloneChainedProxyGroupName
    }
}

/// Applies a `ProfileOverride` to a profile's text (1.7.0).
///
/// Only three kinds of change are made, each at a known place:
/// - custom groups are appended at the end of `proxy-groups` as one-line
///   mappings, so the profile's primary selector stays first;
/// - a group that lists a custom group, or lost hidden nodes, is rewritten
///   as a one-line mapping with every one of its fields kept;
/// - every other line stays byte for byte.
/// A group the compiler cannot read with certainty (anchors, nested
/// mappings, multi-line scalars) is never rewritten. The result is parsed
/// again; when it does not show the expected groups the original text is
/// returned with a diagnostic, so an override can never break a profile.
public enum ProfileOverrideCompiler {
    public static func apply(
        _ override: ProfileOverride?,
        globalOverride: ProfileOverride? = nil,
        externalRuleProviders: [RuleProviderMetadata] = [],
        ruleProviderCacheDirectoryURL: URL? = nil,
        externalRules: [String] = [],
        to yaml: String
    ) -> ProfileOverrideResult {
        let compiledExternalRules = resolveExternalRules(
            externalRuleProviders: externalRuleProviders,
            cacheDirectoryURL: ruleProviderCacheDirectoryURL,
            explicitExternalRules: externalRules
        )

        if let globalOverride, !globalOverride.isEmpty {
            let filteredGlobal = filterGlobalOverride(globalOverride, shadowedBy: override)
            if !filteredGlobal.isEmpty {
                let hasPerProfile = override.map { !$0.isEmpty } ?? false
                let globalResult = applySingle(
                    filteredGlobal,
                    externalRules: hasPerProfile ? [] : compiledExternalRules,
                    to: yaml
                )
                guard let override, !override.isEmpty else {
                    return globalResult
                }
                let profileResult = applySingle(
                    override,
                    externalRules: compiledExternalRules,
                    to: globalResult.yaml
                )
                return mergeResults(globalResult, profileResult)
            }
        }
        return applySingle(override, externalRules: compiledExternalRules, to: yaml)
    }

    private static func resolveExternalRules(
        externalRuleProviders: [RuleProviderMetadata],
        cacheDirectoryURL: URL?,
        explicitExternalRules: [String]
    ) -> [String] {
        let cachedProviderRules: [String]
        if externalRuleProviders.isEmpty {
            cachedProviderRules = []
        } else {
            cachedProviderRules = RuleProviderEngine.compileCachedRules(
                for: externalRuleProviders,
                cacheDirectoryURL: cacheDirectoryURL
            )
        }
        var merged: [String] = []
        var seen = Set<String>()
        for raw in cachedProviderRules + explicitExternalRules {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.filter { !$0.isWhitespace }.uppercased()
            if seen.insert(key).inserted {
                merged.append(trimmed)
            }
        }
        return merged
    }

    private static func filterGlobalOverride(
        _ global: ProfileOverride,
        shadowedBy perProfile: ProfileOverride?
    ) -> ProfileOverride {
        guard let perProfile, !perProfile.isEmpty else { return global }
        let overriddenGroupNames = Set(perProfile.groups.map(\.name))
            .union(perProfile.chainedProxies.map(\.name))
        let overriddenHostDomains = Set(
            perProfile.customHosts.map { $0.domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        )
        var filtered = global
        filtered.groups = global.groups.filter { !overriddenGroupNames.contains($0.name) }
        filtered.chainedProxies = global.chainedProxies.filter { !overriddenGroupNames.contains($0.name) }
        filtered.customHosts = global.customHosts.filter {
            !overriddenHostDomains.contains($0.domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
        return filtered
    }

    private static func mergeResults(
        _ first: ProfileOverrideResult,
        _ second: ProfileOverrideResult
    ) -> ProfileOverrideResult {
        var combinedHidden = first.hiddenNodes
        var seenHidden = Set(combinedHidden)
        for node in second.hiddenNodes where seenHidden.insert(node).inserted {
            combinedHidden.append(node)
        }
        return ProfileOverrideResult(
            yaml: second.yaml,
            diagnostics: first.diagnostics + second.diagnostics,
            customGroupMembers: first.customGroupMembers.merging(second.customGroupMembers) { _, new in new },
            hiddenNodes: combinedHidden,
            chainedProxies: first.chainedProxies.merging(second.chainedProxies) { _, new in new },
            standaloneChainedProxyGroupName: second.standaloneChainedProxyGroupName ?? first.standaloneChainedProxyGroupName
        )
    }

    private static func applySingle(
        _ override: ProfileOverride?,
        externalRules: [String] = [],
        to yaml: String
    ) -> ProfileOverrideResult {
        let effectiveOverride = override ?? ProfileOverride()
        if yaml.first(where: { !$0.isWhitespace }) == "{" {
            return applyToJSON(effectiveOverride, externalRules: externalRules, json: yaml)
        }
        let document = YAMLDocument(yaml)
        if effectiveOverride.isEmpty && externalRules.isEmpty && document.nodeDialerProxies.isEmpty {
            return ProfileOverrideResult(yaml: yaml, diagnostics: [], customGroupMembers: [:], hiddenNodes: [])
        }
        guard document.isEditable else {
            if effectiveOverride.isEmpty && externalRules.isEmpty {
                return ProfileOverrideResult(yaml: yaml, diagnostics: [], customGroupMembers: [:], hiddenNodes: [])
            }
            return ProfileOverrideResult(
                yaml: yaml,
                diagnostics: [.unsupportedProfileLayout],
                customGroupMembers: [:],
                hiddenNodes: []
            )
        }
        let plan = Plan(
            override: effectiveOverride,
            nodes: document.nodeNames,
            nodeDialerProxies: document.nodeDialerProxies,
            groups: document.groups.map { ($0.name, $0.members) },
            nodeTokens: document.nodeTokens,
            yamlCloner: { targetName, newName, dialer in
                document.clonedProxyLines(
                    from: targetName,
                    newName: newName,
                    dialerProxy: dialer
                )
            },
            proxyItemIndent: document.proxyItemIndent
        )
        let newExternalRules = document.filterUnseenRules(externalRules)
        if effectiveOverride.isEmpty && plan.strippedBaseDialerProxies.isEmpty && newExternalRules.isEmpty {
            return ProfileOverrideResult(yaml: yaml, diagnostics: [], customGroupMembers: [:], hiddenNodes: [])
        }
        var diagnostics = plan.diagnostics

        var rewritten: [Int: String] = [:]
        for (index, group) in document.groups.enumerated() {
            let members = plan.members(of: group.name, original: group.memberTokens)
            guard members != group.memberTokens else { continue }
            guard let line = group.flowLine(members: members) else {
                diagnostics.append(.groupNotEditable(group: group.name))
                continue
            }
            rewritten[index] = line
        }
        let output = document.render(
            replacingGroups: rewritten,
            insertingGroups: plan.customGroupLines,
            insertingProxies: plan.chainedProxyLines,
            insertingHosts: plan.customHosts,
            strippingDialerProxies: plan.strippedBaseDialerProxies,
            insertingRules: newExternalRules
        )
        // The result must show every group and proxy the profile had plus the
        // custom ones; anything else means the edit went wrong.
        let check = ProfileConfigurationInspector.inspect(yaml: output)
        let expectedGroups = document.groups.count + plan.customGroupLines.count
        let expectedProxies = document.nodeNames.count + plan.emittedChainedProxies.count
        let actualDefinedProxies = check.proxyCount + check.subscriptionNoticeNames.count
        let customNames = Set(plan.emittedCustomGroups)
        let found = Set(check.proxyGroups.map(\.name))
        guard check.proxyGroupCount == expectedGroups,
              actualDefinedProxies == expectedProxies,
              customNames.isSubset(of: found) || check.proxyGroups.count < check.proxyGroupCount
        else {
            return ProfileOverrideResult(
                yaml: yaml,
                diagnostics: [.unsupportedProfileLayout],
                customGroupMembers: plan.customGroupMembers,
                hiddenNodes: plan.hiddenNodes,
                chainedProxies: plan.chainedProxies,
                standaloneChainedProxyGroupName: plan.standaloneChainedProxyGroupName
            )
        }
        return ProfileOverrideResult(
            yaml: output,
            diagnostics: diagnostics,
            customGroupMembers: plan.customGroupMembers,
            hiddenNodes: plan.hiddenNodes,
            chainedProxies: plan.chainedProxies,
            standaloneChainedProxyGroupName: plan.standaloneChainedProxyGroupName
        )
    }

    /// Every node the profile defines, in order (no 500-item display cap).
    public static func nodeNames(in yaml: String) -> [String] {
        if yaml.first(where: { !$0.isWhitespace }) == "{" {
            let root = (try? JSONSerialization.jsonObject(with: Data(yaml.utf8))) as? [String: Any]
            return (root?["proxies"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        }
        return YAMLDocument(yaml).nodeNames
    }

    /// Returns deduplicated proxy names available for custom groups and chained proxies,
    /// incorporating global/per-profile overrides and any additional provider nodes while
    /// excluding nodes matched by hidden keywords.
    public static func availableProxyNames(
        in yaml: String,
        proxyOverride: ProfileOverride? = nil,
        globalOverride: ProfileOverride? = nil,
        additionalProviderNodes: [String] = []
    ) -> [String] {
        var keywords: [String] = []
        if let globalOverride {
            keywords.append(contentsOf: globalOverride.hiddenNodeKeywords.map { $0.lowercased() })
        }
        if let proxyOverride {
            keywords.append(contentsOf: proxyOverride.hiddenNodeKeywords.map { $0.lowercased() })
        }
        func isHidden(_ name: String) -> Bool {
            guard !keywords.isEmpty else { return false }
            let lowered = name.lowercased()
            return keywords.contains(where: { lowered.contains($0) })
        }

        var result: [String] = []
        var seen = Set<String>()
        func appendIfEligible(_ name: String) {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !isHidden(trimmed), seen.insert(trimmed).inserted else { return }
            result.append(trimmed)
        }

        for node in nodeNames(in: yaml) {
            appendIfEligible(node)
        }
        if let globalOverride {
            let filteredGlobal = filterGlobalOverride(globalOverride, shadowedBy: proxyOverride)
            for chain in filteredGlobal.chainedProxies {
                appendIfEligible(chain.name)
            }
        }
        if let proxyOverride {
            for chain in proxyOverride.chainedProxies {
                appendIfEligible(chain.name)
            }
        }
        for providerNode in additionalProviderNodes {
            appendIfEligible(providerNode)
        }
        return result
    }

    // MARK: - Plan

    /// What the override does to this profile, independent of its syntax.
    struct Plan {
        private(set) var diagnostics: [ProfileOverrideDiagnostic] = []
        private(set) var customGroupMembers: [String: [String]] = [:]
        private(set) var emittedCustomGroups: [String] = []
        private(set) var customGroupLines: [String] = []
        private(set) var chainedProxies: [String: String] = [:]
        private(set) var emittedChainedProxies: [String] = []
        private(set) var chainedProxyLines: [String] = []
        private(set) var strippedBaseDialerProxies: Set<String> = []
        private(set) var standaloneChainedProxyGroupName: String?
        private(set) var customHosts: [(domain: String, ip: String)] = []
        let hiddenNodes: [String]
        private let hidden: Set<String>
        /// Parent group → custom groups / chained proxies to add (top, bottom).
        private var insertions: [String: (top: [String], bottom: [String])] = [:]

        /// `nodeTokens` maps a node's name to the way the profile spells it,
        /// so a custom group lists it exactly as the profile's own groups do.
        init(
            override: ProfileOverride,
            nodes: [String],
            nodeDialerProxies: [String: String] = [:],
            groups: [(name: String, members: [String])],
            nodeTokens: [String: String] = [:],
            yamlCloner: ((_ target: String, _ newName: String, _ dialer: String?) -> [String]?)? = nil,
            proxyItemIndent: Int = 2
        ) {
            let keywords = override.hiddenNodeKeywords.map { $0.lowercased() }
            let hiddenNodes = nodes.filter { node in
                let lowered = node.lowercased()
                return keywords.contains(where: { lowered.contains($0) })
            }
            self.hiddenNodes = hiddenNodes
            hidden = Set(hiddenNodes)
            let visible = nodes.filter { !hidden.contains($0) }
            var taken = Set(nodes).union(groups.map(\.name))
            let groupNames = Set(groups.map(\.name))

            for group in override.groups {
                guard !taken.contains(group.name) else {
                    diagnostics.append(.nameConflict(group: group.name))
                    continue
                }
                taken.insert(group.name)
                let members = visible.filter(group.matches)
                customGroupMembers[group.name] = members
                emittedCustomGroups.append(group.name)
                if let parent = group.parentGroup {
                    guard groupNames.contains(parent) else {
                        diagnostics.append(.parentGroupMissing(group: group.name, parent: parent))
                        continue
                    }
                    var entry = insertions[parent] ?? ([], [])
                    switch group.position {
                    case .top: entry.top.append(YAMLDocument.quote(group.name))
                    case .bottom: entry.bottom.append(YAMLDocument.quote(group.name))
                    }
                    insertions[parent] = entry
                }
            }

            let emittedCustomGroupSet = Set(emittedCustomGroups)
            let visibleSet = Set(visible)
            let baseAvailableDialers = visibleSet
                .union(groupNames)
                .union(emittedCustomGroups)

            // First pass: collect candidate chained proxies (checking name conflicts and targets)
            // so mutual or out-of-order chained references can be checked by graph cycle detection.
            enum ChainValidationOutcome {
                case nameConflict
                case targetMissing(String)
                case candidate(ChainedProxyOverride)
            }
            var provisionalTaken = taken
            var chainOutcomes: [(index: Int, chain: ChainedProxyOverride, outcome: ChainValidationOutcome)] = []
            for (idx, chain) in override.chainedProxies.enumerated() {
                guard !provisionalTaken.contains(chain.name) else {
                    chainOutcomes.append((idx, chain, .nameConflict))
                    continue
                }
                if case let .existingNode(targetName) = chain.target, !visibleSet.contains(targetName) {
                    chainOutcomes.append((idx, chain, .targetMissing(targetName)))
                    continue
                }
                provisionalTaken.insert(chain.name)
                chainOutcomes.append((idx, chain, .candidate(chain)))
            }

            // Fixed-point pruning for genuinely missing dialer proxies while keeping mutual/3-way cycles intact.
            var activeCandidateNames = Set(chainOutcomes.compactMap { entry -> String? in
                if case .candidate = entry.outcome { return entry.chain.name }
                return nil
            })
            var pruned = true
            while pruned {
                pruned = false
                let availableDialers = baseAvailableDialers.union(activeCandidateNames)
                for entry in chainOutcomes {
                    guard case let .candidate(chain) = entry.outcome,
                          activeCandidateNames.contains(chain.name),
                          !availableDialers.contains(chain.dialerProxy) else { continue }
                    activeCandidateNames.remove(chain.name)
                    pruned = true
                }
            }

            var acceptedChains: [ChainedProxyOverride] = []
            var standaloneChainedProxies: [String] = []
            for entry in chainOutcomes {
                let chain = entry.chain
                switch entry.outcome {
                case .nameConflict:
                    diagnostics.append(.nameConflict(group: chain.name))
                case let .targetMissing(targetName):
                    diagnostics.append(.targetNodeMissing(chain: chain.name, target: targetName))
                case .candidate:
                    guard activeCandidateNames.contains(chain.name) else {
                        diagnostics.append(.dialerProxyMissing(chain: chain.name, dialer: chain.dialerProxy))
                        continue
                    }
                    acceptedChains.append(chain)
                    taken.insert(chain.name)
                    if let parent = chain.parentGroup {
                        if groupNames.contains(parent) {
                            var insertion = insertions[parent] ?? ([], [])
                            switch chain.position {
                            case .top: insertion.top.append(YAMLDocument.quote(chain.name))
                            case .bottom: insertion.bottom.append(YAMLDocument.quote(chain.name))
                            }
                            insertions[parent] = insertion
                        } else if emittedCustomGroupSet.contains(parent) {
                            var currentMembers = customGroupMembers[parent] ?? []
                            switch chain.position {
                            case .top: currentMembers.insert(chain.name, at: 0)
                            case .bottom: currentMembers.append(chain.name)
                            }
                            customGroupMembers[parent] = currentMembers
                        } else {
                            diagnostics.append(.parentGroupMissing(group: chain.name, parent: parent))
                        }
                    } else {
                        standaloneChainedProxies.append(chain.name)
                    }
                }
            }

            // Directed-graph DFS cycle detection across base proxies, chained overrides, and proxy groups.
            var combinedDialers = nodeDialerProxies
            for chain in acceptedChains {
                combinedDialers[chain.name] = chain.dialerProxy
            }

            var resolvedGroupMembers: [String: [String]] = [:]
            var resolvedGroupOrder: [String] = []
            for group in groups {
                let originalTokens = group.members.map(YAMLDocument.quote)
                let finalTokens = members(of: group.name, original: originalTokens)
                resolvedGroupMembers[group.name] = finalTokens.map(YAMLDocument.unquote)
                resolvedGroupOrder.append(group.name)
            }
            for customGroup in emittedCustomGroups {
                resolvedGroupMembers[customGroup] = customGroupMembers[customGroup] ?? []
                resolvedGroupOrder.append(customGroup)
            }

            if !standaloneChainedProxies.isEmpty,
               let autoGroupName = ProfileOverride.standaloneChainedProxyGroupCandidates.first(where: { !taken.contains($0) }) {
                taken.insert(autoGroupName)
                standaloneChainedProxyGroupName = autoGroupName
                customGroupMembers[autoGroupName] = standaloneChainedProxies
                emittedCustomGroups.append(autoGroupName)
                resolvedGroupMembers[autoGroupName] = standaloneChainedProxies
                resolvedGroupOrder.append(autoGroupName)
            }

            let strippedProxies = ProfileOverrideCompiler.detectAndStripDialerCycles(
                proxyDialers: &combinedDialers,
                proxyOrder: nodes + acceptedChains.map(\.name),
                groupMembers: resolvedGroupMembers,
                groupOrder: resolvedGroupOrder
            )
            let baseNodeSet = Set(nodes)
            strippedBaseDialerProxies = strippedProxies.intersection(baseNodeSet)

            for chain in acceptedChains {
                let effectiveDialer: String? = strippedProxies.contains(chain.name) ? nil : chain.dialerProxy
                let compiledLines: [String]?
                switch chain.target {
                case var .customNode(node):
                    node.name = chain.name
                    node.dialerProxy = effectiveDialer
                    compiledLines = try? AetherNodeProfileCompiler.compileProxyLines(
                        node: node,
                        indent: proxyItemIndent
                    )
                case let .existingNode(targetName):
                    if let yamlCloner {
                        compiledLines = yamlCloner(targetName, chain.name, effectiveDialer)
                    } else {
                        compiledLines = []
                    }
                }
                guard let compiledLines else { continue }
                if let effectiveDialer {
                    chainedProxies[chain.name] = effectiveDialer
                }
                emittedChainedProxies.append(chain.name)
                chainedProxyLines.append(contentsOf: compiledLines)
            }

            for groupName in emittedCustomGroups where groupName != standaloneChainedProxyGroupName {
                if (customGroupMembers[groupName] ?? []).isEmpty {
                    diagnostics.append(.noMatchingNodes(group: groupName))
                }
            }

            let groupKindsByName = Dictionary(uniqueKeysWithValues: override.groups.map { ($0.name, $0.groupKind) })
            for groupName in emittedCustomGroups {
                let members = customGroupMembers[groupName] ?? []
                let kind = groupKindsByName[groupName] ?? .select
                customGroupLines.append(
                    ProfileOverrideCompiler.renderCustomGroupFlowLine(
                        name: groupName,
                        kind: kind,
                        members: members,
                        nodeTokens: nodeTokens
                    )
                )
            }

            for host in override.customHosts where host.isEnabled {
                let domain = host.domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let ip = host.ip.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !domain.isEmpty, !ip.isEmpty else { continue }
                customHosts.append((domain: domain, ip: ip))
            }
        }

        /// A group's member tokens after hiding nodes and adding custom
        /// groups; tokens keep their original spelling.
        func members(of group: String, original: [String]) -> [String] {
            var kept = original.filter { !hidden.contains(YAMLDocument.unquote($0)) }
            if kept.isEmpty, !original.isEmpty { kept = ["DIRECT"] }
            guard let entry = insertions[group] else { return kept }
            return entry.top + kept + entry.bottom
        }
    }

    private static func renderCustomGroupFlowLine(
        name: String,
        kind: CustomProxyGroupKind,
        members: [String],
        nodeTokens: [String: String]
    ) -> String {
        let normalized = kind.normalized()
        var fields: [String] = [
            "name: \(YAMLDocument.quote(name))",
            "type: \(normalized.clashType)",
        ]
        switch normalized {
        case .select:
            break
        case let .urlTest(interval, tolerance):
            fields.append("url: \(YAMLDocument.quote(CustomProxyGroupKind.defaultProbeURL))")
            fields.append("interval: \(interval)")
            fields.append("tolerance: \(tolerance)")
        case let .fallback(interval):
            fields.append("url: \(YAMLDocument.quote(CustomProxyGroupKind.defaultProbeURL))")
            fields.append("interval: \(interval)")
        case let .loadBalance(strategy):
            fields.append("strategy: \(strategy.rawValue)")
            fields.append("url: \(YAMLDocument.quote(CustomProxyGroupKind.defaultProbeURL))")
            fields.append("interval: \(CustomProxyGroupKind.defaultIntervalSeconds)")
        case .smart:
            fields.append("url: \(YAMLDocument.quote(CustomProxyGroupKind.defaultProbeURL))")
            fields.append("interval: \(CustomProxyGroupKind.defaultIntervalSeconds)")
        }
        let proxyTokens = (members.isEmpty ? ["DIRECT"] : members.map {
            YAMLDocument.flowToken(name: $0, written: nodeTokens[$0])
        }).joined(separator: ", ")
        fields.append("proxies: [\(proxyTokens)]")
        return "{\(fields.joined(separator: ", "))}"
    }

    private static func jsonGroupObject(
        name: String,
        kind: CustomProxyGroupKind,
        members: [String]
    ) -> [String: Any] {
        let normalized = kind.normalized()
        var object: [String: Any] = [
            "name": name,
            "type": normalized.clashType,
            "proxies": members.isEmpty ? ["DIRECT"] : members,
        ]
        switch normalized {
        case .select:
            break
        case let .urlTest(interval, tolerance):
            object["url"] = CustomProxyGroupKind.defaultProbeURL
            object["interval"] = interval
            object["tolerance"] = tolerance
        case let .fallback(interval):
            object["url"] = CustomProxyGroupKind.defaultProbeURL
            object["interval"] = interval
        case let .loadBalance(strategy):
            object["strategy"] = strategy.rawValue
            object["url"] = CustomProxyGroupKind.defaultProbeURL
            object["interval"] = CustomProxyGroupKind.defaultIntervalSeconds
        case .smart:
            object["url"] = CustomProxyGroupKind.defaultProbeURL
            object["interval"] = CustomProxyGroupKind.defaultIntervalSeconds
        }
        return object
    }

    private static func detectAndStripDialerCycles(
        proxyDialers: inout [String: String],
        proxyOrder: [String],
        groupMembers: [String: [String]],
        groupOrder: [String]
    ) -> Set<String> {
        guard !proxyDialers.isEmpty else { return [] }

        enum VisitState { case visiting, visited }
        enum Edge { case dialer(proxy: String); case groupMember }

        var stripped = Set<String>()
        let allRoots = proxyOrder + groupOrder

        var strippedInPass = true
        while strippedInPass {
            strippedInPass = false
            var states: [String: VisitState] = [:]
            var pathNodes: [String] = []
            var pathEdges: [Edge?] = []

            func dfs(_ node: String, via incomingEdge: Edge?) {
                if states[node] == .visited { return }
                if states[node] == .visiting {
                    if let cycleStart = pathNodes.firstIndex(of: node) {
                        let cycleEdges: [Edge?] = Array(pathEdges[(cycleStart + 1)...]) + [incomingEdge]
                        if let closingDialerProxy = cycleEdges.reversed().compactMap({ edge -> String? in
                            if case let .dialer(proxy) = edge { return proxy }
                            return nil
                        }).first {
                            if proxyDialers.removeValue(forKey: closingDialerProxy) != nil {
                                stripped.insert(closingDialerProxy)
                                strippedInPass = true
                            }
                        }
                    }
                    return
                }

                states[node] = .visiting
                pathNodes.append(node)
                pathEdges.append(incomingEdge)

                if let dialerTarget = proxyDialers[node] {
                    dfs(dialerTarget, via: .dialer(proxy: node))
                }
                if let members = groupMembers[node] {
                    for member in members {
                        dfs(member, via: .groupMember)
                    }
                }

                pathNodes.removeLast()
                pathEdges.removeLast()
                states[node] = .visited
            }

            for root in allRoots where states[root] == nil {
                dfs(root, via: nil)
            }
        }
        return stripped
    }

    // MARK: - JSON profiles

    private static func applyToJSON(
        _ override: ProfileOverride,
        externalRules: [String] = [],
        json: String
    ) -> ProfileOverrideResult {
        guard var root = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else {
            return ProfileOverrideResult(yaml: json, diagnostics: [.unsupportedProfileLayout], customGroupMembers: [:], hiddenNodes: [])
        }
        var proxies = root["proxies"] as? [[String: Any]] ?? []
        let nodes = proxies.compactMap { $0["name"] as? String }
        var nodeDialerProxies: [String: String] = [:]
        for entry in proxies {
            guard let name = entry["name"] as? String else { continue }
            if let dialer = (entry["dialer-proxy"] as? String) ?? (entry["connect-via"] as? String),
               !dialer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                nodeDialerProxies[name] = dialer
            }
        }
        var groups = root["proxy-groups"] as? [[String: Any]] ?? []
        let plan = Plan(
            override: override,
            nodes: nodes,
            nodeDialerProxies: nodeDialerProxies,
            groups: groups.map { (($0["name"] as? String) ?? "", ($0["proxies"] as? [String]) ?? []) }
        )

        let existingRules = root["rules"] as? [String] ?? []
        let existingRuleKeys = Set(existingRules.map { $0.filter { !$0.isWhitespace }.uppercased() })
        let unseenExternalRules = externalRules.filter {
            !existingRuleKeys.contains($0.filter { !$0.isWhitespace }.uppercased())
        }

        if override.isEmpty && plan.strippedBaseDialerProxies.isEmpty && unseenExternalRules.isEmpty {
            return ProfileOverrideResult(yaml: json, diagnostics: [], customGroupMembers: [:], hiddenNodes: [])
        }

        for index in groups.indices {
            guard let name = groups[index]["name"] as? String,
                  let members = groups[index]["proxies"] as? [String] else { continue }
            let quotedMembers = members.map(YAMLDocument.quote)
            let updated = plan.members(of: name, original: quotedMembers)
            if updated != quotedMembers {
                groups[index]["proxies"] = updated.map(YAMLDocument.unquote)
            }
        }
        if !plan.strippedBaseDialerProxies.isEmpty {
            for idx in proxies.indices {
                if let name = proxies[idx]["name"] as? String,
                   plan.strippedBaseDialerProxies.contains(name) {
                    proxies[idx].removeValue(forKey: "dialer-proxy")
                    proxies[idx].removeValue(forKey: "connect-via")
                }
            }
        }
        var addedProxies: [[String: Any]] = []
        let proxyByName = Dictionary(
            proxies.compactMap { entry -> (String, [String: Any])? in
                guard let name = entry["name"] as? String else { return nil }
                return (name, entry)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let chainByName = Dictionary(
            override.chainedProxies.map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for name in plan.emittedChainedProxies {
            guard let chain = chainByName[name] else { continue }
            let effectiveDialer = plan.chainedProxies[chain.name]
            switch chain.target {
            case var .customNode(node):
                node.name = chain.name
                node.dialerProxy = effectiveDialer
                if let obj = try? AetherNodeProfileCompiler.compileProxyJSONObject(node: node) {
                    addedProxies.append(obj)
                }
            case let .existingNode(targetName):
                if var cloned = proxyByName[targetName] {
                    cloned["name"] = chain.name
                    if let effectiveDialer {
                        cloned["dialer-proxy"] = effectiveDialer
                    } else {
                        cloned.removeValue(forKey: "dialer-proxy")
                    }
                    cloned.removeValue(forKey: "connect-via")
                    addedProxies.append(cloned)
                }
            }
        }
        if !addedProxies.isEmpty || !plan.strippedBaseDialerProxies.isEmpty {
            root["proxies"] = addedProxies + proxies
        }

        let groupKindsByName = Dictionary(uniqueKeysWithValues: override.groups.map { ($0.name, $0.groupKind) })
        var added: [[String: Any]] = []
        for name in plan.emittedCustomGroups {
            let members = plan.customGroupMembers[name] ?? []
            let kind = groupKindsByName[name] ?? .select
            added.append(Self.jsonGroupObject(name: name, kind: kind, members: members))
        }
        root["proxy-groups"] = groups + added
        if !unseenExternalRules.isEmpty {
            root["rules"] = unseenExternalRules + existingRules
        }
        if !plan.customHosts.isEmpty {
            var hostsDict = (root["hosts"] as? [String: Any]) ?? [:]
            for entry in plan.customHosts {
                hostsDict[entry.domain] = entry.ip
            }
            root["hosts"] = hostsDict
        }
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]),
              let output = String(data: data, encoding: .utf8) else {
            return ProfileOverrideResult(yaml: json, diagnostics: [.unsupportedProfileLayout], customGroupMembers: [:], hiddenNodes: [])
        }
        return ProfileOverrideResult(
            yaml: output,
            diagnostics: plan.diagnostics,
            customGroupMembers: plan.customGroupMembers,
            hiddenNodes: plan.hiddenNodes,
            chainedProxies: plan.chainedProxies,
            standaloneChainedProxyGroupName: plan.standaloneChainedProxyGroupName
        )
    }
}

// MARK: - YAML text model

/// Just enough of a Clash profile's YAML to find nodes and groups and to
/// rewrite single groups. Everything else is carried through untouched.
struct YAMLDocument {
    struct Group {
        let name: String
        /// Members as written, quotes included.
        let memberTokens: [String]
        var members: [String] { memberTokens.map(YAMLDocument.unquote) }
        /// Fields in order; nil when the group cannot be rewritten safely.
        let fields: [(key: String, value: Value)]?
        let lineRange: Range<Int>

        enum Value {
            case scalar(String)
            case list([String])
        }

        /// The group as a one-line flow mapping with new members.
        func flowLine(members: [String]) -> String? {
            guard let fields else { return nil }
            var parts: [String] = []
            var wroteMembers = false
            for (key, value) in fields {
                switch value {
                case let .scalar(raw):
                    parts.append("\(key): \(raw)")
                case let .list(items):
                    if key == "proxies" {
                        parts.append("proxies: [\(members.joined(separator: ", "))]")
                        wroteMembers = true
                    } else {
                        parts.append("\(key): [\(items.joined(separator: ", "))]")
                    }
                }
            }
            if !wroteMembers {
                parts.append("proxies: [\(members.joined(separator: ", "))]")
            }
            return "{" + parts.joined(separator: ", ") + "}"
        }
    }

    private(set) var lines: [String]
    private(set) var isEditable = true
    private(set) var nodeNames: [String] = []
    /// Node name → its `name:` value as written, quotes included.
    private(set) var nodeTokens: [String: String] = [:]
    private(set) var nodeDialerProxies: [String: String] = [:]
    private(set) var proxyRanges: [String: Range<Int>] = [:]
    private(set) var proxiesHeader: Int?
    private(set) var proxyItemIndent = 2
    private(set) var groups: [Group] = []
    /// Index of the `proxy-groups:` line and the indent of its items.
    private var groupsHeader: Int?
    private var groupItemIndent = 2
    private var rulesHeader: Int?
    private var rulesHeaderHasEmptyFlow = false
    private var ruleItemIndent = 2
    private var existingNormalizedRules: Set<String> = []
    private var hostsHeader: Int?
    private var hostsItemIndent = 2
    private var existingHostLineByDomain: [String: Int] = [:]

    func filterUnseenRules(_ candidates: [String]) -> [String] {
        var result: [String] = []
        var seen = existingNormalizedRules
        for rule in candidates {
            let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.filter { !$0.isWhitespace }.uppercased()
            if seen.insert(key).inserted {
                result.append(trimmed)
            }
        }
        return result
    }

    init(_ text: String) {
        lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        parse()
    }

    private mutating func parse() {
        var sections: [(key: String, start: Int)] = []
        for (index, line) in lines.enumerated() {
            guard let first = line.first, first != " ", first != "#", first != "-",
                  let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !key.contains(" ") || key.hasPrefix("\"") else { continue }
            sections.append((Self.unquote(key), index))
        }
        for (position, section) in sections.enumerated() {
            let end = position + 1 < sections.count ? sections[position + 1].start : lines.count
            let header = lines[section.start]
            let inline = header[header.index(after: header.firstIndex(of: ":")!)...]
                .trimmingCharacters(in: .whitespaces)
            switch section.key {
            case "proxies":
                guard Self.stripComment(inline).isEmpty else { isEditable = false; return }
                proxiesHeader = section.start
                let found = items(in: (section.start + 1)..<end)
                if let first = found.first {
                    proxyItemIndent = Self.indent(of: lines[first.lowerBound])
                }
                for item in found {
                    let parsed = parseItem(item)
                    guard let name = parsed.name else { continue }
                    nodeNames.append(name)
                    if proxyRanges[name] == nil { proxyRanges[name] = item }
                    if let token = parsed.nameToken { nodeTokens[name] = token }
                    if let dialer = parsed.dialerProxy, !dialer.isEmpty, nodeDialerProxies[name] == nil {
                        nodeDialerProxies[name] = dialer
                    }
                }
            case "proxy-groups":
                guard Self.stripComment(inline).isEmpty else { isEditable = false; return }
                groupsHeader = section.start
                let found = items(in: (section.start + 1)..<end)
                if let first = found.first {
                    groupItemIndent = Self.indent(of: lines[first.lowerBound])
                }
                groups = found.compactMap { range in
                    let item = parseItem(range)
                    guard let name = item.name else { return nil }
                    return Group(
                        name: name,
                        memberTokens: item.members,
                        fields: item.fields,
                        lineRange: range
                    )
                }
            case "hosts":
                let strippedInline = Self.stripComment(inline)
                guard strippedInline.isEmpty || strippedInline == "{}" else {
                    isEditable = false
                    return
                }
                hostsHeader = section.start
                var detectedIndent: Int?
                for index in (section.start + 1)..<end {
                    let line = lines[index]
                    let trimmed = Self.stripComment(line.trimmingCharacters(in: .whitespaces))
                    guard !trimmed.isEmpty, !trimmed.hasPrefix("-") else { continue }
                    let indent = Self.indent(of: line)
                    if detectedIndent == nil, indent > 0 {
                        detectedIndent = indent
                    }
                    if let (key, _) = Self.keyValue(trimmed) {
                        existingHostLineByDomain[key.lowercased()] = index
                    }
                }
                if let detectedIndent {
                    hostsItemIndent = detectedIndent
                }
            case "rules":
                rulesHeader = section.start
                let strippedInline = Self.stripComment(inline)
                rulesHeaderHasEmptyFlow = (strippedInline == "[]")
                var detectedRuleIndent: Int?
                for index in (section.start + 1)..<end {
                    let line = lines[index]
                    let trimmed = Self.stripComment(line.trimmingCharacters(in: .whitespaces))
                    guard !trimmed.isEmpty else { continue }
                    if trimmed.hasPrefix("- ") || trimmed == "-" {
                        if detectedRuleIndent == nil {
                            detectedRuleIndent = Self.indent(of: line)
                        }
                        let rawRule = Self.unquote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                        let norm = rawRule.filter { !$0.isWhitespace }.uppercased()
                        if !norm.isEmpty {
                            existingNormalizedRules.insert(norm)
                        }
                    }
                }
                if let detectedRuleIndent {
                    ruleItemIndent = detectedRuleIndent
                }
            default:
                break
            }
        }
    }

    /// Line ranges of the `- ` items in a section.
    private func items(in range: Range<Int>) -> [Range<Int>] {
        var starts: [Int] = []
        var itemIndent: Int?
        for index in range {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let indent = Self.indent(of: line)
            if itemIndent == nil, trimmed.hasPrefix("-") { itemIndent = indent }
            if indent == itemIndent, trimmed.hasPrefix("- ") || trimmed == "-" {
                starts.append(index)
            }
        }
        var result: [Range<Int>] = []
        for (position, start) in starts.enumerated() {
            var end = position + 1 < starts.count ? starts[position + 1] : range.upperBound
            // Trailing blank or comment lines stay outside the item.
            while end > start + 1 {
                let trimmed = lines[end - 1].trimmingCharacters(in: .whitespaces)
                guard trimmed.isEmpty || trimmed.hasPrefix("#") else { break }
                end -= 1
            }
            result.append(start..<end)
        }
        return result
    }

    private struct ParsedItem {
        var name: String?
        var nameToken: String?
        var dialerProxy: String?
        var members: [String] = []
        var fields: [(key: String, value: Group.Value)]?
    }

    private func parseItem(_ range: Range<Int>) -> ParsedItem {
        let first = lines[range.lowerBound]
        let dash = first.firstIndex(of: "-")!
        let body = first[first.index(after: dash)...].trimmingCharacters(in: .whitespaces)
        if body.hasPrefix("{") {
            let text = range.map { lines[$0] }.joined(separator: " ")
            guard let open = text.firstIndex(of: "{"),
                  let close = text.lastIndex(of: "}") else { return ParsedItem() }
            return parseFlowMapping(String(text[text.index(after: open)..<close]))
        }
        // Fields line up with the text after the dash ("  - name: G" puts
        // them at column 4); an item opened by a bare dash takes the
        // indent of its next line.
        let dashColumn = first.distance(from: first.startIndex, to: dash)
        let gap = first[first.index(after: dash)...].prefix(while: { $0 == " " }).count
        var fieldIndent = dashColumn + 1 + gap
        if body.isEmpty {
            let next = range.dropFirst().first {
                !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty
            }
            fieldIndent = next.map { Self.indent(of: lines[$0]) } ?? dashColumn + 2
        }
        return parseBlockMapping(range, firstBody: body, fieldIndent: fieldIndent)
    }

    private func parseFlowMapping(_ content: String) -> ParsedItem {
        var item = ParsedItem(fields: [])
        for part in Self.splitTopLevel(content, separator: ",") {
            guard let (key, raw) = Self.keyValue(part) else { continue }
            if raw.hasPrefix("[") {
                guard raw.hasSuffix("]") else { item.fields = nil; continue }
                let list = Self.splitTopLevel(String(raw.dropFirst().dropLast()), separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                if list.contains(where: { $0.hasPrefix("{") || $0.hasPrefix("[") }) { item.fields = nil }
                item.fields?.append((key, .list(list)))
                if key == "proxies" { item.members = list }
            } else {
                if raw.hasPrefix("{") || raw.hasPrefix("&") || raw.hasPrefix("*") { item.fields = nil }
                item.fields?.append((key, .scalar(raw)))
                let lowerKey = key.lowercased()
                if lowerKey == "name" {
                    item.name = Self.unquote(raw)
                    item.nameToken = raw
                } else if lowerKey == "dialer-proxy" || (lowerKey == "connect-via" && item.dialerProxy == nil) {
                    let value = Self.unquote(raw).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty { item.dialerProxy = value }
                }
            }
        }
        return item
    }

    private func parseBlockMapping(_ range: Range<Int>, firstBody: String, fieldIndent: Int) -> ParsedItem {
        var item = ParsedItem(fields: [])
        var pendingListKey: String?
        var pendingList: [String] = []
        func flushList() {
            if let key = pendingListKey {
                item.fields?.append((key, .list(pendingList)))
                if key == "proxies" { item.members = pendingList }
            }
            pendingListKey = nil
            pendingList = []
        }
        func handleField(_ text: String) {
            guard let (key, raw) = Self.keyValue(text) else { item.fields = nil; return }
            if key == "<<" || raw.hasPrefix("&") || raw.hasPrefix("*") || raw == "|" || raw == ">"
                || raw.hasPrefix("|") || raw.hasPrefix(">") {
                item.fields = nil
            }
            if raw.isEmpty {
                pendingListKey = key
                return
            }
            if raw.hasPrefix("[") {
                guard raw.hasSuffix("]") else { item.fields = nil; return }
                let list = Self.splitTopLevel(String(raw.dropFirst().dropLast()), separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                item.fields?.append((key, .list(list)))
                if key == "proxies" { item.members = list }
            } else {
                if raw.hasPrefix("{") { item.fields = nil }
                item.fields?.append((key, .scalar(raw)))
                let lowerKey = key.lowercased()
                if lowerKey == "name" {
                    item.name = Self.unquote(raw)
                    item.nameToken = raw
                } else if lowerKey == "dialer-proxy" || (lowerKey == "connect-via" && item.dialerProxy == nil) {
                    let value = Self.unquote(raw).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty { item.dialerProxy = value }
                }
            }
        }
        if !firstBody.isEmpty { handleField(Self.stripComment(firstBody)) }
        for index in range.dropFirst() {
            let line = lines[index]
            let trimmed = Self.stripComment(line.trimmingCharacters(in: .whitespaces))
            guard !trimmed.isEmpty else { continue }
            let indent = Self.indent(of: line)
            if trimmed.hasPrefix("- ") || trimmed == "-" {
                guard pendingListKey != nil, indent >= fieldIndent else { item.fields = nil; continue }
                let value = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                if value.hasPrefix("{") || value.hasPrefix("[") || value.contains(": ") { item.fields = nil }
                pendingList.append(value)
                continue
            }
            if indent == fieldIndent {
                flushList()
                handleField(trimmed)
            } else {
                // A nested mapping (health-check:, …): readable, not rewritable.
                item.fields = nil
            }
        }
        flushList()
        return item
    }

    /// Clones an existing proxy item in `proxies:` with a new `name` and optional
    /// `dialer-proxy`, preserving nested transport/plugin options.
    func clonedProxyLines(
        from targetName: String,
        newName: String,
        dialerProxy: String?
    ) -> [String]? {
        guard let range = proxyRanges[targetName] else { return nil }
        return rewritingProxyLines(
            in: range,
            newName: newName,
            dialerProxy: dialerProxy,
            itemIndent: proxyItemIndent
        )
    }

    /// Rewrites an existing proxy item with `dialer-proxy` / `connect-via` removed.
    private func strippingDialerProxyLines(for proxyName: String) -> [String]? {
        guard let range = proxyRanges[proxyName] else { return nil }
        return rewritingProxyLines(
            in: range,
            newName: nil,
            dialerProxy: nil,
            itemIndent: nil
        )
    }

    private func rewritingProxyLines(
        in range: Range<Int>,
        newName: String?,
        dialerProxy: String?,
        itemIndent: Int?
    ) -> [String]? {
        let first = lines[range.lowerBound]
        guard let dash = first.firstIndex(of: "-") else { return nil }
        let body = first[first.index(after: dash)...].trimmingCharacters(in: .whitespaces)
        if body.hasPrefix("{") {
            let text = range.map { lines[$0] }.joined(separator: " ")
            guard let open = text.firstIndex(of: "{"),
                  let close = text.lastIndex(of: "}") else { return nil }
            let content = String(text[text.index(after: open)..<close])
            var parts: [String] = []
            for part in Self.splitTopLevel(content, separator: ",") {
                guard let (key, _) = Self.keyValue(part) else {
                    parts.append(part)
                    continue
                }
                let lower = key.lowercased()
                if lower == "name", let newName {
                    parts.append("name: \(Self.quote(newName))")
                } else if lower == "dialer-proxy" || lower == "connect-via" {
                    continue
                } else {
                    parts.append(part)
                }
            }
            if let dialerProxy {
                parts.append("dialer-proxy: \(Self.quote(dialerProxy))")
            }
            let effectiveIndent = itemIndent ?? Self.indent(of: first)
            let pad = String(repeating: " ", count: effectiveIndent)
            return ["\(pad)- {\(parts.joined(separator: ", "))}"]
        }

        let dashColumn = first.distance(from: first.startIndex, to: dash)
        let gap = first[first.index(after: dash)...].prefix(while: { $0 == " " }).count
        var fieldIndent = dashColumn + 1 + gap
        if body.isEmpty {
            let next = range.dropFirst().first {
                !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty
            }
            fieldIndent = next.map { Self.indent(of: lines[$0]) } ?? dashColumn + 2
        }
        let fieldPad = String(repeating: " ", count: fieldIndent)
        var result: [String] = []
        let strippedFirst = Self.stripComment(body)
        if let (key, _) = Self.keyValue(strippedFirst) {
            let lowerFirst = key.lowercased()
            if lowerFirst == "name", let newName {
                let prefix = String(first[...dash]) + String(repeating: " ", count: max(1, gap))
                result.append("\(prefix)name: \(Self.quote(newName))")
            } else if lowerFirst == "dialer-proxy" || lowerFirst == "connect-via" {
                // Skip dialer-proxy on the opening `- ` line; promote the first kept line below.
            } else {
                result.append(first)
            }
        } else {
            result.append(first)
        }
        for index in range.dropFirst() {
            let line = lines[index]
            let trimmed = Self.stripComment(line.trimmingCharacters(in: .whitespaces))
            let indent = Self.indent(of: line)
            if indent == fieldIndent, let (key, _) = Self.keyValue(trimmed) {
                let lower = key.lowercased()
                if lower == "name", let newName {
                    result.append("\(fieldPad)name: \(Self.quote(newName))")
                    continue
                }
                if lower == "dialer-proxy" || lower == "connect-via" {
                    continue
                }
            }
            if result.isEmpty {
                let dashPrefix = String(repeating: " ", count: dashColumn) + "-" + String(repeating: " ", count: max(1, gap))
                result.append(dashPrefix + line.trimmingCharacters(in: .whitespaces))
            } else {
                result.append(line)
            }
        }
        if let dialerProxy {
            result.append("\(fieldPad)dialer-proxy: \(Self.quote(dialerProxy))")
        }
        return result
    }

    /// The document with some groups replaced and custom groups / proxies / hosts / rules added.
    func render(
        replacingGroups: [Int: String],
        insertingGroups: [String],
        insertingProxies: [String] = [],
        insertingHosts: [(domain: String, ip: String)] = [],
        strippingDialerProxies: Set<String> = [],
        insertingRules: [String] = []
    ) -> String {
        let pad = String(repeating: " ", count: groupItemIndent)
        let hostPad = String(repeating: " ", count: hostsItemIndent)
        let rulePad = String(repeating: " ", count: ruleItemIndent)
        let hostLines = insertingHosts.map { entry in
            "\(hostPad)\(Self.quote(entry.domain)): \(Self.quote(entry.ip))"
        }
        let ruleLines = insertingRules.map { "\(rulePad)- \($0)" }
        let overriddenHostLineIndices = Set(
            insertingHosts.compactMap { existingHostLineByDomain[$0.domain] }
        )
        let firstMajorHeader = [proxiesHeader, groupsHeader, rulesHeader].compactMap { $0 }.min()
        var wroteHostsSection = hostsHeader != nil || hostLines.isEmpty
        var wroteRules = ruleLines.isEmpty
        var output: [String] = []
        output.reserveCapacity(
            lines.count + insertingGroups.count + insertingProxies.count + hostLines.count + ruleLines.count + 8
        )
        let lastGroupLowerBound = groups.last?.lineRange.lowerBound
        let lastGroupLastLine = groups.last.map { $0.lineRange.upperBound - 1 }
        let replacedStarts = Dictionary(uniqueKeysWithValues: replacingGroups.map {
            (groups[$0.key].lineRange.lowerBound, (groups[$0.key].lineRange, $0.value))
        })
        var strippedProxyStarts: [Int: (Range<Int>, [String])] = [:]
        for proxyName in strippingDialerProxies {
            if let range = proxyRanges[proxyName],
               let replacement = strippingDialerProxyLines(for: proxyName) {
                strippedProxyStarts[range.lowerBound] = (range, replacement)
            }
        }
        var skipUntil = -1
        for (index, line) in lines.enumerated() {
            if index < skipUntil { continue }
            if overriddenHostLineIndices.contains(index) { continue }
            if !wroteHostsSection, index == firstMajorHeader {
                output.append("hosts:")
                output.append(contentsOf: hostLines)
                wroteHostsSection = true
            }
            if let (range, replacementLines) = strippedProxyStarts[index] {
                output.append(contentsOf: replacementLines)
                skipUntil = range.upperBound
                continue
            }
            if let (range, replacement) = replacedStarts[index] {
                output.append(pad + "- " + replacement)
                if index == lastGroupLowerBound, !insertingGroups.isEmpty {
                    output.append(contentsOf: insertingGroups.map { pad + "- " + $0 })
                }
                skipUntil = range.upperBound
                continue
            }
            if index == groupsHeader, proxiesHeader == nil, !insertingProxies.isEmpty {
                output.append("proxies:")
                output.append(contentsOf: insertingProxies)
            }
            if index == rulesHeader {
                if proxiesHeader == nil, groupsHeader == nil, !insertingProxies.isEmpty {
                    output.append("proxies:")
                    output.append(contentsOf: insertingProxies)
                }
                if groupsHeader == nil, !insertingGroups.isEmpty {
                    output.append("proxy-groups:")
                    output.append(contentsOf: insertingGroups.map { "  - " + $0 })
                }
                if rulesHeaderHasEmptyFlow, !ruleLines.isEmpty {
                    output.append("rules:")
                    output.append(contentsOf: ruleLines)
                    wroteRules = true
                    continue
                }
            }
            if index == hostsHeader, !hostLines.isEmpty {
                output.append("hosts:")
                output.append(contentsOf: hostLines)
                continue
            }
            output.append(line)
            if index == proxiesHeader, !insertingProxies.isEmpty {
                output.append(contentsOf: insertingProxies)
            }
            if index == groupsHeader, groups.isEmpty, !insertingGroups.isEmpty {
                output.append(contentsOf: insertingGroups.map { pad + "- " + $0 })
            }
            if index == lastGroupLastLine, !insertingGroups.isEmpty {
                output.append(contentsOf: insertingGroups.map { pad + "- " + $0 })
            }
            if index == rulesHeader, !wroteRules {
                output.append(contentsOf: ruleLines)
                wroteRules = true
            }
        }
        if !wroteHostsSection {
            if output.last == "" { output.removeLast() }
            output.append("hosts:")
            output.append(contentsOf: hostLines)
            output.append("")
            wroteHostsSection = true
        }
        if groupsHeader == nil, rulesHeader == nil, !insertingGroups.isEmpty {
            if output.last == "" { output.removeLast() }
            if proxiesHeader == nil, !insertingProxies.isEmpty {
                output.append("proxies:")
                output.append(contentsOf: insertingProxies)
            }
            output.append("proxy-groups:")
            output.append(contentsOf: insertingGroups.map { "  - " + $0 })
            output.append("")
        }
        if !wroteRules {
            if output.last == "" { output.removeLast() }
            output.append("rules:")
            output.append(contentsOf: ruleLines)
            output.append("")
        }
        return output.joined(separator: "\n")
    }

    // MARK: Scalars

    static func indent(of line: String) -> Int {
        line.prefix(while: { $0 == " " }).count
    }

    /// A node in a flow sequence: as the profile wrote it when that is
    /// already safe there (quoted, or plain without flow indicators),
    /// otherwise double-quoted.
    static func flowToken(name: String, written: String?) -> String {
        if let written {
            if written.hasPrefix("\""), written.hasSuffix("\""), written.count >= 2 { return written }
            if written.hasPrefix("'"), written.hasSuffix("'"), written.count >= 2 { return written }
            let unsafe = written.contains { ",[]{}#&*!|>%@`\"'".contains($0) }
                || written.contains(": ")
                || written.first.map { "-?:".contains($0) } == true
            if !unsafe, written == name { return written }
        }
        return quote(name)
    }

    /// Double-quoted YAML scalar for any name.
    static func quote(_ value: String) -> String {
        var escaped = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return "\"" + escaped + "\""
    }

    static func unquote(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard value.count >= 2 else { return value }
        if value.first == "'", value.last == "'" {
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        if value.first == "\"", value.last == "\"" {
            var result = ""
            var escaping = false
            for character in value.dropFirst().dropLast() {
                if escaping {
                    switch character {
                    case "n": result.append("\n")
                    case "t": result.append("\t")
                    default: result.append(character)
                    }
                    escaping = false
                } else if character == "\\" {
                    escaping = true
                } else {
                    result.append(character)
                }
            }
            return result
        }
        return value
    }

    /// Removes a ` # comment` outside quotes.
    static func stripComment(_ text: String) -> String {
        var quote: Character?
        var previous: Character = " "
        for index in text.indices {
            let character = text[index]
            if let active = quote {
                if character == active { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "#", previous == " " || previous == "\t" {
                return String(text[..<index]).trimmingCharacters(in: .whitespaces)
            }
            previous = character
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// `key: value` split at the first `:` outside quotes and brackets.
    static func keyValue(_ text: String) -> (String, String)? {
        let parts = splitTopLevel(text, separator: ":", limit: 1)
        guard parts.count == 2 else { return nil }
        let key = unquote(parts[0])
        guard !key.isEmpty else { return nil }
        return (key, stripComment(parts[1]))
    }

    static func splitTopLevel(_ value: String, separator: Character, limit: Int = .max) -> [String] {
        var values: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        var depth = 0
        var splits = 0
        for character in value {
            if escaped {
                escaped = false
                current.append(character)
                continue
            }
            if character == "\\", quote == "\"" {
                escaped = true
                current.append(character)
                continue
            }
            if let active = quote {
                if character == active { quote = nil }
                current.append(character)
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
            } else if character == "[" || character == "{" {
                depth += 1
            } else if character == "]" || character == "}" {
                depth = max(0, depth - 1)
            } else if character == separator, depth == 0, splits < limit {
                // In a flow mapping a key's colon is followed by a space;
                // `2001:db8::1` stays one value.
                if separator != ":" || current.isEmpty == false {
                    values.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                    splits += 1
                    continue
                }
            }
            current.append(character)
        }
        values.append(current.trimmingCharacters(in: .whitespaces))
        return values
    }
}
