import AetherRouteKit
import Darwin
import Foundation

/// Builds the `FlowSourceApp` the engine receives for a transparent flow.
///
/// The signing identifier is `NEFlowMetaData.sourceAppSigningIdentifier`; the
/// path comes from the audit token's process via `proc_pidpath`, which is
/// allowed in the sandboxed extension. Either may be missing — system daemons
/// often have no audit token, and a process can exit before it is looked up.
public enum TransparentProxySourceAppResolver {
    public static func sourceApp(
        for evaluation: TransparentProxySelfIdentityGuard.Evaluation
    ) -> FlowSourceApp? {
        FlowSourceApp(
            signingIdentifier: evaluation.signingIdentifier,
            executablePath: executablePath(
                for: evaluation.sourceProcessIdentifier
            )
        )
    }

    static func executablePath(for pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        // PROC_PIDPATHINFO_MAXSIZE (4 * MAXPATHLEN) is not imported as a
        // Swift constant.
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let path = String(
            decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        return path.hasPrefix("/") ? path : nil
    }
}
