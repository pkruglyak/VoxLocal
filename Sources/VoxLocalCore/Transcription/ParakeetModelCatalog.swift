import Foundation

/// NVIDIA's multilingual offline model used for high-quality file
/// transcription. The revision, byte count and checksum match the model index
/// bundled with NeMo-Speech.cpp 0.2.0.
public struct ParakeetModelInfo: Identifiable, Hashable, Sendable {
    public let name = "parakeet-tdt-0.6b-v3"
    public let approxMB = 714
    public let expectedBytes: Int64 = 713_975_456
    public let sha256 = "e3880d0aaaaf2c308ea2c35016b2b895c423eb3fda924c1b463d1c19b7f4d32e"

    public var id: String { name }
    public var fileName: String { "parakeet-tdt-0.6b-v3.q8_0.gguf" }
    public var displayName: String { L10n.t("model.parakeet.title") }
    public var usageDescription: String { L10n.t("model.parakeet.description") }

    /// Official NVIDIA model repository. The pinned revision is the one
    /// tested by the bundled NeMo-Speech.cpp runtime.
    public var downloadURL: URL {
        URL(string: "https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3/resolve/541d1f99c6b0c3cd0b11a95167540bb8edefd82b/\(fileName)")!
    }

    public var sizeLabel: String {
        "\(approxMB) MB"
    }
}

public enum ParakeetModelCatalog {
    public static let recommended = ParakeetModelInfo()
}
