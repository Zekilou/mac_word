import Foundation

/// 内置 GloVe 词向量（随 app 分发，零网络零命令行）。
/// @ai: 数据来自 Stanford GloVe 6B 预训练向量，构建期由 convert_glove.swift 裁剪高频词
///      转成紧凑二进制（见 external_src/），运行时只读加载。OOV 词返回 nil，
///      由上层用词库数据 / LLM 合成伪向量兜底。
final class GloVeEmbeddingProvider: EmbeddingProvider {
    /// 词表：词 → 向量（只读，加载后不变）。
    private let table: [String: [Float]]
    let dimension: Int

    /// 从内存 Data 加载（测试可注入小词表）。
    init(data: Data) throws {
        guard data.count >= 16 else {
            throw EmbeddingLoadError.invalidFormat("文件过短")
        }
        let dim = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: Int32.self) }
        let count = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: Int32.self) }
        self.dimension = Int(dim)
        var table: [String: [Float]] = [:]
        table.reserveCapacity(Int(count))
        var offset = 8
        let bytes = [UInt8](data)
        for _ in 0..<count {
            guard offset + 4 <= bytes.count else {
                throw EmbeddingLoadError.invalidFormat("词表损坏（词长越界）")
            }
            let wordLen = Int(Int32(
                littleEndian: bytes[offset..<offset + 4].withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }))
            offset += 4
            guard offset + wordLen <= bytes.count else {
                throw EmbeddingLoadError.invalidFormat("词表损坏（词字节越界）")
            }
            let word = String(decoding: bytes[offset..<offset + wordLen], as: UTF8.self)
            offset += wordLen
            guard offset + Int(dim) * 4 <= bytes.count else {
                throw EmbeddingLoadError.invalidFormat("词表损坏（向量越界）")
            }
            var vec = [Float](repeating: 0, count: Int(dim))
            for i in 0..<Int(dim) {
                let start = offset + i * 4
                vec[i] = Float(bitPattern: UInt32(
                    littleEndian: bytes[start..<start + 4].withUnsafeBytes {
                        $0.loadUnaligned(as: UInt32.self)
                    }))
            }
            offset += Int(dim) * 4
            table[word] = vec
        }
        self.table = table
    }

    /// 加载内置资源（包内 glove50d.bin）；失败返回 nil（不影响主功能，管线回退 LLM 联想）。
    /// @ai: SPM 资源用 Bundle.module；测试注入 data init。
    convenience init?(bundledIn bundle: Bundle = .module) {
        guard let url = bundle.url(forResource: "glove50d", withExtension: "bin"),
              let data = try? Data(contentsOf: url) else { return nil }
        try? self.init(data: data)
    }

    /// 系统词向量文件加载（external_src 转换产物 / 用户指定路径，测试用）。
    convenience init?(fileAt url: URL) {
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? self.init(data: data)
    }

    func vector(for word: String) async -> [Float]? {
        table[word.lowercased()]
    }
}

/// GloVe 加载错误。
enum EmbeddingLoadError: LocalizedError {
    case invalidFormat(String)

    var errorDescription: String? {
        switch self {
        case .invalidFormat(let msg): return "词向量文件格式错误：\(msg)"
        }
    }
}
