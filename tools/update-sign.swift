// Signs release DMGs for the in-app updater (Ed25519, CryptoKit). The private key stays outside the repo.
//   update-sign --generate <key file>     new key pair: writes the private key (mode 600), prints the public key (base64)
//   update-sign --public <key file>       prints the public key of an existing private key
//   update-sign --sign <key file> <file>  writes <file>.sig: the base64 signature of the file's bytes
//   update-sign --verify <public key> <file> <sig file>   exit 0 if the signature is good
import CryptoKit
import Foundation

func fail(_ s: String) -> Never { FileHandle.standardError.write(Data((s + "\n").utf8)); exit(1) }
func key(_ path: String) -> Curve25519.Signing.PrivateKey {
    guard let s = try? String(contentsOfFile: path, encoding: .utf8), let d = Data(base64Encoded: s.trimmingCharacters(in: .whitespacesAndNewlines)),
          let k = try? Curve25519.Signing.PrivateKey(rawRepresentation: d) else { fail("can't read the private key at \(path)") }
    return k
}
let a = CommandLine.arguments
switch a.count > 1 ? a[1] : "" {
case "--generate":
    guard a.count == 3 else { fail("usage: --generate <key file>") }
    let path = a[2]
    if FileManager.default.fileExists(atPath: path) { fail("\(path) exists: not overwriting a signing key") }
    try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let k = Curve25519.Signing.PrivateKey()
    guard FileManager.default.createFile(atPath: path, contents: Data(k.rawRepresentation.base64EncodedString().utf8), attributes: [.posixPermissions: 0o600]) else { fail("can't write \(path)") }
    print(k.publicKey.rawRepresentation.base64EncodedString())
case "--public":
    print(key(a[2]).publicKey.rawRepresentation.base64EncodedString())
case "--sign":
    guard a.count == 4, let data = FileManager.default.contents(atPath: a[3]) else { fail("usage: --sign <key file> <file>") }
    let sig = try! key(a[2]).signature(for: data)
    try! Data(sig.base64EncodedString().utf8).write(to: URL(fileURLWithPath: a[3] + ".sig"))
case "--verify":
    guard a.count == 5, let pk = Data(base64Encoded: a[2]), let k = try? Curve25519.Signing.PublicKey(rawRepresentation: pk),
          let data = FileManager.default.contents(atPath: a[3]), let s = try? String(contentsOfFile: a[4], encoding: .utf8),
          let sig = Data(base64Encoded: s.trimmingCharacters(in: .whitespacesAndNewlines)) else { fail("usage: --verify <public key> <file> <sig file>") }
    exit(k.isValidSignature(sig, for: data) ? 0 : 1)
default: fail("usage: update-sign --generate|--public|--sign|--verify ...")
}
