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
        if let appGroupDefaults = UserDefaults(suiteName: AppConstants.appGroup),
           let value = appGroupDefaults.object(forKey: userDefaultsKey) as? Bool {
            return value
        }
        if let standardValue = UserDefaults.standard.object(forKey: userDefaultsKey) as? Bool {
            return standardValue
        }
        return true
    }

    public static func setEnabled(_ enabled: Bool) {
        UserDefaults(suiteName: AppConstants.appGroup)?.set(enabled, forKey: userDefaultsKey)
        UserDefaults.standard.set(enabled, forKey: userDefaultsKey)
    }

    // MARK: - Predefined Rule Lists

    public static let highPriorityBypassRules: [String] = [
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
        "*.lan",
        "*.localdomain",
        "*.example",
        "*.invalid",
        "*.localhost",
        "*.test",
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
        ("'+.myqcloud.com'", "119.29.29.29"),
        ("'+.bdimg.com'", "119.29.29.29"),
        ("'+.bilivideo.com'", "119.29.29.29"),
        ("'+.tsinghua.edu.cn'", "223.5.5.5"),
        ("'+.ustc.edu.cn'", "223.5.5.5"),
    ]

    // MARK: - Optimization API

    /// Optimizes the provided raw YAML configuration for domestic download speed and
    /// Apple services acceleration while preserving proxy routing for foreign domains,
    /// with user custom rules injected at top priority.
    public static func optimizedProfile(for yaml: String, customRules: [CustomRule] = []) -> String {
        guard !yaml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return yaml }
        let lines = yaml.components(separatedBy: "\n")
        guard !lines.isEmpty else { return yaml }

        let sections = parseTopLevelSections(from: lines)

        var resultLines: [String] = []

        let optimizedDNSLines = optimizeDNSSection(sections["dns"], customRules: customRules)
        let optimizedRuleLines = optimizeRulesSection(sections["rules"], customRules: customRules)

        var emittedSections = Set<String>()

        for (key, sectionLines) in sections.orderedSections {
            if key == "dns" {
                resultLines.append(contentsOf: optimizedDNSLines)
                emittedSections.insert("dns")
            } else if key == "rules" {
                continue
            } else if key == "proxies" || key == "proxy-groups" || key == "proxy-providers" || key == "rule-providers" {
                if !emittedSections.contains("dns") {
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

        if !emittedSections.contains("dns") {
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
        var existingPolicies: [(String, String)] = []
        var otherDNSProps: [String] = []

        var currentField: String?

        for line in lines.dropFirst() { // Skip "dns:"
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            let leadingSpaces = line.prefix(while: { $0 == " " }).count

            if leadingSpaces <= 2 {
                if let (key, val) = parseKeyAndValue(trimmed) {
                    let lowerKey = key.lowercased()
                    currentField = lowerKey

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
                            existingPolicies.append(contentsOf: parseFlowPolicy(val))
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
                    let cleanItem = unquote(item)
                    switch field {
                    case "nameserver":
                        existingNameservers.append(cleanItem)
                    case "fallback":
                        existingFallbacks.append(cleanItem)
                    case "fake-ip-filter":
                        existingFakeIPFilters.append(cleanItem)
                    default:
                        break
                    }
                    continue
                } else if field == "nameserver-policy" {
                    if let (k, v) = parsePolicyLine(trimmed) {
                        existingPolicies.append((k, v))
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

        var mergedPolicies: [(String, String)] = domesticNameserverPolicies
        var policyKeys = Set(mergedPolicies.map { unquote($0.0) })
        for (k, v) in existingPolicies {
            let cleanK = unquote(k)
            guard !cleanK.lowercased().hasPrefix("geosite:"), !cleanK.isEmpty else { continue }
            if !policyKeys.contains(cleanK) {
                policyKeys.insert(cleanK)
                mergedPolicies.append((cleanK, unquote(v)))
            }
        }
        output.append("  nameserver-policy:")
        for (k, v) in mergedPolicies {
            let cleanK = unquote(k)
            let cleanV = unquote(v)
            guard !cleanK.isEmpty, !cleanV.isEmpty else { continue }
            let formattedKey = cleanK.contains(":") || cleanK.hasPrefix("+.") || cleanK.contains("*") ? "'\(cleanK)'" : cleanK
            output.append("    \(formattedKey): \(cleanV)")
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

    private static func optimizeRulesSection(_ existingLines: [String]?, customRules: [CustomRule] = []) -> [String] {
        var rawRules: [String] = []

        if let lines = existingLines {
            for line in lines.dropFirst() { // Skip "rules:"
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("-") {
                    var ruleContent = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                    if !ruleContent.hasPrefix("'") && !ruleContent.hasPrefix("\""),
                       let hashIdx = ruleContent.firstIndex(of: "#") {
                        ruleContent = String(ruleContent[..<hashIdx]).trimmingCharacters(in: .whitespaces)
                    }
                    let clean = unquote(ruleContent)
                    if !clean.isEmpty && clean != "-" && clean != "''" && clean != "\"\"" {
                        rawRules.append(clean)
                    }
                }
            }
        }

        var seenNormalized = Set<String>()
        var newRules: [String] = []

        // 1. User custom rules injected at top priority
        for rule in customRules where rule.isEnabled {
            let clashRule = rule.toClashRuleString()
            let norm = normalizedRuleString(clashRule)
            if !seenNormalized.contains(norm) {
                newRules.append(clashRule)
                seenNormalized.insert(norm)
            }
        }

        // 2. High priority domestic / VPN bypass rules
        for rule in highPriorityBypassRules {
            let norm = normalizedRuleString(rule)
            if !seenNormalized.contains(norm) {
                newRules.append(rule)
                seenNormalized.insert(norm)
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

        let normFallback = normalizedRuleString(fallbackDirectRule)
        if !seenNormalized.contains(normFallback) {
            newRules.append(fallbackDirectRule)
            seenNormalized.insert(normFallback)
        }

        newRules.append(contentsOf: matchRules)

        if newRules.isEmpty {
            newRules = highPriorityBypassRules + [fallbackDirectRule, "MATCH,DIRECT"]
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
