import Foundation

/// Hugging Face 国内镜像：hf-mirror.com。
/// 本软件面向国内用户，下载 GGUF 模型时走镜像（官方域名直连常被墙/超时）。
/// @ai: resolve 拼接镜像 URL；镜像仅用于下载，运行时仍全部本地。
enum HFMirror {
    /// 镜像根地址。
    static let base = "https://hf-mirror.com"

    /// 构造镜像下载 URL：hf-mirror.com/{modelID}/resolve/main/{filename}
    static func resolve(modelID: String, filename: String) -> String {
        "\(base)/\(modelID)/resolve/main/\(filename)"
    }

    /// 模型详情页镜像地址（供用户查看 README / 其他量化档）。
    static func modelPage(modelID: String) -> String {
        "\(base)/\(modelID)"
    }
}
