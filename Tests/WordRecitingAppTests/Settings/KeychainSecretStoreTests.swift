import XCTest
@testable import WordRecitingApp

/// KeychainSecretStore 真实读写测试（用独立 service，不碰生产数据）。
/// @ai: 验证生产机密存储确实落到系统 Keychain 且可跨实例读取。
final class KeychainSecretStoreTests: XCTestCase {

    func testRoundTripReadWriteDelete() throws {
        let service = "wordincontxt.tests.\(UUID().uuidString)"
        let store = KeychainSecretStore(service: service)
        let key = "probe.key"

        XCTAssertNil(store.secret(for: key), "初始应无值")

        store.setSecret("sk-roundtrip", for: key)
        XCTAssertEqual(store.secret(for: key), "sk-roundtrip")

        // 覆盖写（走 SecItemUpdate 分支，不能变成 duplicate item）
        store.setSecret("sk-updated", for: key)
        XCTAssertEqual(store.secret(for: key), "sk-updated")

        // 新实例 + 同 service → 证明真的持久化在 Keychain，而非进程内字典
        let second = KeychainSecretStore(service: service)
        XCTAssertEqual(second.secret(for: key), "sk-updated", "跨实例应能读到（真实持久化）")

        second.setSecret(nil, for: key)
        XCTAssertNil(store.secret(for: key), "删除后应为空")
    }

    func testEmptyStringDeletesValue() throws {
        let store = KeychainSecretStore(service: "wordincontxt.tests.\(UUID().uuidString)")
        store.setSecret("x", for: "k")
        XCTAssertEqual(store.secret(for: "k"), "x")
        store.setSecret("", for: "k")
        XCTAssertNil(store.secret(for: "k"), "空串应视作删除")
    }
}
