import Foundation

// MARK: - 一级区（首页 / 数据 / 学习 / 设置）

/// 一级导航区：首页 + 三区架构（spec §3.1）。
/// @ai: 纯导航模型，无业务逻辑；图标供侧边栏展示。
///      `.home` 无二级子区（`ContentView` 会收折二级栏），是默认落地页。
enum AppZone: String, CaseIterable, Identifiable, Sendable {
    case home = "首页"
    case data = "数据"
    case learning = "学习"
    case settings = "设置"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .home: return "house"
        case .data: return "tray.full"
        case .learning: return "graduationcap"
        case .settings: return "gearshape"
        }
    }
}

// MARK: - 二级子区

/// 二级子区：归属某一级区（spec §3.1）。
/// @ai: rawValue 为中文标题；zone 决定它显示在哪一区；icon 供二级栏展示。
enum AppSection: String, CaseIterable, Identifiable, Sendable {
    // 首页
    case home = "首页"
    // 数据
    case decks = "词库"
    case vocabulary = "词汇"
    case synonyms = "同义词"
    case rssSources = "RSS 源"
    case analytics = "分析"
    case dictionary = "词典"
    // 学习
    case creation = "创作"
    case reading = "阅读"
    case study = "背诵"
    // 设置
    case model = "模型"
    case general = "通用"
    case storage = "储存"
    case display = "显示"

    var id: String { rawValue }

    var zone: AppZone {
        switch self {
        case .home: return .home
        case .decks, .vocabulary, .synonyms, .rssSources, .analytics, .dictionary: return .data
        case .creation, .reading, .study: return .learning
        case .model, .general, .storage, .display: return .settings
        }
    }

    var icon: String {
        switch self {
        case .home: return "house"
        case .decks: return "rectangle.stack"
        case .vocabulary: return "person.text.rectangle"
        case .synonyms: return "arrow.left.arrow.right"
        case .rssSources: return "dot.radiowaves.left.and.right"
        case .analytics: return "chart.bar"
        case .dictionary: return "character.book.closed"
        case .creation: return "square.and.pencil"
        case .reading: return "book.closed"
        case .study: return "book"
        case .model: return "cpu"
        case .general: return "sliders.horizontal.3"
        case .storage: return "externaldrive"
        case .display: return "display"
        }
    }
}
