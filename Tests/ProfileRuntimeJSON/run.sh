#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-runtime-json.XXXXXX")
trap 'find "$WORK" -depth -delete' EXIT HUP INT TERM
cat > "$WORK/main.swift" <<'SWIFT'
import Foundation

@main struct JSONRuntimeRegression {
    static func mapping(_ text: String) throws -> NSDictionary {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ruby")
        process.arguments = ["-ryaml", "-rjson", "-e", "STDOUT.write(JSON.generate(YAML.safe_load(STDIN.read, aliases: true)))"]
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: Data(text.utf8))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let object = try JSONSerialization.jsonObject(with: data) as? NSDictionary else {
            throw NSError(domain: "RuntimeJSONRegression", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Runtime rewrite produced invalid YAML"])
        }
        return object
    }
    static func main() throws {
        let raw = #"{"dns":{"enable":true,"nameserver":["1.1.1.1"]},"proxies":[{"name":"test:#node","type":"ss","server":"example.invalid","port":443,"cipher":"aes-128-gcm","password":"SYNTHETIC:#\"secret\nline","udp":true,"plugin-opts":{"host":"x:#y","nested":[null,false,17,{"quoted:key":"text"}]}}],"proxy-groups":[{"name":"Proxy","type":"select","proxies":["test:#node"]}],"rules":["MATCH,Proxy"]}"#
        let profile = ActiveProfile(name: "JSON", yaml: raw)
        let original = try mapping(raw)
        for (label, text) in [
            ("optimization-off", profile.runtimeYAML),
            ("optimization-on", DomesticRoutingOptimizer.optimizedProfile(for: profile.runtimeYAML)),
            ("direct-optimizer", DomesticRoutingOptimizer.optimizedProfile(for: raw))
        ] {
            let result = try mapping(text)
            precondition((result["proxies"] as! NSArray).isEqual(original["proxies"]), "Proxy options changed")
            precondition((result["proxy-groups"] as! NSArray).isEqual(original["proxy-groups"]), "Group members changed")
            if label != "optimization-off" {
                precondition((result["dns"] as? NSDictionary)?["enhanced-mode"] as? String == "fake-ip")
                precondition((result["rules"] as? [String])?.last == "MATCH,Proxy")
            }
            print("PASS: JSON runtime \(label), YAML parses and nested values round-trip")
        }
        precondition(profile.yaml == raw, "Imported source was changed")
    }
}
SWIFT
swiftc -parse-as-library -swift-version 6 -warnings-as-errors \
  "$ROOT"/Sources/AetherRouteKit/*.swift "$WORK/main.swift" -o "$WORK/regression"
"$WORK/regression"
