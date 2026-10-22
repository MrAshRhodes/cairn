import CryptoKit
import Foundation

// Throwaway Ed25519 key pair for release-pipeline tests: the base64 private seed, then the base64 public key.
// The pair exists only in the caller's memory and never signs a real release.
let key = Curve25519.Signing.PrivateKey()
print(key.rawRepresentation.base64EncodedString())
print(key.publicKey.rawRepresentation.base64EncodedString())
