import Foundation

/// Runtime platform synthesis for transparent domestic network acceleration and
/// lossless proxy routing.
///
/// Third-party subscription profiles often end with `MATCH,PROXY` and lack rules
/// for Apple services, domestic CDNs, and domestic update endpoints. In addition,
/// fallback resolvers querying overseas Anycast servers often resolve domestic
/// domains to overseas endpoints or assign fake IPs that fail `GEOIP,CN`.
///
/// `DomesticRoutingOptimizer` transforms the profile YAML in memory at launch:
/// 1. Configures `dns:` with `enhanced-mode: fake-ip`, domestic nameservers,
///    and directed `nameserver-policy` mappings.
/// 2. Injects domestic, Apple, Microsoft update, NTP, and captive portal domains into `fake-ip-filter`.
/// 3. Injects high-priority `DIRECT` rules for LAN CIDRs, Apple CDN/update services,
///    Microsoft updates, domestic CDNs/mirrors, and `GEOSITE,apple`/`GEOSITE,cn`.
/// 4. Injects `GEOIP,CN,DIRECT` before the final `MATCH` rule.
/// 5. Strictly preserves all existing proxies, proxy-groups, and user selections.
/// 6. Operates losslessly: disk storage remains 100% untouched.
public enum DomesticRoutingOptimizer {

    public static let userDefaultsKey = "AetherRoute.DomesticOptimizationEnabled"

    public static var isEnabled: Bool {
        if let standardValue = UserDefaults.standard.object(forKey: userDefaultsKey) as? Bool {
            return standardValue
        }
        return true
    }

    public static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: userDefaultsKey)
    }

    // MARK: - Predefined Rule Lists

    /// Mandatory loopback protection rules injected at the very top of `rules:`
    /// (ahead of `AETHER-APP` / `PROCESS-NAME` and custom destination rules) so
    /// local loopback traffic (`127.0.0.0/8`, `::1`, `localhost`, `*.localhost`)
    /// is never sent to a remote proxy server even when an application rule
    /// routes a whole desktop client through a proxy group.
    public static let loopbackProtectionRules: [String] = [
        "DOMAIN,localhost,DIRECT",
        "DOMAIN-SUFFIX,localhost,DIRECT",
        "IP-CIDR,127.0.0.0/8,DIRECT,no-resolve",
        "IP-CIDR6,::1/128,DIRECT,no-resolve",
    ]

    public static let highPriorityBypassRules: [String] = [
        "DOMAIN,localhost,DIRECT",
        "DOMAIN-SUFFIX,localhost,DIRECT",
        "IP-CIDR,127.0.0.0/8,DIRECT,no-resolve",
        "IP-CIDR,10.0.0.0/8,DIRECT,no-resolve",
        "IP-CIDR,172.16.0.0/12,DIRECT,no-resolve",
        "IP-CIDR,192.168.0.0/16,DIRECT,no-resolve",
        "IP-CIDR,100.64.0.0/10,DIRECT,no-resolve",
        "IP-CIDR6,::1/128,DIRECT,no-resolve",
        "IP-CIDR6,fc00::/7,DIRECT,no-resolve",
        "IP-CIDR6,fe80::/10,DIRECT,no-resolve",
        // Tailscale & P2P / VPN Control Plane
        "DOMAIN-SUFFIX,tailscale.com,DIRECT",
        "DOMAIN-SUFFIX,ts.net,DIRECT",
        "DOMAIN-KEYWORD,tailscale,DIRECT",
        "DOMAIN-KEYWORD,headscale,DIRECT",
        "DOMAIN-SUFFIX,baizhiedu.xin,DIRECT",
        "IP-CIDR,82.157.10.147/32,DIRECT,no-resolve",
        // Apple update & software delivery endpoints (high-bandwidth CDNs)
        "DOMAIN-SUFFIX,swcdn.apple.com,DIRECT",
        "DOMAIN-SUFFIX,updates.cdn-apple.com,DIRECT",
        "DOMAIN-SUFFIX,mensa.cdn-apple.com,DIRECT",
        "DOMAIN-SUFFIX,osxapps.itunes.apple.com,DIRECT",
        "DOMAIN-SUFFIX,oscdn.apple.com,DIRECT",
        "DOMAIN-SUFFIX,download.developer.apple.com,DIRECT",
        "DOMAIN-SUFFIX,aaplimg.com,DIRECT",
        "DOMAIN-SUFFIX,cdn-apple.com,DIRECT",
        "DOMAIN-SUFFIX,mzstatic.com,DIRECT",
        "DOMAIN-SUFFIX,apple.com,DIRECT",
        "DOMAIN-SUFFIX,icloud.com,DIRECT",
        "DOMAIN-SUFFIX,icloud-content.com,DIRECT",
        "DOMAIN-SUFFIX,me.com,DIRECT",
        "GEOSITE,apple,DIRECT",
        // Microsoft system updates
        "DOMAIN-SUFFIX,windowsupdate.com,DIRECT",
        "DOMAIN-SUFFIX,delivery.mp.microsoft.com,DIRECT",
        "DOMAIN-SUFFIX,update.microsoft.com,DIRECT",
        // Major domestic CDNs, cloud storage, and university mirrors
        "DOMAIN-SUFFIX,alicdn.com,DIRECT",
        "DOMAIN-SUFFIX,aliyun.com,DIRECT",
        "DOMAIN-SUFFIX,alipay.com,DIRECT",
        "DOMAIN-SUFFIX,taobao.com,DIRECT",
        "DOMAIN-SUFFIX,tmall.com,DIRECT",
        "DOMAIN-SUFFIX,qcloud.com,DIRECT",
        "DOMAIN-SUFFIX,myqcloud.com,DIRECT",
        "DOMAIN-SUFFIX,tencent.com,DIRECT",
        "DOMAIN-SUFFIX,qq.com,DIRECT",
        "DOMAIN-SUFFIX,wechat.com,DIRECT",
        "DOMAIN-SUFFIX,weixin.com,DIRECT",
        "DOMAIN-SUFFIX,weixinbridge.com,DIRECT",
        "DOMAIN-SUFFIX,servicewechat.com,DIRECT",
        "DOMAIN-SUFFIX,tenpay.com,DIRECT",
        "DOMAIN-SUFFIX,baidu.com,DIRECT",
        "DOMAIN-SUFFIX,bdimg.com,DIRECT",
        "DOMAIN-SUFFIX,baidupcs.com,DIRECT",
        "DOMAIN-SUFFIX,bilibili.com,DIRECT",
        "DOMAIN-SUFFIX,bilivideo.com,DIRECT",
        "DOMAIN-SUFFIX,hdslb.com,DIRECT",
        "DOMAIN-SUFFIX,douyin.com,DIRECT",
        "DOMAIN-SUFFIX,douyinpic.com,DIRECT",
        "DOMAIN-SUFFIX,douyinstatic.com,DIRECT",
        "DOMAIN-SUFFIX,douyincdn.com,DIRECT",
        "DOMAIN-SUFFIX,163.com,DIRECT",
        "DOMAIN-SUFFIX,126.net,DIRECT",
        "DOMAIN-SUFFIX,netease.com,DIRECT",
        "DOMAIN-SUFFIX,jd.com,DIRECT",
        "DOMAIN-SUFFIX,weibo.com,DIRECT",
        "DOMAIN-SUFFIX,zhihu.com,DIRECT",
        "DOMAIN-SUFFIX,zhimg.com,DIRECT",
        "DOMAIN-SUFFIX,tsinghua.edu.cn,DIRECT",
        "DOMAIN-SUFFIX,ustc.edu.cn,DIRECT",
        "DOMAIN-SUFFIX,sjtug.org,DIRECT",
        "DOMAIN-SUFFIX,bfsu.edu.cn,DIRECT",
        "GEOSITE,cn,DIRECT",
    ]

    public static let fallbackDirectRule = "GEOIP,CN,DIRECT"

    public static let fakeIPFilterDomains: [String] = [
        "+.lan",
        "*.lan",
        "+.localdomain",
        "*.localdomain",
        "*.example",
        "*.invalid",
        "+.localhost",
        "*.localhost",
        "*.test",
        "+.local",
        "*.local",
        "*.home.arpa",
        "*.tailscale.com",
        "*.ts.net",
        "*headscale*",
        "*.baizhiedu.xin",
        "captive.apple.com",
        "*.captive.apple.com",
        "time.*.com",
        "time.*.apple.com",
        "time1.apple.com",
        "time2.apple.com",
        "time3.apple.com",
        "time4.apple.com",
        "time5.apple.com",
        "time6.apple.com",
        "time7.apple.com",
        "time.asia.apple.com",
        "*.push.apple.com",
        "*.push-apple.com.akadns.net",
        "localhost.ptlogin2.qq.com",
        "*.apple.com",
        "*.cdn-apple.com",
        "*.aaplimg.com",
        "*.mzstatic.com",
        "*.apple-cloudkit.com",
        "*.apple-livephotoskit.com",
        "*.apple-mapkit.com",
        "*.appstore.com",
        "*.digicert.com",
        "*.icloud.com",
        "*.icloud-content.com",
        "*.me.com",
        "swcdn.apple.com",
        "updates.cdn-apple.com",
        "mensa.cdn-apple.com",
        "osxapps.itunes.apple.com",
        "oscdn.apple.com",
        "download.developer.apple.com",
        "*.windowsupdate.com",
        "*.delivery.mp.microsoft.com",
        "*.update.microsoft.com",
        "*.download.windowsupdate.com",
        "*.alicdn.com",
        "*.aliyun.com",
        "*.aliyuncs.com",
        "*.alipay.com",
        "*.alipayobjects.com",
        "*.taobao.com",
        "*.tmall.com",
        "*.qq.com",
        "*.qcloud.com",
        "*.myqcloud.com",
        "*.tencent.com",
        "*.wechat.com",
        "*.weixin.com",
        "*.weixinbridge.com",
        "*.servicewechat.com",
        "*.tenpay.com",
        "*.baidu.com",
        "*.bdimg.com",
        "*.baidupcs.com",
        "*.bilibili.com",
        "*.bilivideo.com",
        "*.hdslb.com",
        "*.douyin.com",
        "*.douyinpic.com",
        "*.douyinstatic.com",
        "*.douyincdn.com",
        "*.zijieapi.com",
        "*.bytegoofy.com",
        "*.volces.com",
        "*.163.com",
        "*.126.net",
        "*.netease.com",
        "*.jd.com",
        "*.360buyimg.com",
        "*.sina.com.cn",
        "*.weibo.com",
        "*.zhihu.com",
        "*.zhimg.com",
        "*.sohu.com",
        "*.kuaishou.com",
        "*.yximgs.com",
        "*.meituan.com",
        "*.dianping.com",
        "*.ele.me",
        "*.xiaomi.com",
        "*.mi.com",
        "*.huawei.com",
        "*.vmall.com",
        "*.tsinghua.edu.cn",
        "*.ustc.edu.cn",
        "*.sjtug.org",
        "*.bfsu.edu.cn",
    ]

    public static let domesticNameservers: [String] = [
        "223.5.5.5",
        "119.29.29.29",
    ]

    public static let domesticNameserverPolicies: [(String, String)] = [
        ("'+.apple.com'", "223.5.5.5"),
        ("'+.cdn-apple.com'", "223.5.5.5"),
        ("'+.aaplimg.com'", "223.5.5.5"),
        ("'+.mzstatic.com'", "223.5.5.5"),
        ("'+.windowsupdate.com'", "223.5.5.5"),
        ("'+.alicdn.com'", "223.5.5.5"),
        ("'+.qq.com'", "119.29.29.29"),
        ("'+.weixin.com'", "119.29.29.29"),
        ("'+.wechat.com'", "119.29.29.29"),
        ("'+.tencent.com'", "119.29.29.29"),
        ("'+.qcloud.com'", "119.29.29.29"),
        ("'+.myqcloud.com'", "119.29.29.29"),
        ("'+.bdimg.com'", "119.29.29.29"),
        ("'+.bilivideo.com'", "119.29.29.29"),
        ("'+.tsinghua.edu.cn'", "223.5.5.5"),
        ("'+.ustc.edu.cn'", "223.5.5.5"),
    ]

    // MARK: - Optimization API

    /// Optimizes the provided raw YAML configuration for domestic download speed and
    /// Apple services acceleration while preserving proxy routing for foreign domains,
    /// with mandatory loopback protection rules injected at priority #1 and user
    /// custom rules injected immediately after.
    public static func optimizedProfile(
        for yaml: String,
        customRules: [CustomRule] = [],
        remoteRules: [String] = [],
        enableDomesticDirect: Bool = true
    ) -> String {
        guard !yaml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return yaml }
        let lines = ProfileRuntimeYAML.canonicalize(yaml).components(separatedBy: "\n")
        guard !lines.isEmpty else { return yaml }

        let sections = parseTopLevelSections(from: lines)

        var resultLines: [String] = []

        let optimizedDNSLines: [String]? = enableDomesticDirect
            ? optimizeDNSSection(sections["dns"], customRules: customRules)
            : sections["dns"]
        var expandedOrDroppedProviders = Set<String>()
        let parsedRuleProviders = parseRuleProvidersSection(sections["rule-providers"])
        let optimizedRuleLines = optimizeRulesSection(
            sections["rules"],
            customRules: customRules,
            remoteRules: remoteRules,
            enableDomesticDirect: enableDomesticDirect,
            ruleProviders: parsedRuleProviders,
            expandedOrDroppedProviders: &expandedOrDroppedProviders
        )

        var emittedSections = Set<String>()

        for (key, sectionLines) in sections.orderedSections {
            if key == "dns" {
                if let optimizedDNSLines {
                    resultLines.append(contentsOf: optimizedDNSLines)
                }
                emittedSections.insert("dns")
            } else if key == "rules" {
                continue
            } else if key == "rule-providers" {
                let sanitizedProviders = sanitizeRuleProvidersSection(
                    sectionLines,
                    providers: parsedRuleProviders,
                    droppedOrExpanded: expandedOrDroppedProviders
                )
                if !sanitizedProviders.isEmpty {
                    if !emittedSections.contains("dns"), let optimizedDNSLines {
                        resultLines.append(contentsOf: optimizedDNSLines)
                        emittedSections.insert("dns")
                    }
                    resultLines.append(contentsOf: sanitizedProviders)
                    emittedSections.insert(key)
                }
            } else if key == "proxies" || key == "proxy-groups" || key == "proxy-providers" {
                if !emittedSections.contains("dns"), let optimizedDNSLines {
                    resultLines.append(contentsOf: optimizedDNSLines)
                    emittedSections.insert("dns")
                }
                resultLines.append(contentsOf: sectionLines)
                emittedSections.insert(key)
            } else {
                resultLines.append(contentsOf: sectionLines)
                emittedSections.insert(key)
            }
        }

        if !emittedSections.contains("dns"), let optimizedDNSLines {
            resultLines.insert(contentsOf: optimizedDNSLines, at: 0)
            emittedSections.insert("dns")
        }

        resultLines.append(contentsOf: optimizedRuleLines)
        emittedSections.insert("rules")

        var output = resultLines.joined(separator: "\n")
        if !output.hasSuffix("\n") {
            output.append("\n")
        }
        return output
    }

    // MARK: - Section Parsing

    private struct OrderedSectionMap {
        var orderedSections: [(String, [String])] = []
        var sectionMap: [String: [String]] = [:]

        subscript(key: String) -> [String]? {
            get { sectionMap[key] }
            set {
                sectionMap[key] = newValue
                if let idx = orderedSections.firstIndex(where: { $0.0 == key }) {
                    if let val = newValue {
                        orderedSections[idx] = (key, val)
                    } else {
                        orderedSections.remove(at: idx)
                    }
                } else if let val = newValue {
                    orderedSections.append((key, val))
                }
            }
        }
    }

    private static func canonicalSectionKey(_ rawKey: String) -> String {
        let lower = rawKey.lowercased()
        switch lower {
        case "proxy", "proxies":
            return "proxies"
        case "proxy-group", "proxy-groups", "proxy group", "proxy groups":
            return "proxy-groups"
        case "rule", "rules":
            return "rules"
        case "rule-provider", "rule-providers", "rule provider", "rule providers":
            return "rule-providers"
        case "proxy-provider", "proxy-providers", "proxy provider", "proxy providers":
            return "proxy-providers"
        case "dns":
            return "dns"
        default:
            return lower
        }
    }

    private static func parseTopLevelSections(from lines: [String]) -> OrderedSectionMap {
        var result = OrderedSectionMap()
        var currentSection: String?
        var currentLines: [String] = []

        func finishSection() {
            if let section = currentSection {
                result[section] = currentLines
            } else if !currentLines.isEmpty {
                result["_preamble_"] = currentLines
            }
            currentLines.removeAll(keepingCapacity: true)
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isComment = trimmed.hasPrefix("#")
            let isListItem = trimmed.hasPrefix("-")
            let isIndent = line.hasPrefix(" ") || line.hasPrefix("\t")

            if !isIndent, !isComment, !isListItem, let colonIndex = line.firstIndex(of: ":") {
                let rawKeyCandidate = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces)
                if !rawKeyCandidate.isEmpty {
                    finishSection()
                    let canonicalKey = canonicalSectionKey(rawKeyCandidate)
                    currentSection = canonicalKey
                    let remainder = String(line[colonIndex...]).trimmingCharacters(in: .whitespaces)
                    let normalizedLine = (remainder == ":" && canonicalKey != rawKeyCandidate)
                        ? "\(canonicalKey):"
                        : line
                    currentLines.append(normalizedLine)
                    continue
                }
            }
            currentLines.append(line)
        }
        finishSection()
        return result
    }

    // MARK: - DNS Section Optimization

    private static func optimizeDNSSection(_ existingLines: [String]?, customRules: [CustomRule] = []) -> [String] {
        guard let lines = existingLines, !lines.isEmpty else {
            return defaultDNSBlock(customRules: customRules)
        }

        var existingNameservers: [String] = []
        var existingFallbacks: [String] = []
        var existingFakeIPFilters: [String] = []
        // Every resolver the profile lists for a key, in order. Block-style
        // lists arrive one item per line after a bare `key:`.
        var existingPolicies: [(String, [String])] = []
        var otherDNSProps: [String] = []

        var currentField: String?
        var pendingPolicyIndex: Int?

        for line in lines.dropFirst() { // Skip "dns:"
            let trimmed = stripInlineComment(line.trimmingCharacters(in: .whitespaces))
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            let leadingSpaces = line.prefix(while: { $0 == " " }).count

            if leadingSpaces <= 2 && !trimmed.hasPrefix("-") {
                if let (key, val) = parseKeyAndValue(trimmed) {
                    let lowerKey = key.lowercased()
                    currentField = lowerKey
                    pendingPolicyIndex = nil

                    switch lowerKey {
                    case "enable", "enhanced-mode", "fake-ip-range":
                        continue
                    case "nameserver":
                        if !val.isEmpty {
                            existingNameservers.append(contentsOf: parseFlowList(val))
                        }
                        continue
                    case "fallback":
                        if !val.isEmpty {
                            existingFallbacks.append(contentsOf: parseFlowList(val))
                        }
                        continue
                    case "fake-ip-filter":
                        if !val.isEmpty {
                            existingFakeIPFilters.append(contentsOf: parseFlowList(val))
                        }
                        continue
                    case "nameserver-policy":
                        if !val.isEmpty {
                            existingPolicies.append(contentsOf: parseFlowPolicy(val).map {
                                ($0.0, normalizePolicyResolverValues($0.1))
                            })
                        }
                        continue
                    case "fallback-filter":
                        // Will be generated deterministically
                        continue
                    default:
                        let recognizedDNSFields: Set<String> = [
                            "ipv6", "use-hosts", "respect-rules", "listen",
                            "default-nameserver", "proxy-server-nameserver",
                            "edns-client-subnet"
                        ]
                        if recognizedDNSFields.contains(lowerKey) && !val.isEmpty {
                            otherDNSProps.append("  \(key): \(val)")
                        }
                        continue
                    }
                }
            }

            if let field = currentField {
                if trimmed.hasPrefix("-") {
                    let item = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                    let cleanItem = unquote(stripInlineComment(item))
                    guard !cleanItem.isEmpty else { continue }
                    switch field {
                    case "nameserver":
                        existingNameservers.append(cleanItem)
                    case "fallback":
                        existingFallbacks.append(cleanItem)
                    case "fake-ip-filter":
                        existingFakeIPFilters.append(cleanItem)
                    case "nameserver-policy":
                        if let index = pendingPolicyIndex {
                            existingPolicies[index].1.append(cleanItem)
                        }
                    default:
                        break
                    }
                    continue
                } else if field == "nameserver-policy" {
                    if let (k, v) = parsePolicyLine(trimmed) {
                        if v.isEmpty {
                            existingPolicies.append((k, []))
                            pendingPolicyIndex = existingPolicies.count - 1
                        } else {
                            pendingPolicyIndex = nil
                            existingPolicies.append((k, normalizePolicyResolverValues(v)))
                        }
                    }
                    continue
                }
            }
        }

        var output: [String] = ["dns:"]
        output.append("  enable: true")
        output.append("  enhanced-mode: fake-ip")
        output.append("  fake-ip-range: 198.18.0.1/16")

        var mergedNameservers: [String] = []
        for ns in domesticNameservers {
            if !mergedNameservers.contains(ns) {
                mergedNameservers.append(ns)
            }
        }
        for ns in existingNameservers {
            if !mergedNameservers.contains(ns) {
                mergedNameservers.append(ns)
            }
        }
        output.append("  nameserver:")
        for ns in mergedNameservers {
            output.append("    - \(ns)")
        }

        var mergedFallbacks: [String] = existingFallbacks
        if mergedFallbacks.isEmpty {
            mergedFallbacks = ["1.1.1.1", "8.8.8.8"]
        }
        output.append("  fallback:")
        for fb in mergedFallbacks {
            output.append("    - \(fb)")
        }

        var mergedFakeIP: [String] = []
        var fakeIPSet = Set<String>()
        for domain in fakeIPFilterDomains {
            if !fakeIPSet.contains(domain) {
                fakeIPSet.insert(domain)
                mergedFakeIP.append(domain)
            }
        }
        for rule in customRules where rule.isEnabled && rule.target.isDirect {
            let directDomain: String?
            switch rule.kind {
            case .domain:
                directDomain = rule.value
            case .domainSuffix:
                directDomain = rule.value.hasPrefix(".") ? "*\(rule.value)" : "*.\(rule.value)"
            default:
                directDomain = nil
            }
            if let d = directDomain, !fakeIPSet.contains(d) {
                fakeIPSet.insert(d)
                mergedFakeIP.append(d)
            }
        }
        for domain in existingFakeIPFilters {
            if !fakeIPSet.contains(domain) {
                fakeIPSet.insert(domain)
                mergedFakeIP.append(domain)
            }
        }
        output.append("  fake-ip-filter:")
        for domain in mergedFakeIP {
            output.append("    - '\(domain)'")
        }

        var mergedPolicies: [(String, [String])] = domesticNameserverPolicies.map {
            ($0.0, [$0.1])
        }
        var policyKeys = Set(mergedPolicies.map { unquote($0.0) })
        for (k, values) in existingPolicies {
            let cleanK = unquote(k)
            guard !cleanK.lowercased().hasPrefix("geosite:"), !cleanK.isEmpty else { continue }
            if !policyKeys.contains(cleanK) {
                policyKeys.insert(cleanK)
                mergedPolicies.append((cleanK, values))
            }
        }
        output.append("  nameserver-policy:")
        for (k, values) in mergedPolicies {
            let cleanK = unquote(k)
            let cleanValues = values.map(unquote).filter { !$0.isEmpty }
            guard !cleanK.isEmpty, !cleanValues.isEmpty else { continue }
            let formattedKey = cleanK.contains(":") || cleanK.hasPrefix("+.") || cleanK.contains("*") ? "'\(cleanK)'" : cleanK
            // One resolver stays a plain scalar so the common case reads the
            // same as before; several become a flow list, quoted so a `#` or
            // `,` inside a resolver URL survives.
            let formattedValue = cleanValues.count == 1
                ? cleanValues[0]
                : "[" + cleanValues.map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }
                    .joined(separator: ", ") + "]"
            output.append("    \(formattedKey): \(formattedValue)")
        }

        output.append("  fallback-filter:")
        output.append("    geoip: true")
        output.append("    geoip-code: CN")
        output.append("    ipcidr:")
        output.append("      - 240.0.0.0/4")

        for prop in otherDNSProps {
            output.append(prop)
        }

        return output
    }

    private static func defaultDNSBlock(customRules: [CustomRule] = []) -> [String] {
        var output: [String] = [
            "dns:",
            "  enable: true",
            "  enhanced-mode: fake-ip",
            "  fake-ip-range: 198.18.0.1/16",
            "  nameserver:",
        ]
        for ns in domesticNameservers {
            output.append("    - \(ns)")
        }
        output.append("  fallback:")
        output.append("    - 1.1.1.1")
        output.append("    - 8.8.8.8")
        output.append("  fake-ip-filter:")
        var mergedFakeIP: [String] = []
        var fakeIPSet = Set<String>()
        for domain in fakeIPFilterDomains {
            if !fakeIPSet.contains(domain) {
                fakeIPSet.insert(domain)
                mergedFakeIP.append(domain)
            }
        }
        for rule in customRules where rule.isEnabled && rule.target.isDirect {
            let directDomain: String?
            switch rule.kind {
            case .domain:
                directDomain = rule.value
            case .domainSuffix:
                directDomain = rule.value.hasPrefix(".") ? "*\(rule.value)" : "*.\(rule.value)"
            default:
                directDomain = nil
            }
            if let d = directDomain, !fakeIPSet.contains(d) {
                fakeIPSet.insert(d)
                mergedFakeIP.append(d)
            }
        }
        for domain in mergedFakeIP {
            output.append("    - '\(domain)'")
        }
        output.append("  nameserver-policy:")
        for (k, v) in domesticNameserverPolicies {
            let cleanK = unquote(k)
            let cleanV = unquote(v)
            let formattedKey = cleanK.contains(":") || cleanK.hasPrefix("+.") || cleanK.contains("*") ? "'\(cleanK)'" : cleanK
            output.append("    \(formattedKey): \(cleanV)")
        }
        output.append("  fallback-filter:")
        output.append("    geoip: true")
        output.append("    geoip-code: CN")
        output.append("    ipcidr:")
        output.append("      - 240.0.0.0/4")
        return output
    }

    // MARK: - Rules Section Optimization

    /// `AETHER-APP` is generated only from the user's application rules; one
    /// written into a profile is dropped rather than trusted.
    static func isApplicationRule(_ rule: String) -> Bool {
        rule.split(separator: ",", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespaces)
            .uppercased() == CustomRuleKind.application.rawValue
    }

    // MARK: - Rule Provider & RULE-SET Normalization

    struct RuleProviderDef {
        let name: String
        var type: String = ""
        var behavior: String = ""
        var format: String = ""
        var url: String = ""
        var path: String = ""
        var rawLines: [String] = []
    }

    private static func parseRuleProvidersSection(_ existingLines: [String]?) -> [String: RuleProviderDef] {
        guard let lines = existingLines, !lines.isEmpty else { return [:] }
        var result: [String: RuleProviderDef] = [:]
        var currentDef: RuleProviderDef?

        func finishCurrent() {
            if let def = currentDef, !def.name.isEmpty {
                result[def.name.lowercased()] = def
            }
            currentDef = nil
        }

        for line in lines.dropFirst() { // Skip "rule-providers:"
            let trimmed = stripInlineComment(line.trimmingCharacters(in: .whitespaces))
            guard !trimmed.isEmpty else { continue }
            let leadingSpaces = line.prefix(while: { $0 == " " }).count

            if leadingSpaces <= 2 && !trimmed.hasPrefix("-") {
                if let colonIdx = trimmed.firstIndex(of: ":") {
                    finishCurrent()
                    let name = unquote(String(trimmed[..<colonIdx]).trimmingCharacters(in: .whitespaces))
                    let remainder = String(trimmed[trimmed.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
                    var def = RuleProviderDef(name: name, rawLines: [line])
                    if remainder.hasPrefix("{") && remainder.hasSuffix("}") {
                        for pair in parseFlowPolicy(remainder) {
                            applyProviderField(pair.0.lowercased(), pair.1, to: &def)
                        }
                    }
                    currentDef = def
                    continue
                }
            }

            if var def = currentDef {
                def.rawLines.append(line)
                if let (key, val) = parseKeyAndValue(trimmed) {
                    applyProviderField(key.lowercased(), unquote(val), to: &def)
                }
                currentDef = def
            }
        }
        finishCurrent()
        return result
    }

    private static func applyProviderField(_ key: String, _ value: String, to def: inout RuleProviderDef) {
        let clean = unquote(value)
        switch key {
        case "type": def.type = clean.lowercased()
        case "behavior": def.behavior = clean.lowercased()
        case "format": def.format = clean.lowercased()
        case "url": def.url = clean
        case "path": def.path = clean
        default: break
        }
    }

    private static func sanitizeRuleProvidersSection(
        _ existingLines: [String]?,
        providers: [String: RuleProviderDef],
        droppedOrExpanded: Set<String>
    ) -> [String] {
        guard let lines = existingLines, !lines.isEmpty else { return [] }
        var retainedLines: [String] = []

        for (_, def) in providers {
            let lower = def.name.lowercased()
            if def.type == "http" || def.behavior == "classical" || droppedOrExpanded.contains(lower) {
                continue
            }
            if retainedLines.isEmpty {
                retainedLines.append("rule-providers:")
            }
            retainedLines.append(contentsOf: def.rawLines)
        }
        return retainedLines
    }

    private static func synthesizeRules(
        forProviderName rawName: String,
        target: String,
        providerDef: RuleProviderDef?
    ) -> [String]? {
        let cleanTarget = unquote(target).trimmingCharacters(in: .whitespaces)
        guard !cleanTarget.isEmpty else { return nil }

        func normalizedKey(_ s: String) -> String {
            s.lowercased().filter { $0.isLetter || $0.isNumber }
        }

        func filenameStem(from pathOrURL: String) -> String {
            guard !pathOrURL.isEmpty else { return "" }
            let urlComponents = pathOrURL.split(separator: "/")
            guard let last = urlComponents.last else { return "" }
            let filename = String(last.split(separator: "?").first ?? last)
            let stem = String(filename.split(separator: ".").first ?? Substring(filename))
            return normalizedKey(stem)
        }

        var candidateKeys: Set<String> = [normalizedKey(rawName)]
        if let def = providerDef {
            candidateKeys.insert(normalizedKey(def.name))
            if !def.url.isEmpty {
                candidateKeys.insert(filenameStem(from: def.url))
            }
            if !def.path.isEmpty {
                candidateKeys.insert(filenameStem(from: def.path))
            }
        }

        func matchesAny(_ keywords: [String]) -> Bool {
            for kw in keywords {
                if candidateKeys.contains(kw) { return true }
            }
            return false
        }

        if matchesAny(["localareanetwork", "lan", "local", "private", "rfc1918", "lancidr", "privatecidr"]) {
            return [
                "IP-CIDR,192.168.0.0/16,\(cleanTarget),no-resolve",
                "IP-CIDR,10.0.0.0/8,\(cleanTarget),no-resolve",
                "IP-CIDR,172.16.0.0/12,\(cleanTarget),no-resolve",
                "IP-CIDR,127.0.0.0/8,\(cleanTarget),no-resolve",
                "IP-CIDR,100.64.0.0/10,\(cleanTarget),no-resolve",
                "DOMAIN-SUFFIX,local,\(cleanTarget)",
                "DOMAIN-SUFFIX,lan,\(cleanTarget)",
            ]
        }
        if matchesAny(["banad", "banprogramad", "baneasylist", "advertising", "reject", "ad", "ads", "categoryadsall", "categoryads"]) {
            return ["GEOSITE,category-ads-all,\(cleanTarget)"]
        }
        if matchesAny(["googlefcm", "fcm"]) {
            return [
                "GEOSITE,googlefcm,\(cleanTarget)",
                "GEOSITE,google,\(cleanTarget)",
            ]
        }
        if matchesAny(["googlecn", "google-cn"]) {
            return [
                "DOMAIN-SUFFIX,google.cn,\(cleanTarget)",
                "DOMAIN-SUFFIX,gstatic.cn,\(cleanTarget)",
                "DOMAIN-SUFFIX,google.com.hk,\(cleanTarget)",
            ]
        }
        if matchesAny(["steamcn", "steam-cn"]) {
            return [
                "DOMAIN-SUFFIX,steamserver.net,\(cleanTarget)",
                "DOMAIN-SUFFIX,steampowered.com.8686c.com,\(cleanTarget)",
                "DOMAIN-SUFFIX,csgo.wmsj.cn,\(cleanTarget)",
                "DOMAIN-SUFFIX,dota2.wmsj.cn,\(cleanTarget)",
            ]
        }
        if matchesAny(["steam"]) {
            return ["GEOSITE,steam,\(cleanTarget)"]
        }
        if matchesAny(["onedrive"]) {
            return [
                "GEOSITE,onedrive,\(cleanTarget)",
                "GEOSITE,microsoft,\(cleanTarget)",
            ]
        }
        if matchesAny(["microsoft", "ms"]) {
            return ["GEOSITE,microsoft,\(cleanTarget)"]
        }
        if matchesAny(["apple", "icloud"]) {
            return ["GEOSITE,apple,\(cleanTarget)"]
        }
        if matchesAny(["telegram", "tg", "telegramcidr"]) {
            return [
                "GEOSITE,telegram,\(cleanTarget)",
                "IP-CIDR,91.108.4.0/22,\(cleanTarget),no-resolve",
                "IP-CIDR,91.108.8.0/21,\(cleanTarget),no-resolve",
                "IP-CIDR,91.108.16.0/21,\(cleanTarget),no-resolve",
                "IP-CIDR,91.108.56.0/22,\(cleanTarget),no-resolve",
                "IP-CIDR,149.154.160.0/20,\(cleanTarget),no-resolve",
            ]
        }
        if matchesAny(["gemini"]) {
            return [
                "GEOSITE,google-gemini,\(cleanTarget)",
                "GEOSITE,google,\(cleanTarget)",
                "GEOSITE,category-ai-!cn,\(cleanTarget)",
            ]
        }
        if matchesAny(["copilot"]) {
            return [
                "GEOSITE,openai,\(cleanTarget)",
                "GEOSITE,microsoft,\(cleanTarget)",
                "GEOSITE,category-ai-!cn,\(cleanTarget)",
            ]
        }
        if matchesAny(["openai", "chatgpt", "ai", "claude", "anthropic"]) {
            return [
                "GEOSITE,openai,\(cleanTarget)",
                "GEOSITE,category-ai-!cn,\(cleanTarget)",
                "GEOSITE,anthropic,\(cleanTarget)",
            ]
        }
        if matchesAny(["netflix"]) {
            return ["GEOSITE,netflix,\(cleanTarget)"]
        }
        if matchesAny(["proxymedia", "globalmedia", "foreignmedia", "media"]) {
            return [
                "GEOSITE,youtube,\(cleanTarget)",
                "GEOSITE,netflix,\(cleanTarget)",
                "GEOSITE,disney,\(cleanTarget)",
                "GEOSITE,spotify,\(cleanTarget)",
                "GEOSITE,tiktok,\(cleanTarget)",
                "GEOSITE,category-media,\(cleanTarget)",
            ]
        }
        if matchesAny(["proxylite", "proxygfwlist", "gfw", "gfwlist", "global", "proxy", "proxies", "tldnotcn", "proxydomain"]) {
            return ["GEOSITE,geolocation-!cn,\(cleanTarget)"]
        }
        if matchesAny(["chinadomain", "chinamedia", "chinamax", "china", "cn", "direct", "directdomain"]) {
            return ["GEOSITE,cn,\(cleanTarget)"]
        }
        if matchesAny(["chinacompanyip", "chinaip", "cnip", "chinaipex", "cncidr", "chinaips", "chinaipsv4", "chinaipsv6"]) {
            return ["GEOIP,CN,\(cleanTarget),no-resolve"]
        }
        if matchesAny(["youtube"]) {
            return ["GEOSITE,youtube,\(cleanTarget)"]
        }
        if matchesAny(["google"]) {
            return ["GEOSITE,google,\(cleanTarget)"]
        }
        if matchesAny(["bilibili"]) {
            return ["GEOSITE,bilibili,\(cleanTarget)"]
        }
        if matchesAny(["github"]) {
            return ["GEOSITE,github,\(cleanTarget)"]
        }
        if matchesAny(["twitter", "x"]) {
            return ["GEOSITE,twitter,\(cleanTarget)"]
        }
        if matchesAny(["spotify"]) {
            return ["GEOSITE,spotify,\(cleanTarget)"]
        }
        if matchesAny(["disney", "disneyplus"]) {
            return ["GEOSITE,disney,\(cleanTarget)"]
        }
        if matchesAny(["tiktok"]) {
            return ["GEOSITE,tiktok,\(cleanTarget)"]
        }
        if matchesAny(["unban"]) {
            return [
                "DOMAIN-SUFFIX,alidns.com,\(cleanTarget)",
                "DOMAIN-SUFFIX,doh.pub,\(cleanTarget)",
            ]
        }

        return nil
    }

    private static func optimizeRulesSection(
        _ existingLines: [String]?,
        customRules: [CustomRule] = [],
        remoteRules: [String] = [],
        enableDomesticDirect: Bool = true,
        ruleProviders: [String: RuleProviderDef] = [:],
        expandedOrDroppedProviders: inout Set<String>
    ) -> [String] {
        var rawRules: [String] = []

        if let lines = existingLines {
            for line in lines.dropFirst() { // Skip "rules:"
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("-") {
                    let ruleContent = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                    let clean = unquote(stripInlineComment(ruleContent))
                    guard !clean.isEmpty && clean != "-" && clean != "''" && clean != "\"\""
                        && !isApplicationRule(clean) else {
                        continue
                    }

                    let tokens = clean.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    if tokens.first?.uppercased() == "RULE-SET" {
                        let providerName = tokens.count > 1 ? tokens[1] : ""
                        let target = tokens.count > 2 ? tokens[2] : ""
                        let providerDef = ruleProviders[providerName.lowercased()]
                        if let synthesized = synthesizeRules(forProviderName: providerName, target: target, providerDef: providerDef) {
                            expandedOrDroppedProviders.insert(providerName.lowercased())
                            rawRules.append(contentsOf: synthesized)
                            continue
                        }

                        // If not synthesized, check if this references an existing safe inline or file rule-provider
                        if let def = providerDef,
                           (def.type == "inline" || def.type == "file" || def.type.isEmpty),
                           def.behavior != "classical" {
                            // Safe custom inline/file provider: retain both the rule and the provider
                            rawRules.append(clean)
                            continue
                        }

                        // Unexpanded / unknown / remote HTTP rule-provider: safely drop RULE-SET
                        expandedOrDroppedProviders.insert(providerName.lowercased())
                        continue
                    }

                    rawRules.append(clean)
                }
            }
        }

        var seenNormalized = Set<String>()
        var newRules: [String] = []

        // 0. Mandatory loopback protection rules at priority #1 (ahead of
        //    application and custom destination rules) so local 127.0.0.0/8,
        //    ::1, and localhost/RFC 6761 traffic never leaks to a proxy node.
        for rule in loopbackProtectionRules {
            let norm = normalizedRuleString(rule)
            if !seenNormalized.contains(norm) {
                newRules.append(rule)
                seenNormalized.insert(norm)
            }
        }

        // 1. User rules: application rules first (they name the app outright,
        //    so they outrank any non-loopback destination rule), then custom
        //    rules in the user's order.
        let orderedCustomRules = customRules.filter { $0.kind == .application }
            + customRules.filter { $0.kind != .application }
        for rule in orderedCustomRules where rule.isEnabled {
            let clashRule = rule.toClashRuleString()
            let norm = normalizedRuleString(clashRule)
            if !seenNormalized.contains(norm) {
                newRules.append(clashRule)
                seenNormalized.insert(norm)
            }
        }

        // 2. High priority remote rule-providers
        for rule in remoteRules {
            let norm = normalizedRuleString(rule)
            if !seenNormalized.contains(norm) {
                newRules.append(rule)
                seenNormalized.insert(norm)
            }
        }

        // 3. High priority domestic / VPN bypass rules
        if enableDomesticDirect {
            for rule in highPriorityBypassRules {
                let norm = normalizedRuleString(rule)
                if !seenNormalized.contains(norm) {
                    newRules.append(rule)
                    seenNormalized.insert(norm)
                }
            }
        }

        var preMatchRules: [String] = []
        var matchRules: [String] = []

        for r in rawRules {
            let norm = normalizedRuleString(r)
            if seenNormalized.contains(norm) {
                continue
            }
            if norm.hasPrefix("MATCH,") || norm == "MATCH" {
                matchRules.append(r)
            } else {
                preMatchRules.append(r)
                seenNormalized.insert(norm)
            }
        }

        newRules.append(contentsOf: preMatchRules)

        if enableDomesticDirect {
            let normFallback = normalizedRuleString(fallbackDirectRule)
            if !seenNormalized.contains(normFallback) {
                newRules.append(fallbackDirectRule)
                seenNormalized.insert(normFallback)
            }
        }

        newRules.append(contentsOf: matchRules)

        if newRules.isEmpty {
            newRules = enableDomesticDirect
                ? (highPriorityBypassRules + [fallbackDirectRule, "MATCH,DIRECT"])
                : (loopbackProtectionRules + ["MATCH,DIRECT"])
        }

        var output: [String] = ["rules:"]
        for r in newRules {
            output.append("  - \(r)")
        }
        return output
    }

    // MARK: - Utilities

    private static func normalizedRuleString(_ rule: String) -> String {
        rule.filter { !$0.isWhitespace }.uppercased()
    }

    private static func unquote(_ str: String) -> String {
        var s = str.trimmingCharacters(in: .whitespaces)
        if (s.hasPrefix("'") && s.hasSuffix("'")) || (s.hasPrefix("\"") && s.hasSuffix("\"")) {
            s.removeFirst()
            s.removeLast()
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    private static func stripInlineComment(_ line: String) -> String {
        var inSingleQuote = false
        var inDoubleQuote = false
        var previousWasWhitespace = true
        for idx in line.indices {
            let ch = line[idx]
            if ch == "'" && !inDoubleQuote {
                inSingleQuote.toggle()
            } else if ch == "\"" && !inSingleQuote {
                inDoubleQuote.toggle()
            } else if ch == "#" && !inSingleQuote && !inDoubleQuote && previousWasWhitespace {
                return String(line[..<idx]).trimmingCharacters(in: .whitespaces)
            }
            previousWasWhitespace = ch.isWhitespace
        }
        return line.trimmingCharacters(in: .whitespaces)
    }

    private static func normalizePolicyResolverValues(_ rawValue: String) -> [String] {
        let stripped = stripInlineComment(rawValue)
        if stripped.hasPrefix("[") && stripped.hasSuffix("]") {
            return parseFlowList(stripped)
        }
        let value = unquote(stripped)
        return value.isEmpty ? [] : [value]
    }

    private static func parseKeyAndValue(_ line: String) -> (String, String)? {
        guard let colonIdx = line.firstIndex(of: ":") else { return nil }
        let key = String(line[..<colonIdx]).trimmingCharacters(in: .whitespaces)
        let val = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
        return (key, val)
    }

    private static func parsePolicyLine(_ trimmed: String) -> (String, String)? {
        if trimmed.hasPrefix("'"), let secondQuote = trimmed.dropFirst().firstIndex(of: "'") {
            let key = String(trimmed[...secondQuote])
            let remainder = trimmed[trimmed.index(after: secondQuote)...].trimmingCharacters(in: .whitespaces)
            if remainder.hasPrefix(":") {
                let value = remainder.dropFirst().trimmingCharacters(in: .whitespaces)
                return (key, value)
            }
        } else if trimmed.hasPrefix("\""), let secondQuote = trimmed.dropFirst().firstIndex(of: "\"") {
            let key = String(trimmed[...secondQuote])
            let remainder = trimmed[trimmed.index(after: secondQuote)...].trimmingCharacters(in: .whitespaces)
            if remainder.hasPrefix(":") {
                let value = remainder.dropFirst().trimmingCharacters(in: .whitespaces)
                return (key, value)
            }
        } else if let range = trimmed.range(of: ": ") {
            let key = String(trimmed[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            return (key, value)
        } else if trimmed.hasSuffix(":") {
            let key = String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces)
            return (key, "")
        }
        return nil
    }

    private static func parseFlowList(_ value: String) -> [String] {
        var s = value.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("[") && s.hasSuffix("]") {
            s.removeFirst()
            s.removeLast()
        }
        return s.split(separator: ",").map { unquote(String($0)) }.filter { !$0.isEmpty }
    }

    private static func parseFlowPolicy(_ value: String) -> [(String, String)] {
        var s = value.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("{") && s.hasSuffix("}") {
            s.removeFirst()
            s.removeLast()
        }
        var results: [(String, String)] = []
        for pair in s.split(separator: ",") {
            let trimmedPair = pair.trimmingCharacters(in: .whitespaces)
            if let (k, v) = parsePolicyLine(trimmedPair) {
                results.append((k, v))
            }
        }
        return results
    }
}
