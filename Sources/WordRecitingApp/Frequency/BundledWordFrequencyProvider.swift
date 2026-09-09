import Foundation

/// 内置精简词频族表：从 bundle 的 word_families.json 加载。
/// 文件格式：
/// {
///   "source": "bnc-coca-25k",
///   "families": [ { "rank": 1, "band": 1, "members": ["the", "a", "an"] } ]
/// }
final class BundledWordFrequencyProvider: WordFrequencyProvider {
    let sourceName: String
    private let bandByWord: [String: Int]
    private let rankByWord: [String: Int]
    let bandFamilyCounts: [Int: Int]
    let totalFamilyCount: Int

    private struct Payload: Decodable {
        struct Family: Decodable {
            let rank: Int
            let band: Int
            let members: [String]
        }
        let source: String
        let families: [Family]
    }

    init(data: Data) throws {
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw WordFrequencyLoadError.invalidFormat("\(error)")
        }
        var bands: [String: Int] = [:]
        var ranks: [String: Int] = [:]
        var familyCounts: [Int: Int] = [:]
        for family in payload.families {
            familyCounts[family.band, default: 0] += 1
            for member in family.members {
                let key = member.lowercased()
                if let existing = ranks[key], existing <= family.rank { continue }
                ranks[key] = family.rank
                bands[key] = family.band
            }
        }
        self.sourceName = payload.source
        self.bandByWord = bands
        self.rankByWord = ranks
        self.bandFamilyCounts = familyCounts
        self.totalFamilyCount = payload.families.count
    }

    /// 从 bundle 加载；资源不存在时返回 nil（优雅降级）。
    convenience init?(bundledIn bundle: Bundle = .module) {
        guard let url = bundle.url(forResource: "word_families", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        try? self.init(data: data)
    }

    convenience init?(fileAt url: URL) {
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? self.init(data: data)
    }

    func band(for word: String) -> Int? { bandByWord[word.lowercased()] }
    func rank(for word: String) -> Int? { rankByWord[word.lowercased()] }
}
