import Foundation
import AetherRouteKit

extension TunnelManager {

    @discardableResult
    func addCustomRule(_ rule: CustomRule) async -> Bool {
        guard !isTransitioning, !isUpdatingCustomRules else {
            customRuleMessage = AppLocalization.string("Wait for the current rule or connection change to finish.")
            customRuleMessageIsError = true
            return false
        }
        isUpdatingCustomRules = true
        defer { isUpdatingCustomRules = false }
        do {
            customRules = try CustomRuleStore.applicationGroup().add(rule)
            let isLive = (state == .connected)
            await refreshActiveProfileSummaryOffMainActor()
            if isLive {
                let reloaded = await reloadCustomRulesLive()
                if reloaded {
                    customRuleMessage = AppLocalization.string("Custom rule added and active at top priority")
                    customRuleMessageIsError = false
                }
            } else {
                customRuleMessage = AppLocalization.string("Custom rule saved and will apply on next connection.")
                customRuleMessageIsError = false
            }
            return true
        } catch {
            customRuleMessage = localizedCustomRuleError(error)
            customRuleMessageIsError = true
            return false
        }
    }

    @discardableResult
    func updateCustomRule(_ rule: CustomRule) async -> Bool {
        guard !isTransitioning, !isUpdatingCustomRules else {
            customRuleMessage = AppLocalization.string("Wait for the current rule or connection change to finish.")
            customRuleMessageIsError = true
            return false
        }
        isUpdatingCustomRules = true
        defer { isUpdatingCustomRules = false }
        do {
            customRules = try CustomRuleStore.applicationGroup().update(rule)
            customRuleMessage = AppLocalization.string("Custom rule updated")
            customRuleMessageIsError = false
            await refreshActiveProfileSummaryOffMainActor()
            await reloadCustomRulesLive()
            return true
        } catch {
            customRuleMessage = localizedCustomRuleError(error)
            customRuleMessageIsError = true
            return false
        }
    }

    @discardableResult
    func deleteCustomRule(id: UUID) async -> Bool {
        guard !isTransitioning, !isUpdatingCustomRules else {
            customRuleMessage = AppLocalization.string("Wait for the current rule or connection change to finish.")
            customRuleMessageIsError = true
            return false
        }
        isUpdatingCustomRules = true
        defer { isUpdatingCustomRules = false }
        do {
            customRules = try CustomRuleStore.applicationGroup().delete(id: id)
            customRuleMessage = AppLocalization.string("Custom rule deleted")
            customRuleMessageIsError = false
            await refreshActiveProfileSummaryOffMainActor()
            await reloadCustomRulesLive()
            return true
        } catch {
            customRuleMessage = localizedCustomRuleError(error)
            customRuleMessageIsError = true
            return false
        }
    }

    @discardableResult
    func toggleCustomRule(id: UUID) async -> Bool {
        guard !isTransitioning, !isUpdatingCustomRules else {
            customRuleMessage = AppLocalization.string("Wait for the current rule or connection change to finish.")
            customRuleMessageIsError = true
            return false
        }
        isUpdatingCustomRules = true
        defer { isUpdatingCustomRules = false }
        do {
            customRules = try CustomRuleStore.applicationGroup().toggle(id: id)
            customRuleMessage = nil
            customRuleMessageIsError = false
            await refreshActiveProfileSummaryOffMainActor()
            await reloadCustomRulesLive()
            return true
        } catch {
            customRuleMessage = localizedCustomRuleError(error)
            customRuleMessageIsError = true
            return false
        }
    }

    @discardableResult
    func moveCustomRule(id: UUID, direction: CustomRuleMoveDirection) async -> Bool {
        guard !isTransitioning, !isUpdatingCustomRules else {
            customRuleMessage = AppLocalization.string("Wait for the current rule or connection change to finish.")
            customRuleMessageIsError = true
            return false
        }
        isUpdatingCustomRules = true
        defer { isUpdatingCustomRules = false }
        do {
            // The Rules page lists destination rules only; move among those.
            customRules = try CustomRuleStore.applicationGroup().move(
                id: id,
                direction: direction,
                within: { $0.kind != .application }
            )
            customRuleMessage = nil
            customRuleMessageIsError = false
            await refreshActiveProfileSummaryOffMainActor()
            await reloadCustomRulesLive()
            return true
        } catch {
            customRuleMessage = localizedCustomRuleError(error)
            customRuleMessageIsError = true
            return false
        }
    }

    @discardableResult
    func importCustomRulesBatch(_ rules: [CustomRule]) async -> Bool {
        guard ensurePrivacyConsent() else { return false }
        guard !isTransitioning, !isUpdatingCustomRules else {
            customRuleMessage = AppLocalization.string("Wait for the current rule or connection change to finish.")
            customRuleMessageIsError = true
            return false
        }
        isUpdatingCustomRules = true
        defer { isUpdatingCustomRules = false }
        do {
            customRules = try CustomRuleStore.applicationGroup().importBatch(rules)
            let isLive = (state == .connected)
            await refreshActiveProfileSummaryOffMainActor()
            if isLive {
                let reloaded = await reloadCustomRulesLive()
                if reloaded {
                    customRuleMessage = AppLocalization.format(
                        "Imported %lld custom rules at top priority",
                        Int64(rules.count)
                    )
                    customRuleMessageIsError = false
                }
            } else {
                customRuleMessage = AppLocalization.format(
                    "Saved %lld custom rules. They will apply on the next connection.",
                    Int64(rules.count)
                )
                customRuleMessageIsError = false
            }
            return true
        } catch let CustomRuleStoreError.tooManyRules(total) {
            customRuleMessage = AppLocalization.format(
                "These rules would bring the total to %lld, above the limit of %lld. Nothing was imported; remove some rules or paste fewer.",
                Int64(total),
                Int64(CustomRuleCollection.maximumRules)
            )
            customRuleMessageIsError = true
            return false
        } catch {
            customRuleMessage = localizedCustomRuleError(error)
            customRuleMessageIsError = true
            return false
        }
    }

    /// Finds an existing destination custom rule matching `(kind, value)`.
    func destinationRule(
        kind: CustomRuleKind,
        value: String
    ) -> CustomRule? {
        guard !customRules.isEmpty else { return nil }
        let normalized = CustomRule(kind: kind, value: value, target: .direct).value
        return customRules.first { rule in
            rule.kind == kind && rule.value == normalized
        }
    }

    /// Creates or updates a destination custom rule for `(kind, value)` to route to `target`.
    @discardableResult
    func setDestinationRule(
        kind: CustomRuleKind,
        value: String,
        noResolve: Bool,
        target: CustomRuleTarget
    ) async -> Bool {
        let existing = destinationRule(kind: kind, value: value)
        let rule = CustomRule(
            id: existing?.id ?? UUID(),
            kind: kind,
            value: value,
            target: target,
            noResolve: noResolve,
            isEnabled: true,
            comment: existing?.comment
        )
        return existing == nil
            ? await addCustomRule(rule)
            : await updateCustomRule(rule)
    }

    /// The application rule that names this app, if any.
    func applicationRule(
        bundleIdentifier: String?,
        bundlePath: String?
    ) -> CustomRule? {
        guard !customRules.isEmpty else { return nil }
        return customRules.first { rule in
            guard let match = rule.applicationMatch else { return false }
            if let bundlePath, let path = match.bundlePath {
                return path == bundlePath
            }
            return bundleIdentifier != nil && match.bundleIdentifier == bundleIdentifier
        }
    }

    /// Sends one app's connections to `target`, replacing the app's existing
    /// rule so the list never holds two rules for the same app.
    @discardableResult
    func setApplicationRule(
        bundleIdentifier: String?,
        bundlePath: String?,
        displayName: String,
        target: CustomRuleTarget
    ) async -> Bool {
        let existing = applicationRule(
            bundleIdentifier: bundleIdentifier,
            bundlePath: bundlePath
        )
        guard let rule = CustomRule.application(
            id: existing?.id ?? UUID(),
            bundleIdentifier: bundleIdentifier,
            bundlePath: bundlePath,
            displayName: displayName,
            target: target
        ) else {
            customRuleMessage = AppLocalization.string("This app cannot be used in a rule.")
            customRuleMessageIsError = true
            return false
        }
        return existing == nil
            ? await addCustomRule(rule)
            : await updateCustomRule(rule)
    }

    func localizedCustomRuleValidationIssue(_ issue: CustomRuleValidationIssue) -> String {
        switch issue {
        case .emptyCriteria:
            return AppLocalization.string("Criteria cannot be empty")
        case .applicationRuleInvalid:
            return AppLocalization.string("Application rules require a valid signing identifier or .app bundle path")
        case .domainLength:
            return AppLocalization.string("Domain length must be between 1 and 253 characters")
        case .domainForbiddenCharacters:
            return AppLocalization.string("Domain cannot contain spaces, slashes, or colons")
        case .domainInvalidFormat:
            return AppLocalization.string("Invalid domain format")
        case .domainLabelLength:
            return AppLocalization.string("Each domain label must be 1 to 63 characters long")
        case .domainLabelHyphenBoundary:
            return AppLocalization.string("Domain labels cannot begin or end with '-'")
        case .domainLabelInvalidCharacters:
            return AppLocalization.string("Domain labels may only contain ASCII letters, digits, and '-'")
        case .keywordForbiddenCharacters:
            return AppLocalization.string("Keyword cannot contain spaces, slashes, or commas")
        case .ipv4CIDRMissingPrefix:
            return AppLocalization.string("IPv4 CIDR must include a slash prefix, e.g. 100.64.0.0/10")
        case .ipv4CIDRInvalidPrefix:
            return AppLocalization.string("IPv4 CIDR prefix must be between 1 and 32")
        case let .ipv4InvalidAddress(ip):
            return AppLocalization.format("Invalid IPv4 address: %@", ip)
        case let .ipv4CIDRHostBitsNonZero(canonical, prefix):
            return AppLocalization.format("CIDR host bits must be zero; use %@/%lld", canonical, Int64(prefix))
        case .ipv6CIDRMissingPrefix:
            return AppLocalization.string("IPv6 CIDR must include a slash prefix, e.g. fd7a:115c:a1e0::/48")
        case .ipv6CIDRInvalidPrefix:
            return AppLocalization.string("IPv6 CIDR prefix must be between 1 and 128")
        case let .ipv6InvalidAddress(ip):
            return AppLocalization.format("Invalid IPv6 address: %@", ip)
        case .geoIPInvalid:
            return AppLocalization.string("GEOIP must be a 2-letter country code, e.g. CN, US, HK")
        case .geoSiteLength:
            return AppLocalization.string("GEOSITE category length must be 1 to 64 characters, e.g. cn, apple, openai")
        case .geoSiteInvalidStart:
            return AppLocalization.string("GEOSITE category must start with an ASCII letter or digit")
        case .geoSiteInvalidCharacters:
            return AppLocalization.string("GEOSITE category may only contain ASCII letters, digits, '-', '_', '!', '@', and '.'")
        case .dstPortInvalid:
            return AppLocalization.string("DST-PORT must be a port number between 1 and 65535, e.g. 443 or 80")
        case .domainWildcardLength:
            return AppLocalization.string("DOMAIN-WILDCARD length must be between 1 and 253 characters")
        case .domainWildcardForbiddenCharacters:
            return AppLocalization.string("DOMAIN-WILDCARD cannot contain spaces, slashes, colons, or commas")
        case .domainWildcardInvalidCharacters:
            return AppLocalization.string("DOMAIN-WILDCARD may only contain ASCII domain characters and '*', '?', '+' wildcards")
        case .domainRegexLength:
            return AppLocalization.string("DOMAIN-REGEX length must be between 1 and 512 characters")
        case .domainRegexNewline:
            return AppLocalization.string("DOMAIN-REGEX cannot contain newlines")
        case let .domainRegexInvalidSyntax(detail):
            return AppLocalization.format("Invalid DOMAIN-REGEX syntax: %@", detail)
        case .ipASNInvalid:
            return AppLocalization.string("IP-ASN must be a non-zero ASN such as 13335 or AS13335")
        case .networkInvalid:
            return AppLocalization.string("NETWORK supports only TCP or UDP")
        case .processNameLength:
            return AppLocalization.string("PROCESS-NAME length must be between 1 and 256 bytes")
        case .processNameForbiddenCharacters:
            return AppLocalization.string("PROCESS-NAME cannot contain '/', commas, or newlines")
        case .processPathFormat:
            return AppLocalization.string("PROCESS-PATH must be an absolute path starting with '/', e.g. /usr/bin/curl")
        case .processPathForbiddenCharacters:
            return AppLocalization.string("PROCESS-PATH cannot contain commas, NUL characters, or newlines")
        case .processPathMissingExecutable:
            return AppLocalization.string("PROCESS-PATH must include an executable filename")
        case .compositeANDFormat:
            return AppLocalization.string("AND composite rules must follow ((NETWORK,UDP),(DST-PORT,443))")
        case .compositeANDUnbalancedParentheses:
            return AppLocalization.string("AND composite rule has unbalanced parentheses")
        }
    }

    func localizedCustomRuleValidationReason(_ reason: String) -> String {
        switch reason {
        case "Criteria cannot be empty":
            return localizedCustomRuleValidationIssue(.emptyCriteria)
        case "Application rules require a valid signing identifier or .app bundle path":
            return localizedCustomRuleValidationIssue(.applicationRuleInvalid)
        case "Domain length must be between 1 and 253 characters":
            return localizedCustomRuleValidationIssue(.domainLength)
        case "Domain cannot contain spaces, slashes, or colons":
            return localizedCustomRuleValidationIssue(.domainForbiddenCharacters)
        case "Invalid domain format":
            return localizedCustomRuleValidationIssue(.domainInvalidFormat)
        case "Each domain label must be 1 to 63 characters long":
            return localizedCustomRuleValidationIssue(.domainLabelLength)
        case "Domain labels cannot begin or end with '-'":
            return localizedCustomRuleValidationIssue(.domainLabelHyphenBoundary)
        case "Domain labels may only contain ASCII letters, digits, and '-'":
            return localizedCustomRuleValidationIssue(.domainLabelInvalidCharacters)
        case "Keyword cannot contain spaces, slashes, or commas":
            return localizedCustomRuleValidationIssue(.keywordForbiddenCharacters)
        case "IPv4 CIDR must include a slash prefix, e.g. 100.64.0.0/10":
            return localizedCustomRuleValidationIssue(.ipv4CIDRMissingPrefix)
        case "IPv4 CIDR prefix must be between 1 and 32":
            return localizedCustomRuleValidationIssue(.ipv4CIDRInvalidPrefix)
        case "IPv6 CIDR must include a slash prefix, e.g. fd7a:115c:a1e0::/48":
            return localizedCustomRuleValidationIssue(.ipv6CIDRMissingPrefix)
        case "IPv6 CIDR prefix must be between 1 and 128":
            return localizedCustomRuleValidationIssue(.ipv6CIDRInvalidPrefix)
        case "GEOIP must be a 2-letter country code, e.g. CN, US, HK":
            return localizedCustomRuleValidationIssue(.geoIPInvalid)
        case "GEOSITE category length must be 1 to 64 characters, e.g. cn, apple, openai":
            return localizedCustomRuleValidationIssue(.geoSiteLength)
        case "GEOSITE category must start with an ASCII letter or digit":
            return localizedCustomRuleValidationIssue(.geoSiteInvalidStart)
        case "GEOSITE category may only contain ASCII letters, digits, '-', '_', '!', '@', and '.'":
            return localizedCustomRuleValidationIssue(.geoSiteInvalidCharacters)
        case "DST-PORT must be a port number between 1 and 65535, e.g. 443 or 80":
            return localizedCustomRuleValidationIssue(.dstPortInvalid)
        case "DOMAIN-WILDCARD length must be between 1 and 253 characters":
            return localizedCustomRuleValidationIssue(.domainWildcardLength)
        case "DOMAIN-WILDCARD cannot contain spaces, slashes, colons, or commas":
            return localizedCustomRuleValidationIssue(.domainWildcardForbiddenCharacters)
        case "DOMAIN-WILDCARD may only contain ASCII domain characters and '*', '?', '+' wildcards":
            return localizedCustomRuleValidationIssue(.domainWildcardInvalidCharacters)
        case "DOMAIN-REGEX length must be between 1 and 512 characters":
            return localizedCustomRuleValidationIssue(.domainRegexLength)
        case "DOMAIN-REGEX cannot contain newlines":
            return localizedCustomRuleValidationIssue(.domainRegexNewline)
        case "IP-ASN must be a non-zero ASN such as 13335 or AS13335":
            return localizedCustomRuleValidationIssue(.ipASNInvalid)
        case "NETWORK supports only TCP or UDP":
            return localizedCustomRuleValidationIssue(.networkInvalid)
        case "PROCESS-NAME length must be between 1 and 256 bytes":
            return localizedCustomRuleValidationIssue(.processNameLength)
        case "PROCESS-NAME cannot contain '/', commas, or newlines":
            return localizedCustomRuleValidationIssue(.processNameForbiddenCharacters)
        case "PROCESS-PATH must be an absolute path starting with '/', e.g. /usr/bin/curl":
            return localizedCustomRuleValidationIssue(.processPathFormat)
        case "PROCESS-PATH cannot contain commas, NUL characters, or newlines":
            return localizedCustomRuleValidationIssue(.processPathForbiddenCharacters)
        case "PROCESS-PATH must include an executable filename":
            return localizedCustomRuleValidationIssue(.processPathMissingExecutable)
        case "AND composite rules must follow ((NETWORK,UDP),(DST-PORT,443))":
            return localizedCustomRuleValidationIssue(.compositeANDFormat)
        case "AND composite rule has unbalanced parentheses":
            return localizedCustomRuleValidationIssue(.compositeANDUnbalancedParentheses)
        default:
            if reason.hasPrefix("Invalid IPv4 address: ") {
                let ip = String(reason.dropFirst("Invalid IPv4 address: ".count))
                return localizedCustomRuleValidationIssue(.ipv4InvalidAddress(ip))
            }
            if reason.hasPrefix("CIDR host bits must be zero; use ") {
                let tail = String(reason.dropFirst("CIDR host bits must be zero; use ".count))
                let parts = tail.split(separator: "/", maxSplits: 1)
                if parts.count == 2, let prefix = Int(parts[1]) {
                    return localizedCustomRuleValidationIssue(.ipv4CIDRHostBitsNonZero(String(parts[0]), prefix))
                }
            }
            if reason.hasPrefix("Invalid IPv6 address: ") {
                let ip = String(reason.dropFirst("Invalid IPv6 address: ".count))
                return localizedCustomRuleValidationIssue(.ipv6InvalidAddress(ip))
            }
            if reason.hasPrefix("Invalid DOMAIN-REGEX syntax: ") {
                let detail = String(reason.dropFirst("Invalid DOMAIN-REGEX syntax: ".count))
                return localizedCustomRuleValidationIssue(.domainRegexInvalidSyntax(detail))
            }
            return reason
        }
    }

    func localizedCustomRuleError(_ error: Error) -> String {
        if let storeError = error as? CustomRuleStoreError {
            switch storeError {
            case let .tooManyRules(count):
                return AppLocalization.format(
                    "Custom rules would total %lld, above the limit of %lld. Remove some rules or import fewer.",
                    Int64(count),
                    Int64(CustomRuleCollection.maximumRules)
                )
            case let .ruleNotFound(id):
                return AppLocalization.format("Custom rule with ID %@ not found", id.uuidString)
            }
        }
        if let parseError = error as? CustomRuleParseError {
            switch parseError {
            case .insufficientComponents:
                return AppLocalization.string("Rule requires at least 3 parts (e.g. DOMAIN-SUFFIX,example.com,DIRECT)")
            case let .unsupportedKind(kind):
                return AppLocalization.format(
                    "Unsupported rule kind: %@. Supported: DOMAIN, DOMAIN-SUFFIX, DOMAIN-KEYWORD, DOMAIN-WILDCARD, DOMAIN-REGEX, IP-CIDR, IP-CIDR6, GEOIP, GEOSITE, IP-ASN, DST-PORT, NETWORK, PROCESS-NAME, PROCESS-PATH, AND",
                    kind
                )
            case .emptyValue:
                return AppLocalization.string("Rule criteria / destination cannot be empty")
            case let .validationFailed(reason):
                return localizedCustomRuleValidationReason(reason)
            }
        }
        return localizedConnectionError(error).localizedDescription
    }

    @discardableResult
    func reloadCustomRulesLive(reloadOutbounds: Bool = false) async -> Bool {
        guard !isUIReviewMode, state == .connected else { return true }
        do {
            let currentRoutingMode = sessionRoutingMode ?? routingMode
            let preparedReload = try await prepareReloadProfilePayload(
                requestedMode: currentRoutingMode
            )
            let client = makeProxySelectionProviderClient()
            Self.runtimeLogger.info(
                "stage=customRules liveReload sending payload bytes=\(preparedReload.payloadData.count, privacy: .public) resources=\(preparedReload.routingResources.count, privacy: .public) reloadOutbounds=\(reloadOutbounds, privacy: .public)"
            )
            try await reloadActiveProfileStagingResources(
                preparedReload,
                via: client,
                strategy: reloadOutbounds ? .hotReloadFull : .hotReloadRulesOnly
            )
            await syncGlobalSelector(client: client)
            Self.runtimeLogger.info("stage=customRules liveReload succeeded")
            return true
        } catch {
            Self.runtimeLogger.error(
                "stage=customRules liveReload failed error=\(String(reflecting: error), privacy: .public)"
            )
            customRuleMessage = localizedCustomRuleError(error)
            customRuleMessageIsError = true
            return false
        }
    }

    private nonisolated static func computeProfileSummary(
        rawProfileYAML: String,
        effectiveRules: [CustomRule],
        remoteRules: [String],
        enableDomesticDirect: Bool
    ) -> ProfileConfigurationSummary {
        let profileYAML = DomesticRoutingOptimizer.optimizedProfile(
            for: rawProfileYAML,
            customRules: effectiveRules,
            remoteRules: remoteRules,
            enableDomesticDirect: enableDomesticDirect
        )
        return ProfileConfigurationInspector.inspect(
            yaml: profileYAML,
            customRules: effectiveRules,
            remoteRules: remoteRules
        )
    }

    func refreshActiveProfileSummary() {
        activeProfileSummaryGeneration &+= 1
        guard let activeProfile else { return }
        activeProfileSummary = Self.computeProfileSummary(
            rawProfileYAML: effectiveProfileYAML(for: activeProfile),
            effectiveRules: effectiveRuntimeCustomRules,
            remoteRules: compiledRemoteRulesCache,
            enableDomesticDirect: isDomesticOptimizationEnabled
        )
        refreshRoutingResourceStatuses()
    }

    func refreshActiveProfileSummaryOffMainActor() async {
        activeProfileSummaryGeneration &+= 1
        let generation = activeProfileSummaryGeneration
        guard let activeProfile else { return }
        let rawProfileYAML = effectiveProfileYAML(for: activeProfile)
        let effectiveRules = effectiveRuntimeCustomRules
        let remoteRules = compiledRemoteRulesCache
        let enableDomesticDirect = isDomesticOptimizationEnabled
        let inspected = await Task.detached(priority: .userInitiated) {
            Self.computeProfileSummary(
                rawProfileYAML: rawProfileYAML,
                effectiveRules: effectiveRules,
                remoteRules: remoteRules,
                enableDomesticDirect: enableDomesticDirect
            )
        }.value
        guard generation == activeProfileSummaryGeneration else { return }
        activeProfileSummary = inspected
        refreshRoutingResourceStatuses()
    }
}
