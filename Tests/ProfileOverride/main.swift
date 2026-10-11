import Foundation

/// Writes profiles with overrides applied, in every layout the compiler
/// edits, so `scripts/test_profile_override_cores.sh` can start both cores
/// on them with networking denied (1.7.0).
@main
enum ProfileOverrideFixtureGenerator {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 2 else {
            fputs("usage: profile_override_fixture_generator <output-directory>\n", stderr)
            exit(64)
        }
        let output = URL(fileURLWithPath: arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let override = try ProfileOverride(
            groups: [
                CustomProxyGroup(name: "🇭🇰 香港自动", regions: ["HK"], excludeKeywords: ["游戏"], parentGroup: "节点选择", position: .top),
                CustomProxyGroup(name: "Japan, Tokyo", regions: ["JP"], mode: .failover, parentGroup: "节点选择", position: .bottom),
                CustomProxyGroup(name: "Picked", manualNodes: ["SG 03", "Missing"], parentGroup: "自动选择"),
                CustomProxyGroup(name: "Nobody", regions: ["BR"]),
            ],
            hiddenNodeKeywords: ["剩余流量", "Expire"]
        ).validated()

        var count = 0
        for (name, profile) in fixtures {
            let result = ProfileOverrideCompiler.apply(override, to: profile)
            guard result.yaml != profile else {
                fputs("\(name): override was not applied: \(result.diagnostics)\n", stderr)
                exit(1)
            }
            guard !result.diagnostics.contains(.unsupportedProfileLayout) else {
                fputs("\(name): unsupported layout\n", stderr)
                exit(1)
            }
            let summary = ProfileConfigurationInspector.inspect(yaml: result.yaml)
            for group in ["🇭🇰 香港自动", "Japan, Tokyo", "Picked", "Nobody"] {
                guard summary.proxyGroups.contains(where: { $0.name == group }) else {
                    fputs("\(name): \(group) missing\n", stderr)
                    exit(1)
                }
            }
            try result.yaml.write(
                to: output.appendingPathComponent("\(name).yaml"),
                atomically: true,
                encoding: .utf8
            )
            count += 1
        }
        print("profile override fixtures: \(count)")
    }

    private static let nodes: [(name: String, line: String)] = [
        ("🇭🇰 HK 01", "type: ss, server: 127.0.0.1, port: 8388, cipher: aes-128-gcm, password: fixture"),
        ("HK 02 游戏", "type: socks5, server: 127.0.0.1, port: 1080"),
        ("日本 东京", "type: trojan, server: 127.0.0.1, port: 443, password: fixture, sni: example.com, skip-cert-verify: true"),
        ("SG 03", "type: vmess, server: 127.0.0.1, port: 443, uuid: 11111111-2222-3333-4444-555555555555, alterId: 0, cipher: auto"),
        ("剩余流量：10 GB", "type: socks5, server: 127.0.0.1, port: 1"),
    ]

    private static var fixtures: [(String, String)] {
        let names = nodes.map(\.name)
        let flowProxies = nodes.map { "  - {name: \"\($0.name)\", \($0.line)}" }.joined(separator: "\n")
        let blockProxies = nodes.map { node in
            "- name: \(node.name)\n" + node.line.components(separatedBy: ", ").map { "  " + $0 }.joined(separator: "\n")
        }.joined(separator: "\n")
        let quotedMembers = names.map { "\"\($0)\"" }.joined(separator: ", ")
        let rules = "rules:\n  - DOMAIN-SUFFIX,example.com,节点选择\n  - MATCH,节点选择\n"

        let flow = """
        mixed-port: 0
        proxies:
        \(flowProxies)
        proxy-groups:
          - {name: 节点选择, type: select, proxies: [自动选择, \(quotedMembers), DIRECT]}
          - {name: 自动选择, type: url-test, url: "http://www.gstatic.com/generate_204", interval: 300, tolerance: 50, proxies: [\(quotedMembers)]}
          - {name: 故障转移, type: fallback, url: "http://www.gstatic.com/generate_204", interval: 300, proxies: [\(quotedMembers)]}
        \(rules)
        """

        let block = """
        mixed-port: 0
        # comment before the nodes
        proxies:
        \(blockProxies)
        proxy-groups:
        - name: 节点选择
          type: select
          proxies:
          - 自动选择
        \(names.map { "  - \($0)" }.joined(separator: "\n"))
        - name: 自动选择
          type: url-test
          url: http://www.gstatic.com/generate_204
          interval: 300 # seconds
          proxies:
        \(names.map { "    - \($0)" }.joined(separator: "\n"))
        \(rules)
        """

        let json: String = {
            let object: [String: Any] = [
                "mixed-port": 0,
                "proxies": nodes.map { node -> [String: Any] in
                    var entry: [String: Any] = ["name": node.name]
                    for field in node.line.components(separatedBy: ", ") {
                        let parts = field.components(separatedBy: ": ")
                        entry[parts[0]] = Int(parts[1]) ?? (parts[1] == "true" ? true : parts[1])
                    }
                    return entry
                },
                "proxy-groups": [
                    ["name": "节点选择", "type": "select", "proxies": ["自动选择"] + names],
                    ["name": "自动选择", "type": "url-test", "url": "http://www.gstatic.com/generate_204", "interval": 300, "proxies": names],
                ],
                "rules": ["DOMAIN-SUFFIX,example.com,节点选择", "MATCH,节点选择"],
            ]
            let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return String(decoding: data, as: UTF8.self)
        }()

        return [("flow", flow), ("block", block), ("json", json)]
    }
}
