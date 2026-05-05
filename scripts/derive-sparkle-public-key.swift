#!/usr/bin/env swift

// Re-derives the Sparkle public key from a base64-encoded Ed25519 private
// key passed on argv[1]. CI uses this so the workflow can carry a single
// secret (`SPARKLE_PRIVATE_KEY`) and compute the matching public key at
// release time, instead of having to keep both halves in sync manually.
//
// Usage:
//   swift scripts/derive-sparkle-public-key.swift "$SPARKLE_PRIVATE_KEY"
//
// Prints the base64 public key on stdout (no trailing newline guarantee
// from Swift's `print` is fine — the workflow trims when consuming).

import Foundation
import CryptoKit

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write(Data("Usage: derive-sparkle-public-key.swift <base64-private-key>\n".utf8))
    exit(1)
}

let raw = CommandLine.arguments[1].trimmingCharacters(in: .whitespacesAndNewlines)
guard let privateData = Data(base64Encoded: raw) else {
    FileHandle.standardError.write(Data("ERROR: argument is not valid base64\n".utf8))
    exit(1)
}

do {
    let key = try Curve25519.Signing.PrivateKey(rawRepresentation: privateData)
    print(key.publicKey.rawRepresentation.base64EncodedString())
} catch {
    FileHandle.standardError.write(Data("ERROR: not a valid Ed25519 private key: \(error)\n".utf8))
    exit(1)
}
