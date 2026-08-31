import Foundation

/// llama-server 二进制下载器：从 llama.cpp 官方 release 拉 macOS arm64 tar.gz，
/// 解压提取 llama-server 可执行文件到 bin 目录。
/// @ai: 复用 ModelDownloader 下载 tar.gz（断点续传/进度）；解压用系统 /usr/bin/tar；
///      提取后 chmod +x 并持久化路径到 AppSettings.llamaServerBinaryPath。
struct LlamaServerDownloader {

    /// 二进制目录（默认 ~/Library/Application Support/wordincontxt/bin）。
    let binDirectory: URL

    /// 二进制最终路径（binDirectory/llama-server）。
    var binaryURL: URL { binDirectory.appendingPathComponent("llama-server") }

    init(binDirectory: URL? = nil) {
        if let binDirectory {
            self.binDirectory = binDirectory
        } else {
            let support = (try? AppIdentity.ensureSupportDirectory())
                ?? FileManager.default.temporaryDirectory
                    .appendingPathComponent(AppIdentity.supportDirName, isDirectory: true)
            self.binDirectory = support
                .appendingPathComponent("bin", isDirectory: true)
        }
    }

    /// 已下载的二进制路径（存在、可执行且依赖动态库齐备才返回 URL，否则 nil）。
    /// 缺 libllama-server-impl.dylib 时启动即 DYLD 崩溃（Library not loaded），视为未完整下载。
    func existingBinary() -> URL? {
        let url = binaryURL
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: url.path) else { return nil }
        guard fm.fileExists(atPath: binaryURL.deletingLastPathComponent()
            .appendingPathComponent("libllama-server-impl.dylib").path) else { return nil }
        return url
    }

    /// 下载 llama-server：用指定 tag 构造下载 URL → 下载 tar.gz → 解压 → 提取 → chmod +x。
    /// @ai: tag 传 nil 时用 fallbackTag（不查 GitHub API，避免国内网络卡死）。
    /// - Parameters:
    ///   - tag: 指定版本 tag（如 "b10453"）；nil 用 LlamaServerRelease.fallbackTag。
    ///   - progress: 进度回调（已下载字节, 总字节），任意线程。
    /// - Returns: 最终二进制路径（调用方负责写入 AppSettings.llamaServerBinaryPath）。
    func download(
        tag: String? = nil,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> URL {
        try ensureDirectory()
        let resolvedTag = tag ?? LlamaServerRelease.fallbackTag
        guard let url = LlamaServerRelease.downloadURL(tag: resolvedTag) else {
            throw LlamaServerError.invalidURL
        }

        // 1) 下载 tar.gz 到临时文件
        let tmpArchive = FileManager.default.temporaryDirectory
            .appendingPathComponent("llama-\(resolvedTag)-bin-macos-arm64.tar.gz")
        let downloader = ModelDownloader()
        _ = try await downloader.download(url: url, to: tmpArchive, progress: progress)
        defer { try? FileManager.default.removeItem(at: tmpArchive) }

        // 2) 解压到临时目录
        let extractDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("llama-extract-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: extractDir) }
        try extract(tarball: tmpArchive, to: extractDir)

        // 3) 找 llama-server 二进制（解压后可能在 bin/llama-server 或嵌套目录）
        guard let extracted = findBinary(in: extractDir) else {
            throw LlamaServerError.binaryNotFound
        }

        // 4) 移动到 bin 目录 + chmod +x
        let dest = binaryURL
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: extracted, to: dest)
        try setExecutable(at: dest)

        // 5) 复制依赖动态库（libllama-server-impl.dylib 等）到 bin 目录
        //    llama-server 经 @rpath 加载这些 dylib，缺失会 DYLD 启动即崩（Library not loaded）。
        try copyDylibs(from: extracted.deletingLastPathComponent(), to: binDirectory)

        return dest
    }

    // MARK: - 内部

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: binDirectory, withIntermediateDirectories: true)
    }

    /// 调系统 tar 解压：`/usr/bin/tar -xzf archive -C dest`。
    private func extract(tarball: URL, to dest: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xzf", tarball.path, "-C", dest.path]
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw LlamaServerError.extractFailed("tar 退出码 \(process.terminationStatus)")
        }
    }

    /// 递归找名为 `llama-server` 的可执行文件（解压后目录结构可能嵌套）。
    private func findBinary(in root: URL) -> URL? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root, includingPropertiesForKeys: [.isExecutableKey]
        ) else { return nil }
        for case let url as URL in enumerator {
            if url.lastPathComponent == "llama-server" {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
                    return url
                }
            }
        }
        return nil
    }

    /// chmod +x（0o755）。
    private func setExecutable(at url: URL) throws {
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: url.path)
        } catch {
            throw LlamaServerError.chmodFailed
        }
    }

    /// 复制 llama-server 同级目录下全部 .dylib 到 bin 目录（同名先删后拷）。
    private func copyDylibs(from srcDir: URL, to destDir: URL) throws {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(
            at: srcDir, includingPropertiesForKeys: nil)) ?? []
        for url in files where url.pathExtension == "dylib" {
            let dest = destDir.appendingPathComponent(url.lastPathComponent)
            if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
            try fm.copyItem(at: url, to: dest)
        }
    }
}
