import XCTest
import GRDB
@testable import WordRecitingApp

/// ModelStore（模型文件发现 / 导入 / Ollama manifest 解析）测试。
/// @ai: 全部使用临时目录，不碰真实用户目录。
final class ModelStoreTests: XCTestCase {

    private var tmpDir: URL!
    private var store: ModelStore!

    override func setUpWithError() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        store = ModelStore(modelsDirectory: tmpDir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    private func makeFile(_ name: String, bytes: [UInt8]) throws -> URL {
        let url = tmpDir.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    func testDiscoveredModelsOnlyGguf() throws {
        _ = try makeFile("a.gguf", bytes: [0x00, 0x01, 0x02])
        _ = try makeFile("b.bin", bytes: [0x03])
        _ = try makeFile("c.Q4_K_M.gguf", bytes: [0x04, 0x05])

        let models = store.discoveredModels()
        XCTAssertEqual(models.count, 2)
        XCTAssertEqual(models.map(\.fileName).sorted(), ["a.gguf", "c.Q4_K_M.gguf"])
        XCTAssertEqual(models.first { $0.fileName == "a.gguf" }?.fileSizeBytes, 3)
    }

    func testImportModelCopiesIntoDirectory() throws {
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("outside-\(UUID().uuidString).gguf")
        try Data([0xAB]).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let dest = try store.importModel(from: source)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
        XCTAssertEqual(dest.lastPathComponent, source.lastPathComponent)
        // 内容一致
        XCTAssertEqual(try Data(contentsOf: dest), Data([0xAB]))
    }

    func testImportModelDeduplicatesName() throws {
        // 源文件在模型目录外；模型目录初始为空
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("dup-src-\(UUID().uuidString).gguf")
        try Data([1]).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let d1 = try store.importModel(from: source)
        let d2 = try store.importModel(from: source)
        XCTAssertEqual(d1.lastPathComponent, source.lastPathComponent)
        let base = (source.lastPathComponent as NSString).deletingPathExtension
        XCTAssertEqual(d2.lastPathComponent, "\(base)-1.gguf")
    }

    func testParseManifestsExtractsWeightLayer() throws {
        let manifests = tmpDir.appendingPathComponent("manifests", isDirectory: true)
        let modelDir = manifests.appendingPathComponent("registry.ollama.ai/library/qwen2.5", isDirectory: true)
        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
        let manifest = """
        {"layers":[
          {"mediaType":"application/vnd.ollama.image.model","digest":"sha256:abc123","size":1048576}
        ],"model_format":"gguf"}
        """
        try manifest.write(to: modelDir.appendingPathComponent("0.5b"), atomically: true, encoding: .utf8)

        let candidates = ModelStore.parseManifests(at: manifests)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].fullName, "registry.ollama.ai:library:qwen2.5:0.5b")
        XCTAssertEqual(candidates[0].blobDigest, "sha256:abc123")
        XCTAssertEqual(candidates[0].sizeBytes, 1048576)
    }

    func testParseManifestsSkipsBroken() throws {
        let manifests = tmpDir.appendingPathComponent("manifests", isDirectory: true)
        let d1 = manifests.appendingPathComponent("a/b", isDirectory: true)
        let d2 = manifests.appendingPathComponent("c/d", isDirectory: true)
        try FileManager.default.createDirectory(at: d1, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: d2, withIntermediateDirectories: true)
        try "not json".write(to: d1.appendingPathComponent("latest"), atomically: true, encoding: .utf8)
        try "{\"layers\":[{\"mediaType\":\"application/vnd.ollama.image.embedding\"}]}"
            .write(to: d2.appendingPathComponent("latest"), atomically: true, encoding: .utf8)

        XCTAssertTrue(ModelStore.parseManifests(at: manifests).isEmpty)
    }

    func testExtractOllamaModelCopiesBlob() throws {
        // 构造真实的 blobs 目录结构
        let home = tmpDir.appendingPathComponent("home", isDirectory: true)
        let blobs = home.appendingPathComponent(".ollama/models/blobs", isDirectory: true)
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        let digest = "sha256:feedface"
        let blobName = digest.replacingOccurrences(of: ":", with: "-")
        try Data([0xDE, 0xAD]).write(to: blobs.appendingPathComponent(blobName))

        let modelStore = ModelStore(modelsDirectory: tmpDir)
        let dest = try modelStore.extractOllamaModel(OllamaModelCandidate(
            fullName: "library:qwen2.5:latest", blobDigest: digest, sizeBytes: 2),
            ollamaHome: home)
        XCTAssertEqual(dest.lastPathComponent, "library-qwen2.5-latest.gguf")
        XCTAssertEqual(try Data(contentsOf: dest), Data([0xDE, 0xAD]))
    }

    func testExtractOllamaMissingBlobThrows() {
        XCTAssertThrowsError(try store.extractOllamaModel(OllamaModelCandidate(
            fullName: "x:y", blobDigest: "sha256:missing", sizeBytes: 0)))
    }
}
