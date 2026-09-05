import Foundation

// Offline consumer interoperability check. Uses the exact prepared UI helper;
// it validates inputs only and never invokes run(), curl, an App or a provider.
@main
struct SwiftInputConsumer {
    static func main() {
        let env = ProcessInfo.processInfo.environment
        guard env["AETHERROUTE_SIGNED_PROBE_KIND"] == "controlled-relay-v1",
              env["AETHERROUTE_SIGNED_PROBE_URL"] == nil,
              env["AETHERROUTE_SIGNED_PROBE_SHA256"] == nil,
              let path = env["AETHERROUTE_SIGNED_PROBE_BINDINGS"],
              let sha = env["AETHERROUTE_SIGNED_PROBE_BINDINGS_SHA256"],
              let run = env["AETHERROUTE_SIGNED_NE_RUN_ID"],
              let candidate = env["AETHERROUTE_SIGNED_NE_CANDIDATE_MANIFEST_SHA256"],
              let engine = env["AETHERROUTE_SIGNED_NE_ENGINE"].flatMap(SignedNEProbeEngine.init(rawValue:)),
              let cycles = env["AETHERROUTE_SIGNED_NE_CYCLES"].flatMap(Int.init) else { exit(1) }
        do {
            let values = try SignedNEProbe.loadCycleBindings(path: path, sha256: sha, runID: run,
                                                            candidateSHA256: candidate, engine: engine, cycles: cycles)
            print("controlled_swift_bindings=\(values.count)")
        } catch { exit(1) }
    }
}
