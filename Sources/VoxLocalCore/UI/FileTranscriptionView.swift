import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

@MainActor
public final class FileTranscriptionController: ObservableObject {
    public struct AvailableModel: Identifiable, Hashable, Sendable {
        public enum Engine: Hashable, Sendable {
            case whisper
            case parakeet
        }

        public let name: String
        public let engine: Engine
        public let sizeBytes: Int64
        public var id: String { name }

        public var displayName: String {
            switch engine {
            case .whisper:
                return WhisperModelCatalog.info(for: name)?.displayName ?? name
            case .parakeet:
                return ParakeetModelCatalog.recommended.displayName
            }
        }
    }

    public enum State: Equatable {
        case ready
        case preparing
        case transcribing
        case completed
        case failed(String)
    }

    @Published public private(set) var state: State = .ready
    @Published public private(set) var sourceURL: URL?
    @Published public private(set) var installedModels: [AvailableModel] = []
    @Published public var selectedModel = ""
    @Published public var transcriptText = ""
    @Published public private(set) var detectedLanguage: String?
    @Published public private(set) var completedAt: Date?
    @Published public private(set) var isDownloadingRecommendedModel = false
    @Published public private(set) var modelDownloadProgress: Double = 0
    @Published public private(set) var modelDownloadError: String?

    private let settings: SettingsStore
    private let modelManager: ModelManager
    private let transcriber: WhisperTranscriber
    private let parakeetTranscriber: ParakeetTranscriber
    private let converter: MediaAudioConverter
    private var task: Task<Void, Never>?
    private var modelDownloadTask: Task<Void, Never>?
    private var modelSubscription: AnyCancellable?
    private var parakeetModelSubscription: AnyCancellable?
    private var downloadProgressSubscription: AnyCancellable?

    public init(
        settings: SettingsStore,
        modelManager: ModelManager,
        transcriber: WhisperTranscriber = WhisperTranscriber(),
        parakeetTranscriber: ParakeetTranscriber = ParakeetTranscriber(),
        converter: MediaAudioConverter = MediaAudioConverter()
    ) {
        self.settings = settings
        self.modelManager = modelManager
        self.transcriber = transcriber
        self.parakeetTranscriber = parakeetTranscriber
        self.converter = converter
        modelSubscription = modelManager.$installedModels
            .receive(on: DispatchQueue.main)
            .sink { [weak self] models in self?.applyModels(models) }
        parakeetModelSubscription = modelManager.$installedParakeetModel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.applyModels(self.modelManager.installedModels)
            }
        downloadProgressSubscription = modelManager.$downloadProgress
            .receive(on: DispatchQueue.main)
            .sink { [weak self] progress in self?.modelDownloadProgress = progress ?? 0 }
        refreshModels()
    }

    public var isWorking: Bool {
        state == .preparing || state == .transcribing
    }

    public var canTranscribe: Bool {
        sourceURL != nil && !selectedModel.isEmpty && !isWorking
    }

    public var documentTitle: String {
        let title = sourceURL?.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? L10n.t("file.document.untitled") : title
    }

    public func refreshModels() {
        modelManager.refreshInstalledModels()
        applyModels(modelManager.installedModels)
        // ModelManager publishes its scan on the next main-queue turn.
        // Mirror that result after it lands so a just-downloaded model is
        // immediately available in this picker.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.applyModels(self.modelManager.installedModels)
        }
    }

    private func applyModels(_ models: [ModelManager.InstalledModel]) {
        let recommended = WhisperModelCatalog.models.compactMap { info in
            models.first { $0.name == info.name }
        }
        let visibleWhisper = recommended.isEmpty ? models : recommended
        var available = visibleWhisper.map {
            AvailableModel(name: $0.name, engine: .whisper, sizeBytes: $0.sizeBytes)
        }
        if let parakeet = modelManager.installedParakeetModel {
            available.insert(
                AvailableModel(name: parakeet.name, engine: .parakeet, sizeBytes: parakeet.sizeBytes),
                at: 0)
        }
        installedModels = available
        if selectedModel.isEmpty || !installedModels.contains(where: { $0.name == selectedModel }) {
            let preferredNames = [
                ParakeetModelCatalog.recommended.name,
                WhisperModelCatalog.fileDefaultModelName,
                "small",
                settings.whisperModel,
                WhisperModelCatalog.microphoneDefaultModelName,
            ]
            selectedModel = preferredNames.first(where: { name in
                installedModels.contains(where: { $0.name == name })
            }) ?? installedModels.first?.name ?? ""
        }
    }

    public var recommendedFileModel: ParakeetModelInfo {
        ParakeetModelCatalog.recommended
    }

    public var hasRecommendedFileModel: Bool {
        installedModels.contains { $0.name == ParakeetModelCatalog.recommended.name }
    }

    public func downloadRecommendedFileModel() {
        guard !hasRecommendedFileModel, !isDownloadingRecommendedModel else { return }
        modelDownloadError = nil
        modelDownloadProgress = 0
        isDownloadingRecommendedModel = true
        let info = recommendedFileModel
        modelDownloadTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isDownloadingRecommendedModel = false }
            do {
                _ = try await self.modelManager.download(info)
                self.refreshModels()
                self.selectedModel = info.name
            } catch is CancellationError {
            } catch let error as URLError where error.code == .cancelled {
            } catch {
                self.modelDownloadError = L10n.t("settings.model.download.error", error.localizedDescription)
            }
        }
    }

    public func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = L10n.t("file.picker.title")
        panel.prompt = L10n.t("file.picker.choose")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio, .movie]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setSource(url)
    }

    public func setSource(_ url: URL) {
        sourceURL = url
        transcriptText = ""
        detectedLanguage = nil
        completedAt = nil
        state = .ready
    }

    /// Removes the file from this window without touching the original file
    /// on disk.
    public func clearSource() {
        guard !isWorking else { return }
        sourceURL = nil
        transcriptText = ""
        detectedLanguage = nil
        completedAt = nil
        state = .ready
    }

    public func transcribe() {
        guard let sourceURL, canTranscribe else { return }
        task?.cancel()
        state = .preparing
        transcriptText = ""
        detectedLanguage = nil
        completedAt = nil

        let modelName = selectedModel
        let selectedEngine = installedModels.first { $0.name == modelName }?.engine
        let language = settings.spokenLanguage.whisperCode
        let threads = settings.whisperThreads
        let removeArtifacts = settings.removeArtifacts

        task = Task { [weak self] in
            guard let self else { return }
            var temporaryWAV: URL?
            do {
                let modelURL: URL
                switch selectedEngine {
                case .parakeet:
                    modelURL = try self.modelManager.resolveParakeetModel()
                case .whisper, .none:
                    modelURL = try self.modelManager.resolveModel(named: modelName)
                }
                let audioURL: URL
                if selectedEngine != .parakeet,
                   ["wav", "mp3", "flac", "ogg"].contains(sourceURL.pathExtension.lowercased()) {
                    audioURL = sourceURL
                } else if sourceURL.pathExtension.lowercased() == "wav" {
                    audioURL = sourceURL
                } else {
                    let converted = try await self.converter.convertToWAV(sourceURL: sourceURL)
                    temporaryWAV = converted
                    audioURL = converted
                }
                try Task.checkCancellation()
                self.state = .transcribing
                let result: WhisperTranscriber.Transcript
                if selectedEngine == .parakeet {
                    result = try await self.parakeetTranscriber.transcribe(
                        audioURL: audioURL,
                        modelURL: modelURL,
                        language: language,
                        removeArtifacts: removeArtifacts,
                        timeout: 21_600)
                } else {
                    result = try await self.transcriber.transcribe(
                        audioURL: audioURL,
                        modelURL: modelURL,
                        language: language,
                        threads: threads,
                        removeArtifacts: removeArtifacts,
                        timeout: 21_600)
                }
                try Task.checkCancellation()
                self.transcriptText = result.text
                self.detectedLanguage = result.detectedLanguage
                self.completedAt = Date()
                self.state = .completed
            } catch is CancellationError {
                self.state = .ready
            } catch let error as VoxLocalError {
                Log.shared.error(error.logDetail)
                self.state = .failed(L10n.t(error.messageKey))
            } catch {
                Log.shared.error("file transcription failed: \(error.localizedDescription)")
                self.state = .failed(error.localizedDescription)
            }
            if let temporaryWAV { try? FileManager.default.removeItem(at: temporaryWAV) }
        }
    }

    public func cancel() {
        task?.cancel()
        task = nil
        state = .ready
    }

    public func copyTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(documentPlainText(), forType: .string)
    }

    public func saveDocument() {
        guard !transcriptText.isEmpty else { return }
        let panel = NSSavePanel()
        panel.title = L10n.t("file.save.title")
        panel.prompt = L10n.t("file.save.button")
        panel.nameFieldStringValue = documentTitle + ".rtf"
        panel.allowedContentTypes = [.rtf]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let fullRange = NSRange(location: 0, length: documentAttributedString().length)
            let data = try documentAttributedString().data(
                from: fullRange,
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
            try data.write(to: url, options: .atomic)
        } catch {
            state = .failed(L10n.t("file.error.save", error.localizedDescription))
        }
    }

    public var selectedModelDisplayName: String {
        installedModels.first { $0.name == selectedModel }?.displayName ?? selectedModel
    }

    private func documentPlainText() -> String {
        var sections = [documentTitle]
        if let sourceURL { sections.append("\(L10n.t("file.document.source")): \(sourceURL.lastPathComponent)") }
        sections.append("\(L10n.t("file.document.model")): \(selectedModelDisplayName)")
        if let completedAt {
            sections.append("\(L10n.t("file.document.date")): \(Self.dateFormatter.string(from: completedAt))")
        }
        sections.append("\n\(L10n.t("file.document.transcript"))\n\(transcriptText)")
        return sections.joined(separator: "\n")
    }

    private func documentAttributedString() -> NSAttributedString {
        let result = NSMutableAttributedString()
        let titleFont = NSFont.systemFont(ofSize: 24, weight: .bold)
        let headingFont = NSFont.systemFont(ofSize: 15, weight: .semibold)
        let bodyFont = NSFont.systemFont(ofSize: 13)
        let secondary = NSColor.secondaryLabelColor
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        paragraph.paragraphSpacing = 8

        result.append(NSAttributedString(string: documentTitle + "\n", attributes: [.font: titleFont]))
        if let completedAt {
            result.append(NSAttributedString(
                string: Self.dateFormatter.string(from: completedAt) + "\n\n",
                attributes: [.font: bodyFont, .foregroundColor: secondary]))
        }
        if let sourceURL {
            result.append(NSAttributedString(string: "\(L10n.t("file.document.source")): ", attributes: [.font: headingFont]))
            result.append(NSAttributedString(string: sourceURL.lastPathComponent + "\n", attributes: [.font: bodyFont]))
        }
        result.append(NSAttributedString(string: "\(L10n.t("file.document.model")): ", attributes: [.font: headingFont]))
        result.append(NSAttributedString(string: selectedModelDisplayName + "\n", attributes: [.font: bodyFont]))
        result.append(NSAttributedString(string: "\n\(L10n.t("file.document.transcript"))\n", attributes: [.font: headingFont]))
        result.append(NSAttributedString(string: transcriptText, attributes: [.font: bodyFont, .paragraphStyle: paragraph]))
        return result
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        return formatter
    }()
}

public struct FileTranscriptionView: View {
    @ObservedObject private var controller: FileTranscriptionController
    private let openSettings: () -> Void

    public init(controller: FileTranscriptionController, openSettings: @escaping () -> Void) {
        self.controller = controller
        self.openSettings = openSettings
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(alignment: .top, spacing: 0) {
                FileSetupPane(controller: controller, openSettings: openSettings)
                    .frame(width: 360, alignment: .topLeading)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                Divider()
                FilePreviewPane(controller: controller)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 880, minHeight: 650)
        .onAppear { controller.refreshModels() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform.badge.magnifyingglass")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.t("file.title"))
                    .font(.title2.bold())
                Text(L10n.t("file.subtitle"))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
    }
}

private struct FileSetupPane: View {
    @ObservedObject var controller: FileTranscriptionController
    let openSettings: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                FileDropZone(controller: controller)
                ModelPickerSection(controller: controller, openSettings: openSettings)
                TranscriptionActionSection(controller: controller)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct FileDropZone: View {
    @ObservedObject var controller: FileTranscriptionController
    @State private var isDropTarget = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("file.section.file")).font(.headline)
            Button(action: controller.chooseFile) {
                VStack(spacing: 9) {
                    Image(systemName: controller.sourceURL == nil ? "arrow.down.doc" : "doc.fill")
                        .font(.system(size: 28))
                    Text(controller.sourceURL?.lastPathComponent ?? L10n.t("file.choose"))
                        .fontWeight(.medium)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    Text(L10n.t("file.dropHint"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 112)
                .padding(10)
                .background(dropBackground)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(dropBorder)
            }
            .buttonStyle(.plain)
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTarget, perform: handleDrop)

            if controller.sourceURL != nil {
                HStack(spacing: 12) {
                    Button(L10n.t("file.replace"), action: controller.chooseFile)
                    Button(L10n.t("file.remove"), role: .destructive, action: controller.clearSource)
                    Spacer()
                }
                .disabled(controller.isWorking)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dropBackground: Color {
        isDropTarget ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.07)
    }

    private var dropBorder: some View {
        RoundedRectangle(cornerRadius: 12).strokeBorder(
            isDropTarget ? Color.accentColor : Color.secondary.opacity(0.22),
            style: StrokeStyle(lineWidth: 1, dash: [5]))
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL?
            if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else {
                url = item as? URL
            }
            guard let url else { return }
            Task { @MainActor in controller.setSource(url) }
        }
        return true
    }
}

private struct ModelPickerSection: View {
    @ObservedObject var controller: FileTranscriptionController
    let openSettings: () -> Void
    @State private var confirmRecommendedDownload = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("file.section.model")).font(.headline)
            if controller.installedModels.isEmpty {
                Text(L10n.t("file.noModels"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button(L10n.t("file.openSettings"), action: openSettings)
            } else {
                Picker(L10n.t("file.model"), selection: $controller.selectedModel) {
                    ForEach(controller.installedModels) { model in
                        Text(model.displayName)
                            .tag(model.name)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }

            if !controller.hasRecommendedFileModel {
                VStack(alignment: .leading, spacing: 8) {
                    Label(L10n.t("file.model.recommended.title"), systemImage: "sparkles")
                        .font(.callout.weight(.semibold))
                    Text(L10n.t("file.model.recommended.text", controller.recommendedFileModel.sizeLabel))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if controller.isDownloadingRecommendedModel {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(L10n.t("file.model.recommended.downloading"))
                                Spacer()
                                Text("\(Int((controller.modelDownloadProgress * 100).rounded()))%")
                                    .monospacedDigit()
                            }
                            .font(.caption)
                            ProgressView(value: controller.modelDownloadProgress, total: 1)
                                .progressViewStyle(.linear)
                        }
                    } else {
                        Button(L10n.t("file.model.recommended.download")) {
                            confirmRecommendedDownload = true
                        }
                    }
                    if let error = controller.modelDownloadError {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
                .padding(12)
                .background(Color.accentColor.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .confirmationDialog(
            L10n.t("settings.model.confirm.title"),
            isPresented: $confirmRecommendedDownload
        ) {
            Button(L10n.t("settings.model.confirm.download", controller.recommendedFileModel.sizeLabel)) {
                controller.downloadRecommendedFileModel()
            }
            Button(L10n.t("common.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.t(
                "file.model.recommended.confirm.message",
                controller.recommendedFileModel.displayName,
                controller.recommendedFileModel.sizeLabel))
        }
    }
}

private struct TranscriptionActionSection: View {
    @ObservedObject var controller: FileTranscriptionController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if case .failed(let message) = controller.state {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            if controller.isWorking {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text(controller.state == .preparing
                         ? L10n.t("file.status.preparing")
                         : L10n.t("file.status.transcribing"))
                        .font(.callout)
                    Spacer()
                    Button(L10n.t("common.cancel"), action: controller.cancel)
                }
            } else {
                Button(action: controller.transcribe) {
                    Label(L10n.t("file.transcribe"), systemImage: "waveform")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!controller.canTranscribe)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FilePreviewPane: View {
    @ObservedObject var controller: FileTranscriptionController

    var body: some View {
        Group {
            if controller.transcriptText.isEmpty {
                ContentUnavailableView(
                    L10n.t("file.preview.empty.title"),
                    systemImage: "doc.richtext",
                    description: Text(L10n.t("file.preview.empty.text")))
            } else {
                VStack(spacing: 0) {
                    PreviewToolbar(controller: controller)
                    Divider()
                    DocumentPreview(controller: controller)
                    .background(Color(nsColor: .windowBackgroundColor).opacity(0.65))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct PreviewToolbar: View {
    @ObservedObject var controller: FileTranscriptionController

    var body: some View {
        HStack {
            Text(L10n.t("file.preview.title")).font(.headline)
            Spacer()
            Button(action: controller.copyTranscript) {
                Label(L10n.t("file.copy"), systemImage: "doc.on.doc")
            }
            Button(action: controller.saveDocument) {
                Label(L10n.t("file.save"), systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(16)
    }
}

private struct DocumentPreview: View {
    @ObservedObject var controller: FileTranscriptionController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(controller.documentTitle)
                    .font(.system(size: 28, weight: .bold))
                PreviewMetadata(controller: controller)
                Divider()
                Text(L10n.t("file.document.transcript")).font(.headline)
                TextEditor(text: $controller.transcriptText)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 360)
            }
            .padding(30)
            .frame(maxWidth: 720, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
            .padding(28)
            .frame(maxWidth: .infinity)
        }
    }
}

private struct PreviewMetadata: View {
    @ObservedObject var controller: FileTranscriptionController

    var body: some View {
        HStack(spacing: 16) {
            if let source = controller.sourceURL {
                Label(source.lastPathComponent, systemImage: "paperclip")
            }
            Label(controller.selectedModelDisplayName,
                  systemImage: "cpu")
            if let language = controller.detectedLanguage {
                Label(language.uppercased(), systemImage: "globe")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
