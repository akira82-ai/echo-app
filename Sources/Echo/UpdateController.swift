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

enum UpdatePhase: Equatable {
    case idle, checking, current, available, downloading, verifying, ready, blocked, installing, failed
}

/// Sparkle invokes its user-driver callbacks on the main thread. No update windows are created.
final class UpdateController: NSObject, ObservableObject, SPUUpdaterDelegate, SPUUserDriver {
    static let shared = UpdateController()
    @Published private(set) var phase: UpdatePhase = .idle
    @Published private(set) var availableVersion: String?
    @Published private(set) var statusKey = "updates.unconfigured"
    @Published private(set) var receivedBytes: UInt64 = 0
    @Published private(set) var expectedBytes: UInt64 = 0
    @Published var automaticChecks = false {
        didSet { updater?.automaticallyChecksForUpdates = automaticChecks }
    }
    private var updater: SPUUpdater?
    private var downloadChoice: ((SPUUserUpdateChoice) -> Void)?
    private var installChoice: ((SPUUserUpdateChoice) -> Void)?
    private var postponedInstall: (() -> Void)?
    private var retryTermination: (() -> Void)?
    private var resetWork: DispatchWorkItem?
    private var informationOnly = false
    var isBlocked: () -> Bool = { QuickPanelController.shared.isAnswering || SettingsEditingState.shared.hasUnsavedChanges }
    var configured: Bool { updater != nil }
    var pendingRestart: Bool { phase == .ready || phase == .blocked }
    var isWorking: Bool { [.checking, .downloading, .verifying, .installing].contains(phase) }
    var progress: Int? {
        guard expectedBytes > 0 else { return nil }
        return Int(min(100, Double(receivedBytes) / Double(expectedBytes) * 100))
    }
    var label: String {
        switch phase {
        case .idle: return "v" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
        case .downloading: return progress.map { L10n.format("updates.inline.progress", String($0)) } ?? L10n.text("updates.inline.downloading")
        default: return L10n.text(statusKey)
        }
    }
    var detail: String {
        if phase == .ready { return L10n.text("updates.restartNote") }
        if phase == .blocked { return L10n.text("updates.finishWork.note") }
        if !configured { return L10n.text(statusKey) }
        return availableVersion.map { L10n.format("updates.versionAvailable", $0) } ?? L10n.text(statusKey)
    }
    private func transition(_ next: UpdatePhase, _ key: String) {
        resetWork?.cancel(); resetWork = nil
        phase = next; statusKey = key
    }
    func start() {
        guard updater == nil, UpdateConfiguration(info: Bundle.main.infoDictionary ?? [:]) != nil else { return }
        let engine = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
        updater = engine
        do {
            try engine.start()
            engine.automaticallyDownloadsUpdates = false
            automaticChecks = engine.automaticallyChecksForUpdates
            statusKey = "updates.ready"
            if automaticChecks { engine.checkForUpdatesInBackground() }
        } catch {
            updater = nil
            transition(.failed, "updates.startFailed")
        }
    }
    /// All entry points perform the action shown in the single inline control.
    @objc func checkForUpdates() {
        if phase == .available {
            guard !informationOnly, let choice = downloadChoice else { return }
            downloadChoice = nil
            transition(.downloading, "updates.inline.downloading")
            choice(.install)
        } else if pendingRestart {
            restart()
        } else {
            guard !isWorking else { return }
            guard let updater else { transition(.failed, "updates.unconfigured"); return }
            guard updater.canCheckForUpdates else { return }
            transition(.checking, "updates.inline.checking")
            updater.checkForUpdates()
        }
    }
    private func restart() {
        guard !isBlocked() else { transition(.blocked, "updates.inline.blocked"); return }
        if let handler = postponedInstall {
            postponedInstall = nil; transition(.installing, "updates.inline.installing"); handler()
        } else if let reply = installChoice {
            installChoice = nil; transition(.installing, "updates.inline.installing"); reply(.install)
        } else if let retry = retryTermination {
            retryTermination = nil; transition(.installing, "updates.inline.installing"); retry()
        }
    }
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: automaticChecks, sendSystemProfile: false))
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { transition(.checking, "updates.inline.checking") }
    func showUpdateFound(with item: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        availableVersion = item.displayVersionString
        informationOnly = item.isInformationOnlyUpdate
        if informationOnly {
            reply(.dismiss)
            transition(.failed, "updates.inline.manual")
        } else if state.stage == .installing {
            installChoice = reply; transition(.ready, "updates.inline.install")
        } else {
            downloadChoice = reply; transition(.available, "updates.inline.available")
        }
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        let reason = (error as NSError).userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber
        let latest = reason.map { $0.intValue == Int(SPUNoUpdateFoundReason.onLatestVersion.rawValue) || $0.intValue == Int(SPUNoUpdateFoundReason.onNewerThanLatestVersion.rawValue) } ?? false
        transition(latest ? .current : .failed, latest ? "updates.inline.current" : "updates.inline.incompatible")
        acknowledgement()
        if latest {
            let work = DispatchWorkItem { [weak self] in self?.transition(.idle, "updates.ready") }
            resetWork = work; DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
        }
    }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) { fail(error); acknowledgement() }
    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        receivedBytes = 0; expectedBytes = 0; transition(.downloading, "updates.inline.downloading")
    }
    func showDownloadDidReceiveExpectedContentLength(_ length: UInt64) { expectedBytes = length }
    func showDownloadDidReceiveData(ofLength length: UInt64) {
        let (sum, overflow) = receivedBytes.addingReportingOverflow(length)
        receivedBytes = overflow ? UInt64.max : sum
    }
    func showDownloadDidStartExtractingUpdate() { transition(.verifying, "updates.inline.verifying") }
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        installChoice = reply; transition(.ready, "updates.inline.install")
    }
    func showInstallingUpdate(withApplicationTerminated terminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        if !terminated { retryTermination = retryTerminatingApplication }
        transition(.installing, "updates.inline.installing")
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        transition(.idle, "updates.ready"); acknowledgement()
    }
    func dismissUpdateInstallation() {
        downloadChoice = nil; installChoice = nil; postponedInstall = nil; retryTermination = nil
        availableVersion = nil
        if ![.failed, .current].contains(phase) { transition(.idle, "updates.ready") }
    }
    func showUpdateInFocus() {}
    private func fail(_ error: Error) {
        guard phase != .failed else { return }
        let key: String
        switch phase {
        case .downloading: key = "updates.inline.downloadFailed"
        case .verifying: key = "updates.inline.verifyFailed"
        case .installing, .ready, .blocked: key = "updates.inline.installFailed"
        default: key = "updates.inline.checkFailed"
        }
        downloadChoice = nil; installChoice = nil; postponedInstall = nil; retryTermination = nil
        transition(.failed, key)
        let failure = error as NSError
        NSLog("Echo updater failed: domain=%@ code=%ld", failure.domain, failure.code)
    }
    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let failure = error as NSError
        if failure.domain == SUSparkleErrorDomain && failure.code == SUError.noUpdateError.rawValue { return }
        fail(error)
    }
    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock handler: @escaping () -> Void) -> Bool {
        guard isBlocked() else { return false }
        postponedInstall = handler; transition(.blocked, "updates.inline.blocked"); return true
    }
}

struct InlineUpdateButton: View {
    @ObservedObject private var updates = UpdateController.shared
    private var highlighted: Bool { [.available, .downloading, .verifying, .ready, .installing].contains(updates.phase) }
    private var warning: Bool { [.failed, .blocked].contains(updates.phase) }
    var body: some View {
        Button(action: updates.checkForUpdates) {
            HStack(spacing: 4) {
                if highlighted || warning { Circle().fill(highlighted ? Color.green : Color.orange).frame(width: 4, height: 4) }
                Text(updates.label).monospacedDigit()
            }
            .font(.system(size: 10))
            .padding(.horizontal, highlighted || warning ? 6 : 0).padding(.vertical, 3)
            .background(highlighted ? Color.green.opacity(0.10) : warning ? Color.orange.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(highlighted ? Color.green.opacity(0.22) : .clear, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .foregroundStyle(highlighted ? Color.green : warning ? Color.orange : Color.secondary)
        .disabled(updates.isWorking)
        .help(updates.detail)
        .accessibilityLabel(updates.label + ". " + updates.detail)
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
                SettingsRow(title: updates.detail) {
                    Button(updates.phase == .idle ? L10n.text("updates.check") : updates.label) { updates.checkForUpdates() }
                        .buttonStyle(.bordered).controlSize(.small).disabled(updates.isWorking)
                }
            }
        }
    }
}
