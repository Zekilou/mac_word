import Foundation

/// 应用身份常量 + Application Support 目录迁移（1.0.0 改名 WordRecitingApp → wordincontxt）。
/// 所有需要「用户可见品牌名 / 数据目录名」的地方都引用这里，杜绝硬编码字符串散落。
/// @ai: 内部 Swift 模块名仍为 WordRecitingApp（不可轻改，会牵 Package.resolved 和 Bundle.module）。
enum AppIdentity {
    /// 用户可见品牌名：菜单/关于/窗口/Dock 偏好设置中的显示名。
    static let brandName = "wordincontxt"

    /// App 版本号（与 Info.plist CFBundleShortVersionString 保持同步）。
    static let versionShort = "1.0.0"

    /// Build 号（与 Info.plist CFBundleVersion 保持同步）。
    static let versionBuild = "1"

    /// Bundle ID 前缀（反域名风格）。脚本中 Info.plist CFBundleIdentifier 与此一致。
    static let bundleID = "com.zekilou.wordincontxt"

    /// Application Support 下的子目录名（存放 db.sqlite / models / bin 等）。
    /// 升级前旧名 = "WordRecitingApp"；若旧目录存在且新目录不存在，启动时自动迁移。
    static let supportDirName = "wordincontxt"
    static let supportDirLegacy = "WordRecitingApp"
}

extension AppIdentity {
    /// 返回 `~/Library/Application Support/<supportDirName>`，保证目录存在。
    /// 若发现 legacy 目录而新目录不存在，则一次性 mv 整个目录（保留数据库与模型）。
    /// 失败时抛出，由调用方回退到 in-memory。
    @discardableResult
    static func ensureSupportDirectory() throws -> URL {
        let fm = FileManager.default
        let support = try fm.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)

        let legacy = support.appendingPathComponent(supportDirLegacy, isDirectory: true)
        let target = support.appendingPathComponent(supportDirName,    isDirectory: true)

        var isDir: ObjCBool = false
        let legacyExists = fm.fileExists(atPath: legacy.path, isDirectory: &isDir) && isDir.boolValue
        var targetIsDir: ObjCBool = false
        let targetExists = fm.fileExists(atPath: target.path, isDirectory: &targetIsDir) && targetIsDir.boolValue

        // 迁移：legacy 有 / target 无 -> mv（原子，失败回退）
        if legacyExists && !targetExists {
            do {
                try fm.moveItem(at: legacy, to: target)
            } catch {
                // 兜底：拷贝 + 保留原目录（mv 失败通常因跨卷/perms，退化为 copy）
                try fm.copyItem(at: legacy, to: target)
            }
        }

        if !targetExists {
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
        }
        return target
    }
}
