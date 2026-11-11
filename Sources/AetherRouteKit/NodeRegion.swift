import Foundation

/// Infers the region a proxy node is named after, for display only.
///
/// Node names are free text written by subscription authors, so matching is
/// deliberately conservative: a Latin code or place name must be a whole word
/// of the name. Substring matching read `SS-Proxy-AUTO` as Australia (`AU`),
/// `NODE-1` as Germany (`DE`) and `PLUS` as the United States (`US`); a
/// missing flag is harmless, a wrong one is misleading.
public struct NodeRegion: Equatable, Sendable {
    /// ISO 3166-1 alpha-2 code, except `UK`, which subscriptions use for GB.
    public let code: String
    public let flag: String

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var resolvedCache: [String: NodeRegion?] = [:]
    private static let maxCacheEntries = 2_048

    /// Resolves the region named by `name`, or `nil` when the name does not
    /// clearly name one.
    public static func resolve(from name: String) -> NodeRegion? {
        guard !name.isEmpty else { return nil }
        if let cached = cacheLock.withLock({ resolvedCache[name] }) {
            return cached
        }
        let resolved = computeRegion(from: name)
        cacheLock.withLock {
            if resolvedCache.count >= maxCacheEntries {
                resolvedCache.removeAll(keepingCapacity: true)
            }
            resolvedCache[name] = resolved
        }
        return resolved
    }

    private static let capacityAndRateUnits: Set<String> = [
        "B", "KB", "MB", "GB", "TB", "PB",
        "KIB", "MIB", "GIB", "TIB", "PIB",
        "BPS", "KBPS", "MBPS", "GBPS", "TBPS",
    ]

    private static func computeRegion(from name: String) -> NodeRegion? {
        guard !SubscriptionNoticeClassifier.isNotice(name) else {
            return nil
        }
        if let embedded = embeddedFlag(in: name) {
            return embedded
        }
        let words = nonUnitLatinWords(in: name)
        for entry in catalog {
            if entry.cjkNames.contains(where: name.contains) {
                return entry.region
            }
            if entry.latinNames.contains(where: { containsPhrase($0, in: words) }) {
                return entry.region
            }
        }
        return nil
    }

    /// Evaluates whether a proxy group member matches a user search query by
    /// node name, protocol name, transport name, dialer proxy, or resolved
    /// region aliases (flag, ISO code, Latin/CJK place names), without
    /// false-positive partial word matches.
    public static func matchesSearch(
        member: String,
        protocolName: String? = nil,
        transportName: String? = nil,
        dialerProxy: String? = nil,
        query: String
    ) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        if matchesSingleToken(
            member: member,
            protocolName: protocolName,
            transportName: transportName,
            dialerProxy: dialerProxy,
            token: trimmed
        ) {
            return true
        }
        let tokens = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.count > 1 else { return false }
        return tokens.allSatisfy { token in
            matchesSingleToken(
                member: member,
                protocolName: protocolName,
                transportName: transportName,
                dialerProxy: dialerProxy,
                token: token
            )
        }
    }

    private static func matchesSingleToken(
        member: String,
        protocolName: String?,
        transportName: String?,
        dialerProxy: String?,
        token: String
    ) -> Bool {
        if member.localizedCaseInsensitiveContains(token) {
            return true
        }
        if let protocolName, protocolName.localizedCaseInsensitiveContains(token) {
            return true
        }
        if let transportName, transportName.localizedCaseInsensitiveContains(token) {
            return true
        }
        if let dialerProxy, dialerProxy.localizedCaseInsensitiveContains(token) {
            return true
        }
        guard let region = resolve(from: member) else { return false }
        if region.code.localizedCaseInsensitiveContains(token) || region.flag.contains(token) {
            return true
        }
        if let entry = catalog.first(where: { $0.region.code == region.code }) {
            if entry.cjkNames.contains(where: { $0.localizedCaseInsensitiveContains(token) }) {
                return true
            }
            if entry.aliasCodes.contains(where: { $0.localizedCaseInsensitiveContains(token) }) {
                return true
            }
            if entry.latinNames.contains(where: {
                $0.joined(separator: " ").localizedCaseInsensitiveContains(token)
            }) {
                return true
            }
        }
        return false
    }

    public static func filterMembers(
        _ members: [String],
        protocolByName: [String: String] = [:],
        transportByName: [String: String] = [:],
        dialerByName: [String: String] = [:],
        query: String,
        hideTimedOut: Bool,
        isTimedOut: (String) -> Bool,
        selectedMember: String?
    ) -> [String] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedQuery.isEmpty && !hideTimedOut {
            return members
        }
        return members.filter { member in
            if hideTimedOut && member != selectedMember && isTimedOut(member) {
                return false
            }
            guard !trimmedQuery.isEmpty else { return true }
            return matchesSearch(
                member: member,
                protocolName: protocolByName[member],
                transportName: transportByName[member],
                dialerProxy: dialerByName[member],
                query: trimmedQuery
            )
        }
    }

    // MARK: - Matching

    /// A flag emoji written into the name is the author's own statement and
    /// wins over any word in it.
    private static func embeddedFlag(in name: String) -> NodeRegion? {
        for character in name {
            let scalars = character.unicodeScalars.map(\.value)
            guard scalars.count == 2,
                  scalars.allSatisfy({ (0x1F1E6...0x1F1FF).contains($0) })
            else { continue }
            let code = String(
                String.UnicodeScalarView(
                    scalars.compactMap { Unicode.Scalar($0 - 0x1F1E6 + 0x41) }
                )
            )
            if let entry = catalog.first(where: { $0.region.code == code || $0.aliasCodes.contains(code) }) {
                return entry.region
            }
            return NodeRegion(code: code, flag: String(character))
        }
        return nil
    }

    /// Upper-cased Latin words, omitting storage or bandwidth units that
    /// immediately follow a number (such as `154.92 GB`, `100GB`, `10 Gbps`)
    /// so `GB` in a byte count is never misread as Great Britain.
    private static func nonUnitLatinWords(in name: String) -> [String] {
        var words: [String] = []
        var current = ""
        var currentIsDigit = false
        var afterNumber = false

        func flush() {
            guard !current.isEmpty else { return }
            let upper = current.uppercased()
            current = ""
            if currentIsDigit {
                words.append(upper)
                afterNumber = true
            } else {
                if !(afterNumber && capacityAndRateUnits.contains(upper)) {
                    words.append(upper)
                }
                afterNumber = false
            }
        }

        for scalar in name.unicodeScalars {
            let v = scalar.value
            let isLetter = (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A)
            let isDigit = v >= 0x30 && v <= 0x39
            if isLetter || isDigit {
                if !current.isEmpty, isDigit != currentIsDigit {
                    flush()
                }
                currentIsDigit = isDigit
                current.unicodeScalars.append(scalar)
            } else {
                flush()
                let isHorizontalSpace = v == 0x20 || v == 0x09 || v == 0xA0
                let isDecimalPoint = v == 0x2E && afterNumber
                if !isHorizontalSpace && !isDecimalPoint {
                    afterNumber = false
                }
            }
        }
        flush()
        return words
    }

    private static func containsPhrase(_ phrase: [String], in words: [String]) -> Bool {
        guard !phrase.isEmpty, words.count >= phrase.count else { return false }
        for start in 0...(words.count - phrase.count)
            where words[start..<(start + phrase.count)].elementsEqual(phrase) {
            return true
        }
        return false
    }

    // MARK: - Catalog

    private struct Entry {
        let region: NodeRegion
        var aliasCodes: [String] = []
        /// Whole-word Latin names, each a sequence of upper-cased words.
        let latinNames: [[String]]
        /// CJK names are matched as substrings: they carry no word breaks and
        /// do not collide the way two-letter codes do.
        let cjkNames: [String]
    }

    private static func entry(
        _ code: String,
        _ flag: String,
        aliases: [String] = [],
        latin: [String],
        cjk: [String]
    ) -> Entry {
        Entry(
            region: NodeRegion(code: code, flag: flag),
            aliasCodes: aliases,
            latinNames: ([code] + aliases + latin).map {
                $0.split(separator: " ").map { $0.uppercased() }
            },
            cjkNames: cjk
        )
    }

    private static let catalog: [Entry] = [
        entry("HK", "🇭🇰", latin: ["Hong Kong", "HongKong"], cjk: ["香港"]),
        entry("JP", "🇯🇵", latin: ["Japan", "Tokyo", "Osaka"], cjk: ["日本", "东京", "大阪"]),
        entry("US", "🇺🇸", aliases: ["USA"], latin: ["United States", "America", "Los Angeles", "San Jose", "Seattle"], cjk: ["美国", "硅谷", "洛杉矶", "圣何塞", "西雅图"]),
        entry("SG", "🇸🇬", latin: ["Singapore"], cjk: ["新加坡", "狮城"]),
        entry("TW", "🇹🇼", latin: ["Taiwan", "Taipei"], cjk: ["台湾", "台北"]),
        entry("KR", "🇰🇷", latin: ["Korea", "Seoul"], cjk: ["韩国", "首尔"]),
        entry("UK", "🇬🇧", aliases: ["GB"], latin: ["United Kingdom", "Britain", "London"], cjk: ["英国", "伦敦"]),
        entry("DE", "🇩🇪", latin: ["Germany", "Frankfurt"], cjk: ["德国", "法兰克福"]),
        entry("FR", "🇫🇷", latin: ["France", "Paris"], cjk: ["法国", "巴黎"]),
        entry("CA", "🇨🇦", latin: ["Canada", "Toronto"], cjk: ["加拿大", "多伦多"]),
        entry("AU", "🇦🇺", latin: ["Australia", "Sydney"], cjk: ["澳大利亚", "澳洲", "悉尼"]),
    ]
}
