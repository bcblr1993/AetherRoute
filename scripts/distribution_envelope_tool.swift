import CryptoKit
import Foundation

private struct Envelope: Codable {
    let payload: String
    let signature: String
}

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(1)
}

private func read(_ path: String, expectedBytes: Int? = nil) -> Data {
    guard let data = FileManager.default.contents(atPath: path) else {
        fail("could not read file: \(path)")
    }
    if let expectedBytes, data.count != expectedBytes {
        fail("file must contain exactly \(expectedBytes) bytes: \(path)")
    }
    return data
}

private func write(_ data: Data, to path: String) {
    guard !FileManager.default.fileExists(atPath: path) else {
        fail("refusing to overwrite existing output: \(path)")
    }
    do {
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    } catch {
        fail("could not write output: \(path)")
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else {
    fail("usage: distribution_envelope_tool.swift public-key|sign|verify ...")
}

do {
    switch command {
    case "public-key":
        guard arguments.count == 3 else {
            fail("usage: public-key private-key.raw public-key.raw")
        }
        let privateKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: read(arguments[1], expectedBytes: 32)
        )
        write(privateKey.publicKey.rawRepresentation, to: arguments[2])

    case "sign":
        guard arguments.count == 4 else {
            fail("usage: sign private-key.raw payload.json envelope.json")
        }
        let privateKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: read(arguments[1], expectedBytes: 32)
        )
        let payload = read(arguments[2])
        guard !payload.isEmpty, payload.count <= 32 * 1_024 else {
            fail("payload must contain 1...32768 bytes")
        }
        let envelope = Envelope(
            payload: payload.base64EncodedString(),
            signature: try privateKey.signature(for: payload)
                .base64EncodedString()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        write(try encoder.encode(envelope), to: arguments[3])

    case "verify":
        guard arguments.count == 4 else {
            fail("usage: verify public-key.raw envelope.json payload-output.json")
        }
        let publicKey = try Curve25519.Signing.PublicKey(
            rawRepresentation: read(arguments[1], expectedBytes: 32)
        )
        let envelopeData = read(arguments[2])
        guard envelopeData.count <= 64 * 1_024,
              let envelope = try? JSONDecoder().decode(
                  Envelope.self,
                  from: envelopeData
              ),
              let payload = Data(base64Encoded: envelope.payload),
              let signature = Data(base64Encoded: envelope.signature),
              !payload.isEmpty,
              payload.count <= 32 * 1_024,
              signature.count == 64,
              publicKey.isValidSignature(signature, for: payload)
        else {
            fail("envelope verification failed")
        }
        write(payload, to: arguments[3])

    default:
        fail("unknown command: \(command)")
    }
} catch {
    fail("distribution envelope operation failed: \(error.localizedDescription)")
}
