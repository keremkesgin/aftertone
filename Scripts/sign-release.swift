#!/usr/bin/env swift
import CryptoKit
import Foundation

// Signs a release zip with the maintainer's Ed25519 private key, for
// `UpdateChecker`/`UpdateManifest` to verify against the public key baked into the app.
//
// The private key never lives in this repo. Run with:
//   swift Scripts/sign-release.swift <path-to-zip> <path-to-private-key-b64>
// and paste the printed signature into updates/appcast.json's "sha256Signature" field
// (the field name is a holdover from an earlier checksum-only design; it now holds an
// Ed25519 signature, not a hash — see UpdateManifest).

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(
        Data("usage: sign-release.swift <zip-path> <private-key-b64-path>\n".utf8))
    exit(1)
}

let zipURL = URL(fileURLWithPath: arguments[1])
let keyPath = arguments[2]

guard let keyString = try? String(contentsOfFile: keyPath, encoding: .utf8),
      let keyData = Data(base64Encoded: keyString.trimmingCharacters(in: .whitespacesAndNewlines)),
      let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: keyData)
else {
    FileHandle.standardError.write(Data("could not read/parse private key\n".utf8))
    exit(1)
}

guard let zipData = try? Data(contentsOf: zipURL) else {
    FileHandle.standardError.write(Data("could not read zip at \(zipURL.path)\n".utf8))
    exit(1)
}

guard let signature = try? privateKey.signature(for: zipData) else {
    FileHandle.standardError.write(Data("signing failed\n".utf8))
    exit(1)
}

print(signature.base64EncodedString())
