import Foundation

/// The engine reports matched rules by its internal type name
/// ("DomainSuffix", "IPCIDR"), while profiles and the Rules page spell them
/// the way Clash configuration does ("DOMAIN-SUFFIX", "IP-CIDR"). Showing
/// both spellings for the same rule made the Connections page look like it
/// came from a different product.
public enum ClashRuleKindName {
    private static let names: [String: String] = [
        "domain": "DOMAIN",
        "domainsuffix": "DOMAIN-SUFFIX",
        "domainkeyword": "DOMAIN-KEYWORD",
        "domainregex": "DOMAIN-REGEX",
        "geoip": "GEOIP",
        "geosite": "GEOSITE",
        "ipcidr": "IP-CIDR",
        "ipcidr6": "IP-CIDR6",
        "srcipcidr": "SRC-IP-CIDR",
        "ipsuffix": "IP-SUFFIX",
        "ipasn": "IP-ASN",
        "srcport": "SRC-PORT",
        "dstport": "DST-PORT",
        "inport": "IN-PORT",
        "processname": "PROCESS-NAME",
        "processpath": "PROCESS-PATH",
        "processpathregex": "PROCESS-PATH-REGEX",
        // AetherRoute's application rule; its payload is the app's name.
        "aetherapp": "APP",
        "ruleset": "RULE-SET",
        "network": "NETWORK",
        "match": "MATCH",
        "and": "AND",
        "or": "OR",
        "not": "NOT",
    ]

    /// Returns the configuration spelling for an engine rule type, or the
    /// input unchanged when the type is unknown or already spelled that way.
    public static func display(_ engineName: String) -> String {
        let key = engineName
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .lowercased()
        return names[key] ?? engineName
    }
}
