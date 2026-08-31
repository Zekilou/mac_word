import Foundation

/// RSS 源：内置常用源 + 用户自填（UserDefaults 持久化）。
struct RSSSource: Identifiable, Sendable, Equatable, Codable {
    let id: String
    let title: String
    let urlString: String
    /// true = 内置（不可删）；false = 用户自填。
    let builtIn: Bool

    var url: URL? { URL(string: urlString) }
}

/// RSS 源仓库：内置列表 + 用户自定义（增删、持久化）。
/// @ai: 内置源来自 feedspot 等目录的常用英文新闻/科技源；用户源存 UserDefaults。
@MainActor
@Observable
final class RSSSourceStore {
    static let shared = RSSSourceStore()
    private let defaults: UserDefaults
    private static let customKey = "rss.customSources.v1"

    /// 内置源（https://rss.feedspot.com/world_news_rss_feeds/ 目录精选，均选自该目录标注的可用 feed）。
    /// @ai: Reuters / AP / DW 官方已停 RSS feed（feedspot 目录无 RSS 地址），内置列表只放有真实 feed 的源。
    static let builtIn: [RSSSource] = [
        .init(id: "bbc-world", title: "BBC 世界新闻",
              urlString: "https://feeds.bbci.co.uk/news/world/rss.xml", builtIn: true),
        .init(id: "guardian-world", title: "The Guardian 世界",
              urlString: "https://www.theguardian.com/world/rss", builtIn: true),
        .init(id: "aljazeera", title: "Al Jazeera 全球",
              urlString: "https://www.aljazeera.com/xml/rss/all.xml", builtIn: true),
        .init(id: "nyt-world", title: "NYT 世界",
              urlString: "https://rss.nytimes.com/services/xml/rss/nyt/World.xml", builtIn: true),
        .init(id: "npr-world", title: "NPR 世界",
              urlString: "https://feeds.npr.org/1004/rss.xml", builtIn: true),
        .init(id: "cnn-world", title: "CNN 世界",
              urlString: "https://rss.cnn.com/rss/edition_world.rss", builtIn: true),
        .init(id: "verge", title: "The Verge 科技",
              urlString: "https://www.theverge.com/rss/index.xml", builtIn: true),
        .init(id: "ars", title: "Ars Technica 科技",
              urlString: "https://feeds.arstechnica.com/arstechnica/index", builtIn: true),
        .init(id: "sciencedaily", title: "ScienceDaily 科普",
              urlString: "https://www.sciencedaily.com/rss/top/science.xml", builtIn: true),
    ]

    /// 全部源（内置 + 用户自填）。
    private(set) var all: [RSSSource] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    /// 用户自填源。
    var custom: [RSSSource] { all.filter { !$0.builtIn } }

    /// 添加用户源（URL 需为 http(s) 有效值）；返回是否成功。
    @discardableResult
    func addCustom(title: String, urlString: String) -> Bool {
        guard let url = URL(string: urlString),
              let scheme = url.scheme,
              (scheme == "http" || scheme == "https"),
              url.host != nil else { return false }
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        let src = RSSSource(
            id: "custom-\(UUID().uuidString)",
            title: trimmed.isEmpty ? url.host ?? urlString : trimmed,
            urlString: urlString, builtIn: false)
        all.append(src)
        persist()
        return true
    }

    /// 删除用户源（内置不可删）。
    func remove(_ id: String) {
        all.removeAll { $0.id == id }
        persist()
    }

    // MARK: - 持久化

    private func load() {
        let custom = (try? JSONDecoder().decode(
            [RSSSource].self, from: defaults.data(forKey: Self.customKey) ?? Data()))
            ?? []
        all = Self.builtIn + custom
    }

    private func persist() {
        let custom = all.filter { !$0.builtIn }
        let data = (try? JSONEncoder().encode(custom)) ?? Data()
        defaults.set(data, forKey: Self.customKey)
    }
}
