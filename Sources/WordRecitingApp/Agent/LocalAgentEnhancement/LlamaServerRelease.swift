import Foundation

/// llama.cpp 官方 release 元信息：tag → tar.gz 下载 URL + 最新 tag 查询。
/// @ai: 仅 macOS arm64（Metal 加速）；其他架构后续按需扩展。
///      官方 release 页 https://github.com/ggml-org/llama.cpp/releases
enum LlamaServerRelease {

    /// 兜底 tag：GitHub API 不可达时使用（每发版后手工更新）。
    /// @ai: 当前 b10453（2026-08-16 发布）；用户可手动覆盖。
    static let fallbackTag = "b10453"

    /// release tag → tar.gz 下载 URL（macOS arm64 Metal）。
    /// 文件名规则：`llama-{tag}-bin-macos-arm64.tar.gz`（如 b10453）。
    static func downloadURL(tag: String) -> URL? {
        let s = "https://github.com/ggml-org/llama.cpp/releases/download/\(tag)/llama-\(tag)-bin-macos-arm64.tar.gz"
        return URL(string: s)
    }

    /// 查询最新 release tag（GitHub API，5s 短超时；失败返回 fallbackTag 而非抛错）。
    /// @ai: 国内访问 GitHub API 常超时，短超时 + fallback 保证可用。
    static func latestTag() async -> String {
        guard let url = URL(string: "https://api.github.com/repos/ggml-org/llama.cpp/releases/latest") else {
            return fallbackTag
        }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("wordincontxt/\(AppIdentity.versionShort)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 5   // 5s 短超时，避免卡死
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return fallbackTag
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tag = json["tag_name"] as? String, !tag.isEmpty {
                return tag
            }
            return fallbackTag
        } catch {
            return fallbackTag
        }
    }
}

/// llama-server 相关错误。
enum LlamaServerError: LocalizedError, Sendable {
    case invalidURL
    case archiveMissing
    case extractFailed(String)
    case binaryNotFound
    case chmodFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "llama-server 下载地址无效"
        case .archiveMissing: return "下载的归档文件不存在"
        case .extractFailed(let msg): return "解压失败：\(msg)"
        case .binaryNotFound: return "归档中未找到 llama-server 可执行文件"
        case .chmodFailed: return "设置可执行权限失败"
        }
    }
}
