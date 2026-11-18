// Disposable integration app using Echo's production UpdateController.
import AppKit
import Sparkle

@main
final class UpdateHarness: NSObject, NSApplicationDelegate {
    private let driver = UpdateController()
    private var updater: SPUUpdater!
    private var timer: Timer?
    private var previous: UpdatePhase?
    private var availableSince: Date?
    private var readySince: Date?
    private let started = Date()
    private var root: URL { URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "UpdateTestRoot") as! String) }
    private func log(_ value: String) {
        let path = root.appendingPathComponent("events.txt")
        if !FileManager.default.fileExists(atPath: path.path) { FileManager.default.createFile(atPath: path.path, contents: nil) }
        do {
            let file = try FileHandle(forWritingTo: path)
            defer { try? file.close() }
            try file.seekToEnd(); try file.write(contentsOf: Data((value + "\n").utf8))
        } catch { fatalError("Cannot write integration evidence: \(error)") }
    }
    static func main() {
        let app = NSApplication.shared, delegate = UpdateHarness()
        app.delegate = delegate; app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as! String
        log("START \(version)")
        if version == "2" { log("SUCCESS NEW VERSION"); NSApp.terminate(nil); return }
        driver.isBlocked = { false }
        // Loopback HTTP is confined to the fixture; production start requires HTTPS.
        updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: driver)
        do { try updater.start(); updater.checkForUpdatesInBackground() }
        catch { log("ERROR START"); NSApp.terminate(nil) }
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
    }
    private func tick() {
        if Date().timeIntervalSince(started) > 40 { log("ERROR TIMEOUT"); NSApp.terminate(nil); return }
        if previous != driver.phase { log("PHASE \(driver.phase) \(driver.statusKey)"); previous = driver.phase }
        switch driver.phase {
        case .available:
            guard let availableSince else { availableSince = Date(); log("WAITING FOR DOWNLOAD CLICK"); return }
            if Date().timeIntervalSince(availableSince) > 0.5 { driver.checkForUpdates() }
        case .ready:
            guard let readySince else {
                readySince = Date()
                driver.isBlocked = { true }; driver.checkForUpdates()
                guard driver.phase == .blocked else { log("ERROR RESTART GUARD"); NSApp.terminate(nil); return }
                log("BLOCKED RESTART VERIFIED")
                return
            }
            if Date().timeIntervalSince(readySince) > 0.5 { driver.isBlocked = { false }; driver.checkForUpdates() }
        case .blocked:
            if let readySince, Date().timeIntervalSince(readySince) > 0.5 { driver.isBlocked = { false }; driver.checkForUpdates() }
        case .failed:
            log("REJECTED \(driver.statusKey)"); NSApp.terminate(nil)
        default: break
        }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        log("TERMINATE"); return .terminateNow
    }
}
