import XCTest
@testable import WordRecitingApp

/// 1.0.0 改名（WordRecitingApp → wordincontxt）后，UserDefaults 里持久化的绝对路径迁移。
/// 背景：目录被 mv 到新名，但 settings.localModelPath / llamaServerBinaryPath 仍是旧前缀，
/// 导致「进程内本地模型无法使用」。
@MainActor
final class ModelPathMigrationTests: XCTestCase {

    // MARK: - 夹具

    private func makeTempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-path-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func makeFile(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: url)
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "model-path-migration-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: - AppIdentity.migrateLegacyPath

    func testMigratesWhenLegacyMissingAndTargetExists() throws {
        let root = try makeTempRoot()
        let legacy = root.appendingPathComponent("WordRecitingApp/models/a.gguf")
        let target = root.appendingPathComponent("wordincontxt/models/a.gguf")
        try makeFile(target)

        XCTAssertEqual(AppIdentity.migrateLegacyPath(legacy.path), target.path)
    }

    func testKeepsLegacyPathWhenItStillExists() throws {
        let root = try makeTempRoot()
        let legacy = root.appendingPathComponent("WordRecitingApp/models/a.gguf")
        try makeFile(legacy)

        XCTAssertEqual(AppIdentity.migrateLegacyPath(legacy.path), legacy.path)
    }

    func testKeepsPathWithoutLegacyMarker() throws {
        let root = try makeTempRoot()
        let path = root.appendingPathComponent("models/a.gguf").path

        XCTAssertEqual(AppIdentity.migrateLegacyPath(path), path)
    }

    func testNilStaysNil() {
        XCTAssertNil(AppIdentity.migrateLegacyPath(nil))
    }

    // MARK: - AppSettings 初始化迁移

    func testInitMigratesStaleLocalModelPath() throws {
        let root = try makeTempRoot()
        let legacy = root.appendingPathComponent("WordRecitingApp/models/a.gguf")
        let target = root.appendingPathComponent("wordincontxt/models/a.gguf")
        try makeFile(target)

        let defaults = makeDefaults()
        defaults.set(legacy.path, forKey: "settings.localModelPath")

        _ = AppSettings(defaults: defaults)

        XCTAssertEqual(defaults.string(forKey: "settings.localModelPath"), target.path)
    }

    func testInitMigratesStaleBinaryPath() throws {
        let root = try makeTempRoot()
        let legacy = root.appendingPathComponent("WordRecitingApp/bin/llama-server")
        let target = root.appendingPathComponent("wordincontxt/bin/llama-server")
        try makeFile(target)

        let defaults = makeDefaults()
        defaults.set(legacy.path, forKey: "settings.llamaServerBinaryPath")

        _ = AppSettings(defaults: defaults)

        XCTAssertEqual(defaults.string(forKey: "settings.llamaServerBinaryPath"), target.path)
    }

    func testInitKeepsValidPath() throws {
        let root = try makeTempRoot()
        let model = root.appendingPathComponent("models/a.gguf")
        try makeFile(model)

        let defaults = makeDefaults()
        defaults.set(model.path, forKey: "settings.localModelPath")

        let settings = AppSettings(defaults: defaults)

        XCTAssertEqual(settings.localModelPath, model.path)
    }

    // MARK: - 可用性判断

    func testLocalModelPathIsUsable() throws {
        let root = try makeTempRoot()
        let model = root.appendingPathComponent("models/a.gguf")
        try makeFile(model)

        let settings = AppSettings(defaults: makeDefaults())
        XCTAssertFalse(settings.localModelPathIsUsable, "未选择时不可用")

        settings.localModelPath = model.path
        XCTAssertTrue(settings.localModelPathIsUsable)

        settings.localModelPath = "/nonexistent/nope.gguf"
        XCTAssertFalse(settings.localModelPathIsUsable, "路径不存在时不可用")
    }

    // MARK: - 未用模型（防误删在用模型）

    func testUnusedModelsRequiresValidSelectedPath() throws {
        let root = try makeTempRoot()
        let store = ModelStore(modelsDirectory: root)
        let a = root.appendingPathComponent("a.gguf")
        let b = root.appendingPathComponent("b.gguf")
        try makeFile(a)
        try makeFile(b)

        XCTAssertEqual(store.unusedModels(selectedPath: a.path).map(\.fileName), ["b.gguf"])
        XCTAssertTrue(store.unusedModels(selectedPath: nil).isEmpty, "未选中时不得返回候选")
        XCTAssertTrue(store.unusedModels(selectedPath: "/nonexistent/x.gguf").isEmpty,
                      "选中路径无效时不得返回候选，避免误删在用模型")
    }
}
