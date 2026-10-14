import Foundation
import Security

/// 机密存储抽象：API Key 等敏感值不应落在 UserDefaults（明文 plist）。
/// @ai: 生产用 Keychain（`KeychainSecretStore`）；测试注入 `InMemorySecretStore`，
///      避免单元测试污染真实钥匙串，也避免依赖签名/授权环境。
protocol SecretStore: Sendable {
    /// 读取机密；不存在返回 nil。
    func secret(for key: String) -> String?
    /// 写入机密；value 为 nil 表示删除。
    func setSecret(_ value: String?, for key: String)
}

/// 进程内机密存储（测试用；不落盘）。
final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    init() {}

    func secret(for key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    func setSecret(_ value: String?, for key: String) {
        lock.lock(); defer { lock.unlock() }
        if let value, !value.isEmpty {
            storage[key] = value
        } else {
            storage.removeValue(forKey: key)
        }
    }

    /// 按标识复用同一实例：同一个 UserDefaults suite 对应的多个 AppSettings 必须共享
    /// 同一个机密存储，否则「写设置 → 新建实例 → 读设置」的持久化语义在测试下会失效。
    /// @ai: 测试清理时调 `resetRegistry()`（或让其随进程结束自然回收）。
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [String: InMemorySecretStore] = [:]

    static func shared(identifier: String) -> InMemorySecretStore {
        registryLock.lock(); defer { registryLock.unlock() }
        if let existing = registry[identifier] { return existing }
        let store = InMemorySecretStore()
        registry[identifier] = store
        return store
    }

    /// 清空注册表（测试 tearDown 用，避免跨用例串味）。
    static func resetRegistry() {
        registryLock.lock(); defer { registryLock.unlock() }
        registry.removeAll()
    }
}

/// Keychain 机密存储（生产用）。
/// @ai: 用 kSecClassGenericPassword，service = bundle id（未打包时退回品牌名）。
///      **失败时静默降级**（读写返回 nil / 忽略写入）而不抛错或崩溃——
///      未签名/受限环境下 Keychain 可能不可用，此时应用仍能运行，
///      只是会退回到 UserDefaults 兼容路径（见 AppSettings.llmAPIKey）。
///      可访问性用 kSecAttrAccessibleAfterFirstUnlock：应用自身随时可读，
///      且不随 Time Machine/iCloud 钥匙串在设备间同步（纯本地应用，不外泄）。
final class KeychainSecretStore: SecretStore, @unchecked Sendable {
    static let shared = KeychainSecretStore()

    private let service: String

    init(service: String = Bundle.main.bundleIdentifier ?? AppIdentity.supportDirName) {
        self.service = service
    }

    private func query(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    func secret(for key: String) -> String? {
        var q = query(for: key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text
    }

    func setSecret(_ value: String?, for key: String) {
        guard let value, !value.isEmpty else {
            SecItemDelete(query(for: key) as CFDictionary)
            return
        }
        let data = Data(value.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        // 先尝试更新，不存在再新增（避免 errSecDuplicateItem）
        let updateStatus = SecItemUpdate(query(for: key) as CFDictionary,
                                         attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var add = query(for: key)
            add.merge(attributes) { _, new in new }
            SecItemAdd(add as CFDictionary, nil)
        }
    }
}
