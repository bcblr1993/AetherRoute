import Foundation
import CryptoKit
import Security

// Test infrastructure only. A path or recorded hash alone never authorizes code.
struct SignedNEPythonRuntime: Codable, Equatable, Sendable {
    static let policy = "apple-python-framework-v1"
    static let requirement = "identifier \"com.apple.python3\" and anchor apple"
    let schema: Int
    let policy: String
    let requirement: String
    let pythonPath: String
    let pythonSHA256: String
    let pythonCDHash: String
    let pythonVersion: String
    let frameworkPath: String
    let frameworkSHA256: String
    let frameworkCDHash: String
    let resourcesSHA256: String

    enum Failure: Error { case invalidRecord, invalidPath, invalidSignature, unsupportedVersion, changed }

    static func physical(_ path: String) throws -> String {
        guard path.hasPrefix("/"), !path.utf8.contains(0), let resolved = realpath(path, nil) else { throw Failure.invalidPath }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func hashFile(_ path: String, maximum: Int = 64 * 1024 * 1024) throws -> String {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.invalidPath }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size <= maximum,
              info.st_uid == 0 || info.st_uid == getuid(), info.st_mode & 0o022 == 0 else { throw Failure.invalidPath }
        var digest = SHA256(), buffer = [UInt8](repeating: 0, count: 65536), count = 0
        while true {
            let size = read(descriptor, &buffer, buffer.count)
            if size == 0 { break }
            if size < 0 && errno == EINTR { continue }
            guard size > 0, count + size <= maximum else { throw Failure.invalidPath }
            digest.update(data: Data(buffer.prefix(size))); count += size
        }
        guard count == info.st_size else { throw Failure.changed }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // Shape validation is pure and does not execute a proposed interpreter.
    static func layout(_ path: String) throws -> (framework: String, version: String) {
        guard path.hasPrefix("/"), path.utf8.count <= 4096, !path.utf8.contains(0),
              !path.contains("\n"), !path.contains("\r"), !path.contains("//") else { throw Failure.invalidPath }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 7, !parts.contains("."), !parts.contains(".."),
              parts[parts.count - 5] == "Python3.framework", parts[parts.count - 4] == "Versions",
              parts[parts.count - 2] == "bin" else { throw Failure.invalidPath }
        let version = String(parts[parts.count - 3])
        guard version.range(of: "^3\\.(9|1[0-4])$", options: .regularExpression) != nil,
              parts.last == Substring("python" + version) else { throw Failure.unsupportedVersion }
        return (parts.dropLast(4).joined(separator: "/"), version)
    }

    private static func verifiedCDHash(_ path: String, nested: Bool) throws -> String {
        var code: SecStaticCode?, requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              let code,
              SecRequirementCreateWithString(Self.requirement as CFString, [], &requirement) == errSecSuccess,
              let requirement else { throw Failure.invalidSignature }
        // Network access is deliberately not enabled. Validate every architecture
        // and all sealed framework resources, including nested executable code.
        var flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        if nested { flags.insert(SecCSFlags(rawValue: kSecCSCheckNestedCode)) }
        guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else { throw Failure.invalidSignature }
        var details: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &details) == errSecSuccess,
              let value = details as? [String: Any], value[kSecCodeInfoIdentifier as String] as? String == "com.apple.python3",
              let cdHash = value[kSecCodeInfoUnique as String] as? Data else { throw Failure.invalidSignature }
        return cdHash.map { String(format: "%02x", $0) }.joined()
    }

    static func inspect(pythonPath: String) throws -> Self {
        let shape = try layout(pythonPath)
        guard try physical(pythonPath) == pythonPath, try physical(shape.framework) == shape.framework,
              FileManager.default.isExecutableFile(atPath: pythonPath) else { throw Failure.invalidPath }
        let versionRoot = shape.framework + "/Versions/" + shape.version
        guard try physical(shape.framework + "/Versions/Current") == versionRoot,
              try physical(shape.framework + "/Python3") == versionRoot + "/Python3",
              try physical(shape.framework + "/Resources/Info.plist") == versionRoot + "/Resources/Info.plist"
        else { throw Failure.invalidPath }
        let executableHash = try hashFile(pythonPath, maximum: 8 * 1024 * 1024)
        let executableCDHash = try verifiedCDHash(pythonPath, nested: false)
        let frameworkCDHash = try verifiedCDHash(shape.framework, nested: true)
        let infoData = try Data(contentsOf: URL(fileURLWithPath: versionRoot + "/Resources/Info.plist"))
        guard infoData.count <= 65536,
              let info = try PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any],
              let version = info["CFBundleShortVersionString"] as? String,
              version.range(of: "^" + NSRegularExpression.escapedPattern(for: shape.version) + "\\.[0-9]+$", options: .regularExpression) != nil
        else { throw Failure.unsupportedVersion }
        let record = Self(schema: 1, policy: policy, requirement: requirement, pythonPath: pythonPath,
            pythonSHA256: executableHash, pythonCDHash: executableCDHash, pythonVersion: version,
            frameworkPath: shape.framework, frameworkSHA256: try hashFile(versionRoot + "/Python3"),
            frameworkCDHash: frameworkCDHash, resourcesSHA256: try hashFile(versionRoot + "/_CodeSignature/CodeResources"))
        guard try hashFile(pythonPath, maximum: 8 * 1024 * 1024) == executableHash else { throw Failure.changed }
        return record
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= 8192 else { throw Failure.invalidRecord }
        let record = try JSONDecoder().decode(Self.self, from: data)
        guard try record.encoded() == data, record.schema == 1, record.policy == policy, record.requirement == requirement,
              [record.pythonSHA256, record.frameworkSHA256, record.resourcesSHA256].allSatisfy({ $0.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil }),
              [record.pythonCDHash, record.frameworkCDHash].allSatisfy({ $0.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil }),
              try layout(record.pythonPath).framework == record.frameworkPath else { throw Failure.invalidRecord }
        return record
    }

    func validate() throws {
        guard try Self.inspect(pythonPath: pythonPath) == self else { throw Failure.changed }
    }
}
