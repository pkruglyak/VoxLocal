import Foundation

/// A known downloadable ggml Whisper model. Sizes are approximate and shown
/// to the user before any download starts.
public struct WhisperModelInfo: Identifiable, Hashable, Sendable {
    public let name: String
    public let approxMB: Int
    public let multilingual: Bool

    public var id: String { name }
    public var fileName: String { "ggml-\(name).bin" }

    /// Official upstream source — the same Hugging Face repository used by
    /// whisper.cpp's own `download-ggml-model.sh`.
    public var downloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)")!
    }

    public var sizeLabel: String {
        approxMB >= 1000
            ? String(format: "%.1f GB", Double(approxMB) / 1000)
            : "\(approxMB) MB"
    }

    public var displayName: String { L10n.t("model.\(name).title") }
    public var usageDescription: String { L10n.t("model.\(name).description") }
}

public enum WhisperModelCatalog {
    /// The three choices intentionally exposed in the regular UI. Older model
    /// files remain on disk and can still be resolved, but they no longer make
    /// the model screen look like an expert-only benchmark table.
    public static let models: [WhisperModelInfo] = [
        WhisperModelInfo(name: "base", approxMB: 148, multilingual: true),
        WhisperModelInfo(name: "small", approxMB: 488, multilingual: true),
        WhisperModelInfo(name: "large-v3-turbo", approxMB: 1620, multilingual: true),
    ]

    public static let microphoneDefaultModelName = "base"
    public static let fileDefaultModelName = "large-v3-turbo"
    public static let defaultModelName = microphoneDefaultModelName

    public static func info(for name: String) -> WhisperModelInfo? {
        models.first { $0.name == name }
    }

    public static func isRecommended(_ name: String) -> Bool {
        info(for: name) != nil
    }
}
