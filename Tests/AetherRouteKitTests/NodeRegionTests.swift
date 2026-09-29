import Testing
@testable import AetherRouteKit

@Suite("Node region inference")
struct NodeRegionTests {
    @Test(
        "a code that is only part of a word never names a region",
        arguments: [
            "SS-Proxy-AUTO",   // AUTO ⊃ AU
            "NODE-1",          // NODE ⊃ DE
            "Premium PLUS 01", // PLUS ⊃ US
            "Cache Relay",     // CACHE ⊃ CA
            "DEFAULT",         // DE
            "Status Check",    // STATUS ⊃ US
            "Balanced",
            "DIRECT",
            "REJECT",
            "",
        ]
    )
    func partialCodesDoNotMatch(name: String) {
        #expect(NodeRegion.resolve(from: name) == nil)
    }

    @Test(
        "whole-word codes, place names and CJK names resolve",
        arguments: [
            ("HK-01", "HK"),
            ("hk01", "HK"),
            ("sg2 | premium", "SG"),
            ("Hong Kong IPLC", "HK"),
            ("HongKong 02", "HK"),
            ("Tokyo Direct", "JP"),
            ("Singapore Edge", "SG"),
            ("US-Seattle-VLESS", "US"),
            ("USA 01", "US"),
            ("Los Angeles 3", "US"),
            ("GB London", "UK"),
            ("DE Frankfurt", "DE"),
            ("香港 01", "HK"),
            ("日本东京-Hy2", "JP"),
            ("美国洛杉矶", "US"),
            ("法兰克福", "DE"),
            ("澳洲悉尼", "AU"),
        ]
    )
    func namedRegionsResolve(name: String, code: String) {
        #expect(NodeRegion.resolve(from: name)?.code == code)
    }

    @Test("a flag written into the name wins over words in it")
    func embeddedFlagWins() {
        #expect(NodeRegion.resolve(from: "🇯🇵 US relay")?.code == "JP")
        #expect(NodeRegion.resolve(from: "🇬🇧 01")?.code == "UK")
        #expect(NodeRegion.resolve(from: "🇬🇧 01")?.flag == "🇬🇧")
    }

    @Test("an embedded flag outside the catalog keeps its own region")
    func uncataloguedFlag() {
        let region = NodeRegion.resolve(from: "🇳🇱 Amsterdam")
        #expect(region?.code == "NL")
        #expect(region?.flag == "🇳🇱")
    }
}
