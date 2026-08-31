import Foundation

/// 本地 GGUF 模型文件。
struct LocalModel: Identifiable, Equatable {
    var id: String { url.path }
    let url: URL
    let fileName: String
    let fileSizeBytes: Int64

    /// 人类可读大小（如 "4.7 GB"）。
    var sizeDescription: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: fileSizeBytes)
    }
}

/// Ollama 已安装模型候选（可一键提取为 GGUF 供进程内引擎使用）。
struct OllamaModelCandidate: Identifiable, Equatable {
    /// 完整名称（namespace/name:tag）。
    var id: String { fullName }
    let fullName: String
    let blobDigest: String
    let sizeBytes: Int64
}

/// 模型存储管理：进程内模型文件目录（发现/导入）+ 从 Ollama blobs 提取 GGUF。
/// @ai: 纯文件系统逻辑，不依赖 UI；目录可注入便于测试。
struct ModelStore {

    /// 模型文件目录（默认 ~/Library/Application Support/wordincontxt/models）。
    let modelsDirectory: URL

    init(modelsDirectory: URL? = nil) {
        if let modelsDirectory {
            self.modelsDirectory = modelsDirectory
        } else {
            let support = (try? AppIdentity.ensureSupportDirectory())
                ?? FileManager.default.temporaryDirectory
                    .appendingPathComponent(AppIdentity.supportDirName, isDirectory: true)
            self.modelsDirectory = support
                .appendingPathComponent("models", isDirectory: true)
            // 保证目录已创建（首次使用模型下载功能时还会再 create，此处预建避免偶发）
            try? FileManager.default.createDirectory(
                at: self.modelsDirectory, withIntermediateDirectories: true)
        }
    }

    /// 创建模型目录（幂等）。
    func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: modelsDirectory, withIntermediateDirectories: true)
    }

    /// 扫描模型目录中的 .gguf 文件。
    func discoveredModels() -> [LocalModel] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: modelsDirectory, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return [] }
        return files
            .filter { $0.pathExtension.lowercased() == "gguf" }
            .map { url in
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return LocalModel(
                    url: url, fileName: url.lastPathComponent,
                    fileSizeBytes: Int64(size))
            }
            .sorted { $0.fileName < $1.fileName }
    }

    // MARK: - 从 Ollama 提取

    /// 列出 Ollama 已安装模型（可提取的 GGUF）。
    /// 读取 ~/.ollama/models/manifests 下的 manifest JSON，找到模型权重 blob。
    static func ollamaCandidates() -> [OllamaModelCandidate] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let manifests = home
            .appendingPathComponent(".ollama/models/manifests", isDirectory: true)
        return parseManifests(at: manifests)
    }

    /// 解析 manifests 目录中的模型清单（容错：解析失败的文件跳过）。
    /// Ollama manifest 文件以 tag 命名（如 "latest"、"0.5b"），是 manifests 树下的叶子文件。
    static func parseManifests(at manifestsDir: URL) -> [OllamaModelCandidate] {
        let fm = FileManager.default
        guard let entries = try? fm.subpathsOfDirectory(atPath: manifestsDir.path) else { return [] }

        var candidates: [OllamaModelCandidate] = []
        for entry in entries {
            let fullPath = manifestsDir.appendingPathComponent(entry).path
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: fullPath, isDirectory: &isDir), !isDir.boolValue else { continue }
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: fullPath)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            // 模型权重 layer：mediaType 含 "model"
            guard let layers = json["layers"] as? [[String: Any]],
                  let weight = layers.first(where: {
                      ($0["mediaType"] as? String)?.contains("image.model") == true
                  }),
                  let digest = weight["digest"] as? String
            else { continue }
            let size = (weight["size"] as? Int64) ?? (weight["size"] as? Int).map(Int64.init) ?? 0

            // 完整名 = 相对 manifests 的目录（/ → :）+ tag（相对路径无符号链接偏差）
            let dir = (entry as NSString).deletingLastPathComponent
            let tag = (entry as NSString).lastPathComponent
            let fullName = dir.replacingOccurrences(of: "/", with: ":") + ":" + tag
            candidates.append(OllamaModelCandidate(
                fullName: fullName, blobDigest: digest, sizeBytes: size))
        }
        return candidates.sorted { $0.fullName < $1.fullName }
    }

    /// 把 Ollama 模型权重 blob 复制为 models 目录下的 .gguf 文件，返回生成的文件 URL。
    /// - Parameter ollamaHome: Ollama 数据目录（默认 ~/.ollama），便于测试注入。
    func extractOllamaModel(_ candidate: OllamaModelCandidate, ollamaHome: URL? = nil) throws -> URL {
        let fm = FileManager.default
        let home = ollamaHome ?? fm.homeDirectoryForCurrentUser
        // Ollama blob 文件名为 "sha256-<hex>"（连字符），manifest 中 digest 为 "sha256:<hex>"（冒号）
        let blobName = candidate.blobDigest.replacingOccurrences(of: ":", with: "-")
        let blobURL = home
            .appendingPathComponent(".ollama/models/blobs")
            .appendingPathComponent(blobName)
        guard fm.fileExists(atPath: blobURL.path) else {
            throw ModelStoreError.blobMissing(candidate.blobDigest)
        }
        try ensureDirectory()
        // 用文件名段（可能含路径）做安全文件名
        let safeName = candidate.fullName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let dest = modelsDirectory.appendingPathComponent("\(safeName).gguf")
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try fm.copyItem(at: blobURL, to: dest)
        return dest
    }

    // MARK: - 一键下载（hf-mirror）

    /// 从 hf-mirror 一键下载 GGUF 到模型目录，返回最终文件 URL。
    /// - Parameters:
    ///   - modelID: Hugging Face 模型 ID（如 "bartowski/Qwen2.5-7B-Instruct-GGUF"）。
    ///   - fileName: 仓库内的文件名（ModelCatalog.QuantOption.fileName）。
    ///   - progress: 进度回调（已下载字节, 总字节），任意线程调用。
    func downloadModel(
        modelID: String, fileName: String,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> URL {
        try ensureDirectory()
        guard let url = URL(string: HFMirror.resolve(modelID: modelID, filename: fileName)) else {
            throw ModelDownloadError.httpStatus(0)
        }
        let dest = modelsDirectory.appendingPathComponent(fileName)
        let downloader = ModelDownloader()
        return try await downloader.download(url: url, to: dest, progress: progress)
    }

    // MARK: - 导入用户文件

    /// 把用户选择的 .gguf 复制进模型目录（重名自动加序号）。
    func importModel(from source: URL) throws -> URL {
        try ensureDirectory()
        let fm = FileManager.default
        let baseName = source.lastPathComponent
        var dest = modelsDirectory.appendingPathComponent(baseName)
        var counter = 1
        while fm.fileExists(atPath: dest.path) {
            let name = (baseName as NSString).deletingPathExtension
            let ext = (baseName as NSString).pathExtension
            dest = modelsDirectory.appendingPathComponent("\(name)-\(counter).\(ext)")
            counter += 1
        }
        try fm.copyItem(at: source, to: dest)
        return dest
    }
}

/// 模型存储错误。
enum ModelStoreError: LocalizedError, Sendable {
    case blobMissing(String)

    var errorDescription: String? {
        switch self {
        case .blobMissing(let digest):
            return "Ollama 模型权重文件缺失（\(digest)）。请先 `ollama pull` 该模型。"
        }
    }
}
