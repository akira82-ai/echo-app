import Foundation
import Sparkle

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
    let driver = UpdateController()
    driver.isBlocked = { false }
    var installs = 0
    driver.showDownloadInitiated(cancellation: {})
    driver.showDownloadDidReceiveExpectedContentLength(200)
    driver.showDownloadDidReceiveData(ofLength: 50)
    guard driver.phase == .downloading, driver.progress == 25 else { return false }
    driver.showDownloadDidReceiveData(ofLength: UInt64.max)
    guard driver.progress == 100 else { return false }
    driver.showDownloadDidStartExtractingUpdate()
    guard driver.phase == .verifying else { return false }
    driver.showReady(toInstallAndRelaunch: { _ in installs += 1 })
    guard driver.phase == .ready, installs == 0 else { return false }
    driver.isBlocked = { true }
    driver.checkForUpdates()
    guard driver.phase == .blocked, installs == 0 else { return false }
    driver.isBlocked = { false }
    driver.checkForUpdates(); driver.checkForUpdates()
    guard driver.phase == .installing, installs == 1 else { return false }
    driver.showUpdaterError(NSError(domain: SUSparkleErrorDomain, code: 4005), acknowledgement: {})
    guard driver.phase == .failed, driver.statusKey == "updates.inline.installFailed" else { return false }
    driver.dismissUpdateInstallation()
    guard driver.phase == .failed else { return false }
    let item = SUAppcastItem(dictionary: ["title": "2.19.0", "sparkle:version": "34", "sparkle:shortVersionString": "2.19.0", "enclosure": ["url": "https://example.com/Echo.zip", "length": "100", "type": "application/octet-stream"]])
    if let item {
        var postponed = 0
        driver.isBlocked = { true }
        guard driver.updater(SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: driver), shouldPostponeRelaunchForUpdate: item, untilInvokingBlock: { postponed += 1 }) else { return false }
        driver.checkForUpdates()
        guard postponed == 0 else { return false }
        driver.isBlocked = { false }; driver.checkForUpdates(); driver.checkForUpdates()
        guard postponed == 1 else { return false }
    } else { return false }
    print("PASS inline update progress, explicit install, safety guards, single-use callbacks and failure preservation")
    return true
}
