import AppKit
import ServiceManagement
import SwiftUI

/// Container passed into settings/onboarding so views can reach services.
@MainActor
public final class SettingsDependencies: ObservableObject {
    public let settings: SettingsStore
    public let modelManager: ModelManager
    public let permissions: PermissionsChecking
    public let dictation: DictationController
    /// Re-registers the global hotkey; returns a localized error, nil on success.
    public let applyHotkey: (KeyCombo) -> String?

    public init(
        settings: SettingsStore,
        modelManager: ModelManager,
        permissions: PermissionsChecking,
        dictation: DictationController,
        applyHotkey: @escaping (KeyCombo) -> String?
    ) {
        self.settings = settings
        self.modelManager = modelManager
        self.permissions = permissions
        self.dictation = dictation
        self.applyHotkey = applyHotkey
    }
}

public struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    let deps: SettingsDependencies

    public init(deps: SettingsDependencies) {
        self.deps = deps
        self.settings = deps.settings
    }

    public var body: some View {
        TabView {
            GeneralSettingsTab(settings: settings, deps: deps)
                .tabItem { Label(L10n.t("settings.tab.general"), systemImage: "gearshape") }
            TranscriptionSettingsTab(settings: settings, modelManager: deps.modelManager)
                .tabItem { Label(L10n.t("settings.tab.transcription"), systemImage: "waveform") }
            PermissionsSettingsTab(deps: deps)
                .tabItem { Label(L10n.t("settings.tab.permissions"), systemImage: "checkmark.shield") }
            RefinementSettingsTab(settings: settings)
                .tabItem { Label(L10n.t("settings.tab.refinement"), systemImage: "wand.and.stars") }
            PrivacySettingsTab(settings: settings)
                .tabItem { Label(L10n.t("settings.tab.privacy"), systemImage: "lock.shield") }
        }
        .frame(width: 600, height: 560)
    }
}

// MARK: - General

struct GeneralSettingsTab: View {
    @ObservedObject var settings: SettingsStore
    let deps: SettingsDependencies
    @State private var hotkeyError: String?
    @State private var loginItemError: String?
    @State private var devices: [AudioDeviceFinder.Device] = []

    var body: some View {
        Form {
            Section(L10n.t("settings.hotkey.section")) {
                HStack {
                    Text(L10n.t("settings.hotkey"))
                    Spacer()
                    HotkeyRecorderView(
                        current: KeyCombo(keyCode: settings.hotkeyKeyCode, modifiers: settings.hotkeyModifiers)
                    ) { combo in
                        if let error = deps.applyHotkey(combo) {
                            hotkeyError = error
                        } else {
                            hotkeyError = nil
                            settings.hotkeyKeyCode = combo.keyCode
                            settings.hotkeyModifiers = combo.modifiers
                        }
                    }
                }
                if let hotkeyError {
                    Text(hotkeyError)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                Picker(L10n.t("settings.hotkey.mode"), selection: $settings.hotkeyMode) {
                    Text(L10n.t("settings.hotkey.mode.hold")).tag(HotkeyMode.pressAndHold)
                    Text(L10n.t("settings.hotkey.mode.toggle")).tag(HotkeyMode.toggle)
                }
                .pickerStyle(.radioGroup)
            }

            Section(L10n.t("settings.audio.section")) {
                Picker(L10n.t("settings.mic"), selection: Binding(
                    get: { settings.inputDeviceUID ?? "" },
                    set: { settings.inputDeviceUID = $0.isEmpty ? nil : $0 })
                ) {
                    Text(L10n.t("settings.mic.default")).tag("")
                    ForEach(devices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
            }

            Section(L10n.t("settings.insertion.section")) {
                Picker(L10n.t("settings.insertion"), selection: $settings.insertionMode) {
                    Text(L10n.t("settings.insertion.auto")).tag(InsertionMode.automatic)
                    Text(L10n.t("settings.insertion.clipboard")).tag(InsertionMode.clipboardOnly)
                }
                .pickerStyle(.radioGroup)
            }

            Section(L10n.t("settings.app.section")) {
                Toggle(L10n.t("settings.launchAtLogin"), isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { newValue in
                        settings.launchAtLogin = newValue
                        loginItemError = LoginItemService.setEnabled(newValue)
                    }))
                if let loginItemError {
                    Text(loginItemError)
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                Picker(L10n.t("settings.language.ui"), selection: $settings.interfaceLanguage) {
                    Text(L10n.t("settings.language.ui.ru")).tag(L10n.Language.russian)
                    Text(L10n.t("settings.language.ui.en")).tag(L10n.Language.english)
                    Text(L10n.t("settings.language.ui.system")).tag(L10n.Language.system)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { devices = AudioDeviceFinder.inputDevices() }
    }
}

// MARK: - Permissions and readiness

struct PermissionsSettingsTab: View {
    let deps: SettingsDependencies
    @State private var microphone: PermissionStatus = .notDetermined
    @State private var accessibilityTrusted = false
    @State private var engineAvailable = false
    @State private var selectedModelAvailable = false

    private var everythingReady: Bool {
        microphone == .granted
            && (deps.settings.insertionMode != .automatic || accessibilityTrusted)
            && engineAvailable
            && selectedModelAvailable
    }

    var body: some View {
        Form {
            Section {
                Label(
                    everythingReady
                        ? L10n.t("permissions.overall.ready")
                        : L10n.t("permissions.overall.action"),
                    systemImage: everythingReady ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(everythingReady ? .green : .orange)
                Text(L10n.t("permissions.overall.hint"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.t("permissions.required.section")) {
                permissionRow(
                    title: L10n.t("permissions.microphone.title"),
                    detail: L10n.t("permissions.microphone.detail"),
                    granted: microphone == .granted,
                    required: true) {
                        if microphone == .notDetermined {
                            Button(L10n.t("permissions.request")) {
                                Task {
                                    _ = await deps.permissions.requestMicrophoneAccess()
                                    refresh()
                                }
                            }
                        } else {
                            Button(L10n.t("permissions.openSettings")) {
                                deps.permissions.openMicrophoneSettings()
                            }
                        }
                    }

                permissionRow(
                    title: L10n.t("permissions.accessibility.title"),
                    detail: L10n.t("permissions.accessibility.detail"),
                    granted: accessibilityTrusted,
                    required: deps.settings.insertionMode == .automatic) {
                        Button(accessibilityTrusted
                               ? L10n.t("permissions.openSettings")
                               : L10n.t("permissions.fix")) {
                            deps.permissions.promptForAccessibility()
                            deps.permissions.openAccessibilitySettings()
                        }
                    }

                if !accessibilityTrusted {
                    Label(L10n.t("permissions.accessibility.stale"), systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section(L10n.t("permissions.readiness.section")) {
                readinessRow(
                    L10n.t("permissions.engine.title"),
                    detail: L10n.t("permissions.engine.detail"),
                    ready: engineAvailable)
                readinessRow(
                    L10n.t("permissions.model.title"),
                    detail: L10n.t("permissions.model.detail", deps.settings.whisperModel),
                    ready: selectedModelAvailable)
                Label(L10n.t("permissions.notNeeded"), systemImage: "hand.raised.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button(L10n.t("permissions.recheck")) { refresh() }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                refresh()
            }
        }
    }

    @ViewBuilder
    private func permissionRow<Actions: View>(
        title: String,
        detail: String,
        granted: Bool,
        required: Bool,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(granted ? .green : (required ? .red : .orange))
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).fontWeight(.medium)
                    Text(required ? L10n.t("permissions.required") : L10n.t("permissions.optional"))
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12))
                        .clipShape(Capsule())
                }
                Text(granted ? L10n.t("permissions.granted") : L10n.t("permissions.missing"))
                    .font(.caption)
                    .foregroundStyle(granted ? .green : (required ? .red : .orange))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            actions()
        }
        .padding(.vertical, 3)
    }

    private func readinessRow(_ title: String, detail: String, ready: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: ready ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ready ? .green : .red)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(ready ? L10n.t("permissions.ready") : L10n.t("permissions.notReady"))
                .font(.caption)
                .foregroundStyle(ready ? .green : .red)
        }
    }

    private func refresh() {
        microphone = deps.permissions.microphoneStatus
        accessibilityTrusted = deps.permissions.accessibilityTrusted
        engineAvailable = (try? WhisperTranscriber().locateBinary()) != nil
        selectedModelAvailable = (try? deps.modelManager.resolveModel(named: deps.settings.whisperModel)) != nil
    }
}

/// Captures the next key press (with modifiers) via a local event monitor.
struct HotkeyRecorderView: View {
    let current: KeyCombo
    let onCapture: (KeyCombo) -> Void
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button(recording ? L10n.t("settings.hotkey.press") : current.displayString) {
            recording ? stopRecording() : startRecording()
        }
        .accessibilityLabel(L10n.t("settings.hotkey"))
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            defer { stopRecording() }
            if event.keyCode == 53 { // Esc cancels recording
                return nil
            }
            let combo = KeyCombo.fromNSEvent(keyCode: event.keyCode, flags: event.modifierFlags)
            onCapture(combo)
            return nil
        }
    }

    private func stopRecording() {
        recording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

enum LoginItemService {
    /// Returns a localized error string, or nil on success.
    static func setEnabled(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return L10n.t("settings.launchAtLogin.error", error.localizedDescription)
        }
    }
}

// MARK: - Transcription

struct TranscriptionSettingsTab: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var modelManager: ModelManager
    @State private var confirmDownload: WhisperModelInfo?
    @State private var downloadError: String?

    private var visibleInstalledModels: [ModelManager.InstalledModel] {
        let recommended = WhisperModelCatalog.models.compactMap { info in
            modelManager.installedModels.first { $0.name == info.name }
        }
        guard !recommended.isEmpty else { return modelManager.installedModels }
        guard let legacySelection = modelManager.installedModels.first(where: {
            $0.name == settings.whisperModel && !WhisperModelCatalog.isRecommended($0.name)
        }) else { return recommended }
        return recommended + [legacySelection]
    }

    var body: some View {
        Form {
            Section(L10n.t("settings.model.microphone")) {
                if modelManager.installedModels.isEmpty {
                    Text(L10n.t("settings.model.none"))
                        .foregroundStyle(.secondary)
                }
                Picker(L10n.t("settings.model"), selection: $settings.whisperModel) {
                    ForEach(visibleInstalledModels) { model in
                        Text("\(WhisperModelCatalog.info(for: model.name)?.displayName ?? model.name) (\(ByteCountFormatter.string(fromByteCount: model.sizeBytes, countStyle: .file)))")
                            .tag(model.name)
                    }
                    if !modelManager.installedModels.contains(where: { $0.name == settings.whisperModel }) {
                        Text(L10n.t("settings.model.notInstalled", settings.whisperModel))
                            .tag(settings.whisperModel)
                    }
                }
            }

            Section(L10n.t("settings.model.download")) {
                ForEach(WhisperModelCatalog.models) { info in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(info.displayName)
                                .fontWeight(.medium)
                            Text(info.usageDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(info.sizeLabel)
                            .foregroundStyle(.secondary)
                        if modelManager.installedModels.contains(where: { $0.name == info.name }) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .accessibilityLabel(L10n.t("settings.model.installedAx"))
                        } else if modelManager.downloadingModel == info.name {
                            VStack(alignment: .trailing, spacing: 3) {
                                HStack(spacing: 6) {
                                    ProgressView(value: modelManager.downloadProgress ?? 0)
                                    Text("\(Int(((modelManager.downloadProgress ?? 0) * 100).rounded()))%")
                                        .monospacedDigit()
                                }
                                Text(downloadSizeSummary)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(width: 145)
                            Button(L10n.t("common.cancel")) {
                                modelManager.cancelDownload()
                            }
                        } else {
                            Button(L10n.t("settings.model.get")) {
                                confirmDownload = info
                            }
                            .disabled(modelManager.isDownloading)
                            .help(modelManager.isDownloading
                                  ? L10n.t("settings.model.download.wait")
                                  : "")
                        }
                    }
                }
                if let name = modelManager.downloadingModel {
                    Label(
                        L10n.t("settings.model.download.active", displayName(for: name)),
                        systemImage: "arrow.down.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let downloadError {
                    Text(downloadError)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }

            Section(L10n.t("settings.recognition.section")) {
                Picker(L10n.t("settings.spoken"), selection: $settings.spokenLanguage) {
                    Text(L10n.t("settings.spoken.auto")).tag(SpokenLanguage.auto)
                    Text(L10n.t("settings.spoken.ru")).tag(SpokenLanguage.russian)
                    Text(L10n.t("settings.spoken.en")).tag(SpokenLanguage.english)
                }
                Stepper(value: $settings.whisperThreads, in: 1...16) {
                    Text(L10n.t("settings.threads", settings.whisperThreads))
                }
                Toggle(L10n.t("settings.artifacts"), isOn: $settings.removeArtifacts)
            }
        }
        .formStyle(.grouped)
        .onAppear { modelManager.refreshInstalledModels() }
        // Explicit size confirmation before any model download.
        .confirmationDialog(
            L10n.t("settings.model.confirm.title"),
            isPresented: Binding(get: { confirmDownload != nil }, set: { if !$0 { confirmDownload = nil } })
        ) {
            if let info = confirmDownload {
                Button(L10n.t("settings.model.confirm.download", info.sizeLabel)) {
                    start(info)
                }
                Button(L10n.t("common.cancel"), role: .cancel) {}
            }
        } message: {
            if let info = confirmDownload {
                Text(L10n.t("settings.model.confirm.message", info.name, info.sizeLabel))
            }
        }
    }

    private func start(_ info: WhisperModelInfo) {
        confirmDownload = nil
        downloadError = nil
        Task {
            do {
                _ = try await modelManager.download(info)
            } catch is CancellationError {
                // user cancelled — nothing to report
            } catch let error as URLError where error.code == .cancelled {
                // user cancelled — nothing to report
            } catch {
                downloadError = L10n.t("settings.model.download.error", error.localizedDescription)
            }
        }
    }

    private var downloadSizeSummary: String {
        let written = ByteCountFormatter.string(fromByteCount: modelManager.downloadedBytes, countStyle: .file)
        guard modelManager.downloadTotalBytes > 0 else { return written }
        let total = ByteCountFormatter.string(fromByteCount: modelManager.downloadTotalBytes, countStyle: .file)
        return "\(written) / \(total)"
    }

    private func displayName(for name: String) -> String {
        WhisperModelCatalog.info(for: name)?.displayName
            ?? (name == ParakeetModelCatalog.recommended.name
                ? ParakeetModelCatalog.recommended.displayName
                : name)
    }
}

// MARK: - Refinement

struct RefinementSettingsTab: View {
    @ObservedObject var settings: SettingsStore
    @State private var availability: String?
    @State private var ollamaModels: [String] = []

    var body: some View {
        Form {
            Section {
                Toggle(L10n.t("settings.refine.enabled"), isOn: $settings.refinementEnabled)
                Text(L10n.t("settings.refine.hint"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.t("settings.refine.ollama.section")) {
                TextField(L10n.t("settings.refine.endpoint"), text: $settings.ollamaEndpoint)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    TextField(L10n.t("settings.refine.model"), text: $settings.ollamaModel)
                        .textFieldStyle(.roundedBorder)
                    if !ollamaModels.isEmpty {
                        Picker("", selection: $settings.ollamaModel) {
                            ForEach(ollamaModels, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 30)
                    }
                }
                HStack {
                    Button(L10n.t("settings.refine.check")) { check() }
                    if let availability {
                        Text(availability)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Text(L10n.t("settings.refine.timeout"))
                    Slider(value: $settings.refinementTimeout, in: 5...60, step: 5)
                    Text("\(Int(settings.refinementTimeout)) s")
                        .monospacedDigit()
                }
            }
            .disabled(!settings.refinementEnabled)

            Section(L10n.t("settings.refine.preset.section")) {
                Picker(L10n.t("settings.refine.preset"), selection: $settings.refinementPreset) {
                    ForEach(RefinementPreset.allCases, id: \.self) { preset in
                        Text(L10n.t(preset.titleKey)).tag(preset)
                    }
                }
                if settings.refinementPreset == .custom {
                    TextEditor(text: $settings.customInstruction)
                        .frame(height: 70)
                        .font(.system(size: 12))
                        .accessibilityLabel(L10n.t("settings.refine.custom"))
                }
            }
            .disabled(!settings.refinementEnabled)
        }
        .formStyle(.grouped)
    }

    private func check() {
        availability = L10n.t("settings.refine.status.checking")
        let endpoint = settings.ollamaEndpoint
        let model = settings.ollamaModel
        Task {
            do {
                let provider = try OllamaRefinementProvider(endpoint: endpoint, model: model)
                let names = try await provider.installedModels()
                ollamaModels = names
                if model.isEmpty {
                    availability = L10n.t("settings.refine.status.pickModel", names.joined(separator: ", "))
                } else {
                    switch await provider.checkAvailability() {
                    case .available:
                        availability = L10n.t("settings.refine.status.ok")
                    case .modelMissing(let available):
                        availability = L10n.t("settings.refine.status.nomodel", available.joined(separator: ", "))
                    case .serverUnreachable(let reason):
                        availability = L10n.t("settings.refine.status.unreachable", reason)
                    }
                }
            } catch RefinementError.nonLocalEndpoint {
                availability = L10n.t("settings.refine.nonlocal")
            } catch {
                availability = L10n.t("settings.refine.status.unreachable", error.localizedDescription)
            }
        }
    }
}

// MARK: - Privacy

struct PrivacySettingsTab: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        Form {
            Section(L10n.t("privacy.title")) {
                ForEach(1...5, id: \.self) { index in
                    Label(L10n.t("privacy.p\(index)"), systemImage: "checkmark.shield")
                        .font(.callout)
                }
            }
            Section(L10n.t("settings.diagnostics.section")) {
                Picker(L10n.t("settings.loglevel"), selection: $settings.logLevel) {
                    Text(L10n.t("settings.loglevel.off")).tag(LogLevel.off)
                    Text(L10n.t("settings.loglevel.error")).tag(LogLevel.error)
                    Text(L10n.t("settings.loglevel.info")).tag(LogLevel.info)
                    Text(L10n.t("settings.loglevel.debug")).tag(LogLevel.debug)
                }
                Text(L10n.t("privacy.logs"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button(L10n.t("menu.logs")) {
                    NSWorkspace.shared.open(Log.shared.directory)
                }
            }
            Section {
                Button(L10n.t("settings.resetOnboarding")) {
                    settings.resetOnboarding()
                }
            }
        }
        .formStyle(.grouped)
    }
}
