import AppKit
@preconcurrency import Sparkle
import SwiftUI
@preconcurrency import UserNotifications

/// Application entry object: builds the dependency graph, registers the
/// global hotkey, owns the status item and windows.
@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate, SPUUpdaterDelegate,
    @preconcurrency SPUStandardUserDriverDelegate,
    @preconcurrency UNUserNotificationCenterDelegate {
    private var settings: SettingsStore!
    private var permissions: PermissionsService!
    private var modelManager: ModelManager!
    private var hotkeys: HotkeyManager!
    private var dictation: DictationController!
    private var overlay: OverlayWindowController!
    private var statusItem: StatusItemController!
    private var deps: SettingsDependencies!
    private var updaterController: SPUStandardUpdaterController!

    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var fileTranscriptionWindow: NSWindow?
    private var fileTranscriptionController: FileTranscriptionController?

    public override init() {
        super.init()
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self)
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        settings = SettingsStore()
        L10n.setLanguage(settings.interfaceLanguage)
        Log.shared.level = settings.logLevel
        Log.shared.info("VoxLocal starting (v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"))")
        UNUserNotificationCenter.current().delegate = self

        permissions = PermissionsService()
        modelManager = ModelManager()
        hotkeys = HotkeyManager()

        dictation = DictationController(
            settings: settings,
            permissions: permissions,
            recorder: AudioRecorder(),
            transcriber: WhisperTranscriber(),
            modelManager: modelManager,
            inserter: TextInserter(),
            hotkeys: hotkeys)

        overlay = OverlayWindowController(dictation: dictation)

        deps = SettingsDependencies(
            settings: settings,
            modelManager: modelManager,
            permissions: permissions,
            dictation: dictation,
            applyHotkey: { [weak self] combo in
                self?.registerHotkey(combo)
            })

        statusItem = StatusItemController(
            dictation: dictation,
            modelManager: modelManager,
            openSettings: { [weak self] in self?.showSettings() },
            openFileTranscription: { [weak self] in self?.showFileTranscription() },
            checkForUpdates: { [weak self] in self?.updaterController.checkForUpdates(nil) },
            canCheckForUpdates: { [weak self] in
                self?.updaterController.updater.canCheckForUpdates ?? false
            })

        hotkeys.onMainKeyDown = { [weak self] in self?.dictation.handleHotkeyDown() }
        hotkeys.onMainKeyUp = { [weak self] in self?.dictation.handleHotkeyUp() }
        hotkeys.onEscape = { [weak self] in self?.dictation.cancelDictation() }

        let combo = KeyCombo(keyCode: settings.hotkeyKeyCode, modifiers: settings.hotkeyModifiers)
        if let error = registerHotkey(combo) {
            showHotkeyConflictAlert(message: error)
        }

        if !settings.onboardingCompleted {
            showOnboarding()
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        dictation?.cancelDictation()
        hotkeys?.unregisterMainHotkey()
        hotkeys?.unregisterEscape()
        Log.shared.info("VoxLocal terminating")
        Log.shared.sync()
    }

    // MARK: - Updates

    public var supportsGentleScheduledUpdateReminders: Bool { true }

    public func updater(_ updater: SPUUpdater, willScheduleUpdateCheckAfterDelay delay: TimeInterval) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error {
                Log.shared.error("update notification permission failed: \(error.localizedDescription)")
            }
        }
    }

    public func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        NSApp.setActivationPolicy(.regular)
        guard !state.userInitiated else { return }

        let content = UNMutableNotificationContent()
        content.title = L10n.t("update.notification.title")
        content.body = L10n.t("update.notification.body", update.displayVersionString)
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "VoxLocalUpdate",
            content: content,
            trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    public func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["VoxLocalUpdate"])
    }

    public func standardUserDriverWillFinishUpdateSession() {
        NSApp.setActivationPolicy(.accessory)
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.notification.request.identifier == "VoxLocalUpdate" {
            updaterController.checkForUpdates(nil)
        }
        completionHandler()
    }

    /// Registers the shortcut; returns a localized error message on failure.
    @discardableResult
    private func registerHotkey(_ combo: KeyCombo) -> String? {
        do {
            try hotkeys.registerMainHotkey(combo)
            return nil
        } catch HotkeyError.conflict {
            return L10n.t("error.hotkey.conflict", combo.displayString)
        } catch {
            return L10n.t("error.hotkey.failed", combo.displayString)
        }
    }

    private func showHotkeyConflictAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = L10n.t("alert.hotkeyConflict.title")
        alert.informativeText = message + "\n" + L10n.t("alert.hotkeyConflict.hint")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.t("common.ok"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - Windows

    public func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(deps: deps)))
            window.title = L10n.t("settings.title")
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func showOnboarding() {
        if onboardingWindow == nil {
            let view = OnboardingView(deps: deps) { [weak self] in
                self?.onboardingWindow?.close()
            }
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = L10n.t("onboarding.title")
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            onboardingWindow = window
        }
        onboardingWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func showFileTranscription() {
        if fileTranscriptionWindow == nil {
            let controller = FileTranscriptionController(
                settings: settings,
                modelManager: modelManager)
            let view = FileTranscriptionView(
                controller: controller,
                openSettings: { [weak self] in self?.showSettings() })
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = L10n.t("file.window.title")
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 980, height: 720))
            window.minSize = NSSize(width: 880, height: 650)
            window.isReleasedWhenClosed = false
            window.center()
            fileTranscriptionController = controller
            fileTranscriptionWindow = window
        }
        fileTranscriptionController?.refreshModels()
        fileTranscriptionWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
