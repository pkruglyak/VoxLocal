import Foundation

/// Runs the bundled NVIDIA NeMo-Speech.cpp CLI with Parakeet TDT. Parakeet is
/// intentionally used only for complete audio/video files; microphone
/// dictation continues to use the lower-latency Whisper pipeline.
public final class ParakeetTranscriber: @unchecked Sendable {
    private struct Output: Decodable {
        let text: String
        let languages: [String]?
    }

    private let runner: SubprocessRunning
    private let binaryOverride: URL?

    public init(runner: SubprocessRunning = ProcessSubprocessRunner(), binaryOverride: URL? = nil) {
        self.runner = runner
        self.binaryOverride = binaryOverride
    }

    public static func binaryCandidates() -> [URL] {
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["VOXLOCAL_NEMO_SPEECH_CLI"], !env.isEmpty {
            candidates.append(URL(fileURLWithPath: env))
        }
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "nemo-speech") {
            candidates.append(bundled)
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        candidates.append(cwd.appendingPathComponent("vendor/nemo-speech/bin/nemo-speech"))
        return candidates
    }

    public func locateBinary() throws -> URL {
        if let binaryOverride { return binaryOverride }
        let candidates = Self.binaryCandidates()
        for url in candidates where FileManager.default.isExecutableFile(atPath: url.path) {
            return url
        }
        let searched = candidates.map { PathRedactor.redact($0.path) }.joined(separator: ", ")
        throw VoxLocalError.whisperBinaryMissing(searched)
    }

    public func transcribe(
        audioURL: URL,
        modelURL: URL,
        language: String,
        removeArtifacts: Bool,
        timeout: TimeInterval = 21_600
    ) async throws -> WhisperTranscriber.Transcript {
        let binary = try locateBinary()
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw VoxLocalError.recordingFailed("audio file vanished before transcription")
        }
        switch ModelManager.validateParakeetModelFile(at: modelURL) {
        case .valid: break
        case .missing: throw VoxLocalError.modelMissing(modelURL.path)
        case .tooSmall, .badMagic, .wrongSize: throw VoxLocalError.modelInvalid(modelURL.path)
        }

        var arguments = [
            "--json", "--quiet", "transcribe", audioURL.path,
            "--model", modelURL.path,
            "--device", "metal",
            "--no-warmup",
        ]
        if language != "auto" {
            arguments.append(contentsOf: ["--language", language])
        }

        Log.shared.info("nemo-speech starting (model \(modelURL.lastPathComponent), lang \(language))")
        let started = Date()
        let result: SubprocessResult
        do {
            result = try await runner.run(executable: binary, arguments: arguments, timeout: timeout)
        } catch SubprocessError.timeout {
            throw VoxLocalError.transcriptionTimeout
        } catch SubprocessError.launchFailed(let reason) {
            if reason.localizedCaseInsensitiveContains("bad cpu type")
                || reason.localizedCaseInsensitiveContains("badarch") {
                throw VoxLocalError.unsupportedArchitecture(reason)
            }
            throw VoxLocalError.transcriptionFailed(exitCode: -1, detail: reason)
        }

        try Task.checkCancellation()
        guard result.exitCode == 0 else {
            let stderrTail = String(data: result.stderr.suffix(900), encoding: .utf8) ?? ""
            throw VoxLocalError.transcriptionFailed(exitCode: result.exitCode, detail: stderrTail)
        }

        guard let output = try? JSONDecoder().decode(Output.self, from: result.stdout) else {
            throw VoxLocalError.transcriptionOutputMissing
        }
        let cleaned = removeArtifacts
            ? WhisperOutputParser.stripArtifacts(from: output.text)
            : output.text
        let text = WhisperOutputParser.normalizeWhitespace(cleaned)
        let detectedLanguage = output.languages?.first ?? (language == "auto" ? nil : language)
        let elapsed = String(format: "%.1f", Date().timeIntervalSince(started))
        Log.shared.info("nemo-speech finished in \(elapsed)s (chars: \(text.count), lang: \(detectedLanguage ?? "?"))")
        return WhisperTranscriber.Transcript(text: text, detectedLanguage: detectedLanguage)
    }
}
