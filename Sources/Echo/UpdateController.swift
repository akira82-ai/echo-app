import AppKit
import Sparkle
import SwiftUI

/// Configuration is injected into the distribution bundle, never inferred from a download URL.
struct UpdateConfiguration {
    let feedURL: URL
    let publicKey: String

    init?(info: [String: Any]) {
        guard let raw = info["SUFeedURL"] as? String, let url = URL(string: raw),
              url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
              url.fragment == nil,
              let key = info["SUPublicEDKey"] as? String,
              Data(base64Encoded: key)?.count == 32 else { return nil }
        feedURL = url
        publicKey = key
    }
}

/// Main-thread snapshot, shared with the configuration editor and the restart guard.
final class SettingsEditingState {
    static let shared = SettingsEditingState()
    var hasUnsavedChanges = false
}

final class UpdateController: NSObject, ObservableObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    static let shared = UpdateController()
    @Published private(set) var availableVersion: String?
    @Published private(set) var pendingRestart = false
    @Published private(set) var statusKey = "updates.unconfigured"
    @Published var automaticChecks: Bool = false {
        didSet { controller?.updater.automaticallyChecksForUpdates = automaticChecks }
    }
    private var controller: SPUStandardUpdaterController?
    private var installHandler: (() -> Void)?
    var configured: Bool { controller != nil }

    func start() {
        guard controller == nil,
              UpdateConfiguration(info: Bundle.main.infoDictionary ?? [:]) != nil else { return }
        let updater = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        controller = updater
        do {
            try updater.updater.start()
            updater.updater.automaticallyDownloadsUpdates = false
            automaticChecks = updater.updater.automaticallyChecksForUpdates
            statusKey = "updates.ready"
        } catch {
            controller = nil
            statusKey = "updates.startFailed"
        }
    }

    @objc func checkForUpdates() {
        guard let controller else {
            let alert = NSAlert()
            alert.messageText = L10n.text(statusKey)
            alert.informativeText = L10n.text("updates.configurationNote")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }
        if installHandler != nil { resumeInstallation(); return }
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }

    var supportsGentleScheduledUpdateReminders: Bool { true }
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool { false }
    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        availableVersion = update.displayVersionString
        statusKey = "updates.available"
    }
    func standardUserDriverWillFinishUpdateSession() {
        availableVersion = nil
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        // Do not log provider response bodies or URLs; Sparkle presents user-initiated failures.
        statusKey = (error as NSError).code == SUError.noUpdateError.rawValue ? "updates.current" : "updates.failed"
    }
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        self.installHandler = installHandler
        pendingRestart = true
        DispatchQueue.main.async { [weak self] in self?.resumeInstallation() }
        return true
    }

    private func resumeInstallation() {
        guard let handler = installHandler else { return }
        NSApp.activate(ignoringOtherApps: true)
        let blocked = QuickPanelController.shared.isAnswering || SettingsEditingState.shared.hasUnsavedChanges
        let alert = NSAlert()
        alert.messageText = L10n.text(blocked ? "updates.finishWork" : "updates.restartTitle")
        alert.informativeText = L10n.text(blocked ? "updates.finishWork.note" : "updates.restartNote")
        if blocked {
            alert.addButton(withTitle: L10n.text("updates.later"))
            alert.runModal()
            return
        }
        alert.addButton(withTitle: L10n.text("updates.restart"))
        alert.addButton(withTitle: L10n.text("updates.later"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // Recheck after the modal run loop before allowing Sparkle to terminate the app.
        guard !QuickPanelController.shared.isAnswering, !SettingsEditingState.shared.hasUnsavedChanges else { return }
        installHandler = nil
        pendingRestart = false
        handler()
    }
}

struct UpdateSettingsView: View {
    @ObservedObject private var updates = UpdateController.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L10n.text("updates.title")).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            SettingsCard {
                SettingsRow(title: L10n.text("updates.automatic"), subtitle: L10n.text("updates.manualInstall")) {
                    Toggle(L10n.text("updates.automatic"), isOn: $updates.automaticChecks)
                        .labelsHidden().toggleStyle(.switch).controlSize(.small).disabled(!updates.configured)
                }
                Divider()
                SettingsRow(title: updates.availableVersion.map { L10n.format("updates.versionAvailable", $0) } ?? L10n.text(updates.statusKey)) {
                    Button(L10n.text(updates.pendingRestart ? "updates.restart" : "updates.check")) { updates.checkForUpdates() }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
    }
}
