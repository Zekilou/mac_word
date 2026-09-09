import Foundation

/// 词频族坐标提供者：把词映射到 BNC/COCA 词族带（1k~25k）。
/// @ai: 词频带只是「参考坐标」，不是硬阈值，不得用它直接判定用户会不会。
protocol WordFrequencyProvider: Sendable {
    /// 数据源标识，写入 comp_lemma_frequency.source。
    var sourceName: String { get }
    /// 词族带：1 = 最高频 1k 带 … 25 = 25k 带；表外或未知返回 nil。
    func band(for word: String) -> Int?
    /// 词族在全表中的排序（1 起）；未知返回 nil。
    func rank(for word: String) -> Int?
    /// 每个词族带的词族总数（band → 词族数）。用于词汇量画像的分母。
    var bandFamilyCounts: [Int: Int] { get }
    /// 全表词族总数。
    var totalFamilyCount: Int { get }
}

enum WordFrequencyLoadError: LocalizedError, Equatable {
    case invalidFormat(String)

    var errorDescription: String? {
        switch self {
        case .invalidFormat(let message): return "词频表格式错误：\(message)"
        }
    }
}

/// 全局门面：内置词频表。资源缺失时为 nil，调用方需降级处理。
enum WordFrequency {
    static let bundled: (any WordFrequencyProvider)? =
        BundledWordFrequencyProvider(bundledIn: .module)
}
