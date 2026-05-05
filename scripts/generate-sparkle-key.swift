#!/usr/bin/env swift

// Generates a fresh Ed25519 keypair for Sparkle EdDSA appcast signing.
//
// Sparkle 2 verifies update payloads against an Ed25519 public key baked
// into the app's Info.plist (`SUPublicEDKey`). The matching private key
// signs each DMG before its appcast item is published; that signature
// is what stops an attacker who controls the GitHub Releases CDN from
// pushing a malicious binary. The key pair must be generated ONCE per
// product line and stored carefully — losing the private key means
// every future update has to be re-signed and shipped via a new app
// install (Sparkle won't accept signature rotation mid-stream).
//
// Run from the repo root:
//   swift scripts/generate-sparkle-key.swift
//
// The script writes the private key to `~/.dnp-sparkle-private-key`
// (chmod 600) and prints both halves to stdout. Copy the public key
// into `apps/DNPRemoteMac/project.yml` (Info.plist `SUPublicEDKey`) and
// add the private key to the GitHub Actions repo secret named
// `SPARKLE_PRIVATE_KEY`. After that, never check the private key into
// git.

import Foundation
import CryptoKit

let key = Curve25519.Signing.PrivateKey()
let privateKeyData = key.rawRepresentation
let publicKeyData = key.publicKey.rawRepresentation

let privateBase64 = privateKeyData.base64EncodedString()
let publicBase64 = publicKeyData.base64EncodedString()

let home = FileManager.default.homeDirectoryForCurrentUser
let privatePath = home.appendingPathComponent(".dnp-sparkle-private-key")

do {
    try privateBase64.write(to: privatePath, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                          ofItemAtPath: privatePath.path)
} catch {
    FileHandle.standardError.write(Data("ERROR: failed to write private key: \(error)\n".utf8))
    exit(1)
}

print("==> Generated Sparkle Ed25519 keypair")
print("Private key (KEEP SECRET — saved to \(privatePath.path)):")
print(privateBase64)
print("")
print("Public key (paste into project.yml SUPublicEDKey):")
print(publicBase64)
