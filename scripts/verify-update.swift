import Foundation
import CryptoKit

// Validate the exact ZIP against the app’s embedded public key, not merely the signing account.
do {
    guard CommandLine.arguments.count == 5 else { throw Failure.invalid }
    let args = CommandLine.arguments
    guard let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: args[1])), format: nil) as? [String: Any] else { throw Failure.invalid }
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: Data(base64Encoded: info["SUPublicEDKey"] as? String ?? "") ?? Data())
    let xml = try XMLDocument(contentsOf: URL(fileURLWithPath: args[2]))
    let items = try xml.nodes(forXPath: "/rss/channel/item")
    guard items.count == 1, let item = items.first as? XMLElement,
          let enclosure = item.elements(forName: "enclosure").first,
          let signature = Data(base64Encoded: enclosure.attribute(forName: "sparkle:edSignature")?.stringValue ?? ""),
          enclosure.attribute(forName: "url")?.stringValue == args[4] + URL(fileURLWithPath: args[3]).lastPathComponent,
          item.elements(forName: "sparkle:version").first?.stringValue == info["CFBundleVersion"] as? String,
          item.elements(forName: "sparkle:minimumSystemVersion").first?.stringValue == info["LSMinimumSystemVersion"] as? String,
          item.elements(forName: "sparkle:channel").isEmpty,
          try xml.nodes(forXPath: "//*[local-name()='deltas']").isEmpty else { throw Failure.invalid }
    let archive = try Data(contentsOf: URL(fileURLWithPath: args[3]))
    guard Int(enclosure.attribute(forName: "length")?.stringValue ?? "") == archive.count,
          key.isValidSignature(signature, for: archive) else { throw Failure.invalid }
    print("PASS appcast version, stable channel, URL, length, minimum OS, and Ed25519 signature")
} catch {
    fputs("Update validation failed. Do not publish this feed or archive.\n", stderr)
    exit(1)
}
enum Failure: Error { case invalid }
