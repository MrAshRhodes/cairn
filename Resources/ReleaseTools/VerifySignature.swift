import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    fputs("ERROR: \(message)\n", stderr)
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    fail("Expected public Ed25519 key, signature and archive path, or --feed public-key appcast.xml")
}
let isFeed = arguments[1] == "--feed"
guard let key = Data(base64Encoded: arguments[isFeed ? 2 : 1]), key.count == 32 else {
    fail("Invalid public key")
}
let file = try Data(contentsOf: URL(fileURLWithPath: arguments[3]), options: .mappedIfSafe)
let content: Data
let signatureText: String
if isFeed {
    let marker = Data("<!-- sparkle-signatures:\n".utf8)
    guard let start = file.range(of: marker, options: .backwards),
          let block = String(data: file[start.lowerBound...], encoding: .utf8) else {
        fail("Signed feed trailer is missing")
    }
    let fields = block.components(separatedBy: "\n")
    guard fields.count == 5, fields[1].hasPrefix("edSignature: "), fields[2].hasPrefix("length: "),
          fields[3] == "-->", fields[4].isEmpty,
          Int(fields[2].dropFirst("length: ".count)) == start.lowerBound else {
        fail("Signed feed trailer or content length is invalid")
    }
    content = file.prefix(start.lowerBound)
    signatureText = String(fields[1].dropFirst("edSignature: ".count))
} else {
    content = file
    signatureText = arguments[2]
}
guard let signature = Data(base64Encoded: signatureText), signature.count == 64 else {
    fail("Invalid Ed25519 signature")
}
let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: key)
guard publicKey.isValidSignature(signature, for: content) else {
    fail("Signature does not match the public key in Cairn.app")
}
print("\(isFeed ? "Feed" : "Archive") Ed25519 signature verified against bundled public key.")
