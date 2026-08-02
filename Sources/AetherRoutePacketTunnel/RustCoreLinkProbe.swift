enum RustCoreLinkProbe {
    /// Forces the release build to resolve the audited C ABI even before the
    /// provider starts a real packet session. Invalid input must fail closed.
    static func isLinked() -> Bool {
        clash_packet_input(nil, 0) == 0
    }
}
