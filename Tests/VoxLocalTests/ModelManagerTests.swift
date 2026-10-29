import XCTest
@testable import VoxLocalCore

final class ModelManagerTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voxlocal-models-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func writeValidModel(named name: String) throws -> URL {
        let url = tempDir.appendingPathComponent("ggml-\(name).bin")
        var data = Data([0x6C, 0x6D, 0x67, 0x67]) // ggml magic (LE on disk)
        data.append(Data(count: 1_100_000))
        try data.write(to: url)
        return url
    }

    private func writeValidParakeetModel() throws -> URL {
        let url = tempDir.appendingPathComponent(ParakeetModelCatalog.recommended.fileName)
        try Data([0x47, 0x47, 0x55, 0x46]).write(to: url) // GGUF
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(ParakeetModelCatalog.recommended.expectedBytes))
        try handle.close()
        return url
    }

    func testValidModelPasses() throws {
        let url = try writeValidModel(named: "base")
        XCTAssertEqual(ModelManager.validateModelFile(at: url), .valid)
    }

    func testMissingModel() {
        let url = tempDir.appendingPathComponent("ggml-none.bin")
        XCTAssertEqual(ModelManager.validateModelFile(at: url), .missing)
    }

    func testTooSmallModel() throws {
        let url = tempDir.appendingPathComponent("ggml-tiny.bin")
        try Data([0x6C, 0x6D, 0x67, 0x67, 0x00]).write(to: url)
        XCTAssertEqual(ModelManager.validateModelFile(at: url), .tooSmall)
    }

    func testBadMagicModel() throws {
        let url = tempDir.appendingPathComponent("ggml-corrupt.bin")
        try Data(repeating: 0x42, count: 2_000_000).write(to: url)
        XCTAssertEqual(ModelManager.validateModelFile(at: url), .badMagic)
    }

    func testValidParakeetModelPasses() throws {
        let url = try writeValidParakeetModel()
        XCTAssertEqual(ModelManager.validateParakeetModelFile(at: url), .valid)
    }

    func testTruncatedParakeetModelFails() throws {
        let url = tempDir.appendingPathComponent(ParakeetModelCatalog.recommended.fileName)
        var data = Data([0x47, 0x47, 0x55, 0x46])
        data.append(Data(count: 1_100_000))
        try data.write(to: url)
        XCTAssertEqual(ModelManager.validateParakeetModelFile(at: url), .wrongSize)
    }

    func testResolveModelErrors() throws {
        let manager = ModelManager(modelsDirectory: tempDir)
        XCTAssertThrowsError(try manager.resolveModel(named: "base")) { error in
            guard case VoxLocalError.modelMissing = error else {
                return XCTFail("expected modelMissing, got \(error)")
            }
        }

        try Data(repeating: 1, count: 2_000_000).write(to: tempDir.appendingPathComponent("ggml-base.bin"))
        XCTAssertThrowsError(try manager.resolveModel(named: "base")) { error in
            guard case VoxLocalError.modelInvalid = error else {
                return XCTFail("expected modelInvalid, got \(error)")
            }
        }
    }

    func testResolveValidModel() throws {
        _ = try writeValidModel(named: "base")
        let manager = ModelManager(modelsDirectory: tempDir)
        let url = try manager.resolveModel(named: "base")
        XCTAssertEqual(url.lastPathComponent, "ggml-base.bin")
    }

    func testResolveValidParakeetModel() throws {
        let expected = try writeValidParakeetModel()
        let manager = ModelManager(modelsDirectory: tempDir)
        XCTAssertEqual(try manager.resolveParakeetModel(), expected)
    }

    func testInstalledModelScanSkipsInvalidFiles() throws {
        _ = try writeValidModel(named: "base")
        _ = try writeValidModel(named: "small")
        try Data(repeating: 9, count: 2_000_000).write(to: tempDir.appendingPathComponent("ggml-junk.bin"))
        try Data("hello".utf8).write(to: tempDir.appendingPathComponent("notes.txt"))

        let manager = ModelManager(modelsDirectory: tempDir)
        manager.refreshInstalledModels()
        let expectation = expectation(description: "models published on main queue")
        DispatchQueue.main.async { expectation.fulfill() }
        wait(for: [expectation], timeout: 2)

        XCTAssertEqual(Set(manager.installedModels.map(\.name)), ["base", "small"])
    }

    func testModelNameParsing() {
        XCTAssertEqual(ModelManager.modelName(fromFileName: "ggml-large-v3-turbo.bin"), "large-v3-turbo")
        XCTAssertEqual(ModelManager.modelName(fromFileName: "custom.bin"), "custom")
    }

    func testCatalogURLsPointToOfficialSource() {
        for model in WhisperModelCatalog.models {
            XCTAssertEqual(model.downloadURL.scheme, "https")
            XCTAssertEqual(model.downloadURL.host, "huggingface.co")
            XCTAssertTrue(model.downloadURL.path.contains("ggerganov/whisper.cpp"))
            XCTAssertGreaterThan(model.approxMB, 0)
        }
        let parakeet = ParakeetModelCatalog.recommended
        XCTAssertEqual(parakeet.downloadURL.scheme, "https")
        XCTAssertEqual(parakeet.downloadURL.host, "huggingface.co")
        XCTAssertTrue(parakeet.downloadURL.path.contains("nvidia/parakeet-tdt-0.6b-v3"))
        XCTAssertEqual(parakeet.expectedBytes, 713_975_456)
    }

    func testDefaultModelIsInCatalog() {
        XCTAssertNotNil(WhisperModelCatalog.info(for: WhisperModelCatalog.defaultModelName))
    }

    func testCatalogExposesOnlyThreeRecommendedMultilingualModels() {
        XCTAssertEqual(WhisperModelCatalog.models.map(\.name), ["base", "small", "large-v3-turbo"])
        XCTAssertTrue(WhisperModelCatalog.models.allSatisfy(\.multilingual))
        XCTAssertEqual(WhisperModelCatalog.microphoneDefaultModelName, "base")
        XCTAssertEqual(WhisperModelCatalog.fileDefaultModelName, "large-v3-turbo")
    }
}
