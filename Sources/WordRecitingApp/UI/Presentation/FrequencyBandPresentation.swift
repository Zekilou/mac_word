import Foundation

/// 词频坐标的展示格式化（纯函数，可单测；不放 SwiftUI 依赖）。
/// @ai: 词频只作参考坐标，不代表掌握程度；文案必须诚实。
enum FrequencyBandPresentation {

    /// 词频带标签：1 → "1k 带"；≤0 → "表外"；nil → "—"。
    static func bandLabel(_ band: Int?) -> String {
        guard let band else { return "—" }
        if band <= 0 { return "表外" }
        return "\(band)k 带"
    }

    /// 全表排名文案；0 / nil 视为无坐标。
    static func rankText(_ rank: Int?) -> String? {
        guard let rank, rank > 0 else { return nil }
        return "全表第 \(rank) 位"
    }

    /// tooltip：有坐标时给带 + 排名 + 免责；无坐标时明说。
    static func helpText(band: Int?, rank: Int?) -> String {
        guard let band, band > 0 else {
            return "没有词频坐标（该词不在 BNC/COCA 25k 词族表内）"
        }
        var text = "词频坐标：\(bandLabel(band))"
        if let rankText = rankText(rank) {
            text += "，\(rankText)"
        }
        return text + "（词频只作参考坐标，不代表掌握程度）"
    }
}
