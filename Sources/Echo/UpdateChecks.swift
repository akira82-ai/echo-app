import Foundation

func runUpdateChecks() -> Bool {
    let publicKey = Data(repeating: 1, count: 32).base64EncodedString()
    let valid: [String: Any] = ["SUFeedURL": "https://example.com/appcast.xml", "SUPublicEDKey": publicKey]
    guard UpdateConfiguration(info: valid) != nil else { return false }
    for feed in ["http://example.com/feed", "file:///tmp/feed", "https://user:password@example.com/feed", "https://example.com/feed#fragment", ""] {
        guard UpdateConfiguration(info: ["SUFeedURL": feed, "SUPublicEDKey": publicKey]) == nil else { return false }
    }
    for key in ["", "placeholder", Data(repeating: 1, count: 31).base64EncodedString()] {
        guard UpdateConfiguration(info: ["SUFeedURL": "https://example.com/feed", "SUPublicEDKey": key]) == nil else { return false }
    }
    guard UpdateConfiguration(info: [:]) == nil else { return false }
    print("PASS updater rejects missing keys, malformed keys, insecure feeds, credentials and fragments")
    return true
}
