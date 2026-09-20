import Foundation
import OSLog

/// Unified logging subsystem and category definitions for AetherRoute.
///
/// Standardizes all logging across the main application, network extensions,
/// core engine bridges, and kit frameworks under one searchable subsystem hierarchy:
/// `subsystem: "com.aetherroute.desktop"`.
public enum AppLog {
    /// The common logging subsystem for the entire product family.
    public static let subsystem = "com.aetherroute.desktop"

    /// Standardized, hierarchical category names.
    public enum Category {
        // App Categories
        public static let appRuntime = "app.runtime"
        public static let appLifecycle = "app.lifecycle"
        public static let appActivation = "app.activation"

        // Tunnel Categories
        public static let tunnelRuntime = "tunnel.runtime"
        public static let tunnelCore = "tunnel.core-bridge"

        // Transparent Proxy Categories
        public static let proxyRuntime = "proxy.runtime"
        public static let proxyBudget = "proxy.budget"
        public static let proxyInput = "proxy.input"

        // Flow Core Engine
        public static let flowEngine = "engine.flow-core"

        // Kit Store & Diagnostics Categories
        public static let profileKeys = "kit.profile-keys"
        public static let activeProfile = "kit.active-profile"
        public static let diagnostics = "kit.diagnostics"
        public static let cloudSync = "kit.cloud-sync"
    }

    /// Creates an `os.Logger` bound to the standard subsystem and specified category.
    public static func logger(category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }
}
