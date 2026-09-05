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
}
