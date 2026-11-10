/// Reuse only the exact enabled extension shipped with this app. Disabled,
/// unapproved, retiring, or different-version installations still need the
/// normal macOS activation and authorization flow.
public enum SystemExtensionActivationPolicy {
    public struct Version: Equatable, Sendable {
        public let identifier: String
        public let build: String
        public let release: String

        public init(identifier: String, build: String, release: String) {
            self.identifier = identifier
            self.build = build
            self.release = release
        }
    }

    public struct Installation: Sendable {
        public let version: Version
        public let isEnabled: Bool
        public let isAwaitingUserApproval: Bool
        public let isUninstalling: Bool

        public init(
            version: Version,
            isEnabled: Bool,
            isAwaitingUserApproval: Bool,
            isUninstalling: Bool
        ) {
            self.version = version
            self.isEnabled = isEnabled
            self.isAwaitingUserApproval = isAwaitingUserApproval
            self.isUninstalling = isUninstalling
        }
    }

    public static func canReuse(
        expected: Version,
        installations: [Installation]
    ) -> Bool {
        guard !expected.identifier.isEmpty,
              !expected.build.isEmpty,
              !expected.release.isEmpty else { return false }
        return installations.contains {
            $0.version == expected && $0.isEnabled
                && !$0.isAwaitingUserApproval && !$0.isUninstalling
        }
    }

    /// True when the extension was deactivated in this boot session
    /// (`[terminated waiting to uninstall on reboot]`) and no enabled copy of it
    /// remains. Once an extension is deactivated in the current boot session,
    /// macOS `sysextd` / `LoginItems.appex` cannot re-enable that bundle
    /// identifier until the Mac restarts (whereas an in-place upgrade over an
    /// already-enabled older build still has `isEnabled == true` on the older
    /// entry and does not require a prior restart).
    public static func requiresRebootBeforeReinstall(
        expected: Version,
        installations: [Installation]
    ) -> Bool {
        guard !expected.identifier.isEmpty,
              !expected.build.isEmpty,
              !expected.release.isEmpty,
              !canReuse(expected: expected, installations: installations) else {
            return false
        }
        let matching = installations.filter {
            $0.version.identifier == expected.identifier
        }
        let hasActiveEnabled = matching.contains {
            $0.isEnabled && !$0.isAwaitingUserApproval && !$0.isUninstalling
        }
        guard !hasActiveEnabled else { return false }
        return matching.contains(where: \.isUninstalling)
    }
}
