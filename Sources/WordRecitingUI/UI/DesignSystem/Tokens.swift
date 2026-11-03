import SwiftUI
import WordRecitingCore

// MARK: - L1 原始值
//
// @ai: 这是**唯一**允许出现裸数字的地方。页面与组件必须用下面的 L2 语义令牌，
//      禁止再写 `.padding(14)` / `cornerRadius: 3` / `size: 17`。
//
//      改用令牌的理由（不是洁癖）：改前全应用有 17 种 padding、13 种 spacing、
//      7 种圆角、16 种硬编码字号。这些值彼此相差 1–2pt，肉眼分不出层级，
//      于是「谁更靠近谁」只能靠猜——这是界面看起来乱的根因，不是配色问题。
//
//      栅格：4pt 基准，只保留 {2,4,6,8,12,16,24,32}。旧值映射见每行注释。

enum Space {
    /// 2pt —— 行内极小间隙（图标与数字之间）。
    static let xxs: CGFloat = 2
    /// 4pt —— 紧邻元素（徽章内边距）。
    static let xs: CGFloat = 4
    /// 6pt —— 控件内部（chip 内边距）。
    static let s: CGFloat = 6
    /// 8pt —— 列表行内元素间距。
    static let m: CGFloat = 8
    /// 12pt —— 区块内元素间距。
    static let l: CGFloat = 12
    /// 16pt —— 区块之间的间距 / 页面边距。
    static let xl: CGFloat = 16
    /// 24pt —— 大区块分隔。
    static let xxl: CGFloat = 24
    /// 32pt —— 页面级留白。
    static let xxxl: CGFloat = 32
}

enum Radius {
    /// 4pt —— chip / 徽章 / 小标签。
    static let chip: CGFloat = 4
    /// 8pt —— 按钮 / 输入框 / 行容器。
    static let control: CGFloat = 8
    /// 12pt —— 卡片 / 面板。
    static let card: CGFloat = 12
    /// 16pt —— 大面板 / 闪卡。
    static let panel: CGFloat = 16
    /// 圆形（胶囊）。
    static let pill: CGFloat = 999
}

// MARK: - L1 排版

/// 排版令牌。
/// @ai: 优先用**语义字号**（`.body` / `.caption`…），它跟随系统的文本大小设置；
///      只有「大标题」这类需要精确控制的才用固定点数。
///      旧代码里 8/9/12/13/15/16/17/19 这些散落点数全部归并到下面几档。
enum Type {
    /// 34pt —— 页面唯一的视觉焦点（背诵页卡面单词）。
    static let display = Font.system(size: 34, weight: .semibold)
    /// 22pt —— 页面主标题。
    static let title = Font.system(size: 22, weight: .semibold)
    /// 15pt 半粗 —— 区块标题（旧 `.headline` 的视觉重量，但小 2pt 以适配密集界面）。
    static let section = Font.system(size: 15, weight: .semibold)
    /// 13pt 中粗 —— 行标题 / 强调正文。
    static let emphasis = Font.system(size: 13, weight: .medium)
    /// 13pt —— 正文。
    static let body = Font.system(size: 13)
    /// 12pt —— 次要说明。
    static let caption = Font.system(size: 12)
    /// 11pt —— 元信息（时间、来源、计数）。
    static let micro = Font.system(size: 11)
    /// 11pt 等宽 —— 所有会跳动的数字（计数、百分比、剩余量）。
    /// @ai: 数字必须等宽，否则 9→10 会整行抖动。
    static let mono = Font.system(size: 11, design: .monospaced)
    /// 13pt 等宽 —— 需要对齐的正文数字。
    static let monoBody = Font.system(size: 13, design: .monospaced)
    /// 15pt 等宽 —— 音标。
    static let monoLead = Font.system(size: 15, design: .monospaced)
    /// 19pt —— 引语 / 大号正文（词典释义、文章首段）。
    static let lead = Font.system(size: 19)
    /// 16pt —— 阅读正文（文章词块）。
    static let reading = Font.system(size: 16)
    /// 34pt 半粗 —— 页面大数字（分析页主指标）。
    /// 30pt 半粗 —— 次级大数字。
    static let displaySmall = Font.system(size: 30, weight: .semibold)
    /// 20pt 半粗等宽 —— 统计卡数值。
    static let statValue = Font.system(size: 20, weight: .semibold, design: .monospaced)
    /// 24pt 半粗等宽 —— 首页主 KPI 数值。
    static let statValueLarge = Font.system(size: 24, weight: .semibold, design: .monospaced)
    /// 46pt 衬线 —— 背诵卡面单词（全应用唯一的衬线体，刻意保留为焦点）。
    static let displaySerif = Font.system(size: 46, weight: .semibold, design: .serif)
}

// MARK: - L2 语义令牌（页面只能用这层）

extension Space {
    /// 页面外边距。
    static let page = Space.xl
    /// 区块之间的间距。
    static let section = Space.xl
    /// 区块标题与内容之间。
    static let sectionTitle = Space.m
    /// 列表行内元素之间。
    static let row = Space.m
    /// 列表行的上下内边距。
    static let rowV = Space.s
    /// 列表行的左右内边距。
    static let rowH = Space.l
    /// 工具条内边距。
    static let toolbarH = Space.xl
    static let toolbarV = Space.m
    /// chip 的内边距。
    static let chipH = Space.s
    static let chipV = Space.xxs
}

// MARK: - 语义色

/// 文字色阶。
/// @ai: 只用这四档。旧代码有 21 种 opacity 叠加在系统色上，深色模式下完全不可控
///      （0.07 与 0.08 的差别在深底上根本看不见，却让人以为「用了不同的灰」）。
enum Ink {
    /// 主要内容。
    static let primary = Color.primary
    /// 次要说明（标签、辅助文字）。
    static let secondary = Color.secondary
    /// 元信息（时间、来源、占位）。
    static let tertiary = Color.secondary.opacity(0.65)
    /// 反色（彩色底上的文字）。
    static let inverse = Color.white
}

/// 表面色阶（块状背景）。
enum Surface {
    /// 卡片底。
    static let card = Color(nsColor: .textBackgroundColor)
    /// 面板底（比卡片更轻）。
    static let panel = Color(nsColor: .controlBackgroundColor)
    /// 行悬停。
    static let rowHover = Color.primary.opacity(0.04)
    /// 行选中。
    static let rowSelected = Color.accentColor.opacity(0.12)
    /// 工具条（系统材质）。
    static let toolbar = Material.bar
    /// 分隔线。
    static let separator = Color.primary.opacity(0.09)
    /// 输入框底。
    static let field = Color.primary.opacity(0.05)
}

// MARK: 图标尺寸

/// 图标尺寸令牌。
/// @ai: 全应用图标散落在 8/9/10/11/12/13/15/16/17/32/36/40/44/46 十几个尺寸。
///      图标不需要那么多档——只有「行内 / 控件 / 强调 / 空态 / 展示」五种角色。
///      统一后同一层级的图标大小一致，界面才像一套东西。
enum IconSize {
    /// 9pt —— chip / 徽章内的小图标。
    static let inline = Font.system(size: 9)
    /// 11pt —— 按钮、工具条、输入框内。
    static let control = Font.system(size: 11)
    /// 13pt —— 行首、强调图标。
    static let emphasis = Font.system(size: 13)
    /// 32pt —— 空状态。
    static let empty = Font.system(size: 32, weight: .light)
    /// 40pt —— 页面级展示（词库封面、词典词头）。
    static let hero = Font.system(size: 40, weight: .light)
    /// 22pt —— 详情页词头。
    static let detail = Font.system(size: 22, weight: .light)
}

// MARK: 线宽

/// 线宽。
enum Stroke {
    static let hairline: CGFloat = 1
    /// 强调描边（选中态）。
    static let emphasis: CGFloat = 1.5
}


// MARK: - 网格令牌

/// 看板网格的最小卡片宽度。
/// @ai: 只看板区域用。值来自「卡片内最长标签 + 20pt 数字 + 左右内边距」的实测下限：
///      - `stat` 130pt：标签 4 个字 + 4 位数字，再窄就要换行
///      - `kpi` 150pt：首页 KPI 数字更宽（百分比、连续天数）
///      - `chart` 320pt：图表需要横向空间才可读
///      改这些值会直接改变各看板的列数，属于视觉决策，不要随手调。
enum GridMetrics {
    /// 统计小卡（分析页 / 首页 KPI）。
    static let statMin: CGFloat = 130
    /// 首页 KPI 卡（数字更宽）。
    static let kpiMin: CGFloat = 150
    /// 图表卡。
    static let chartMin: CGFloat = 320
}


// MARK: - 尺寸令牌

/// 固定尺寸的角色化命名。
/// @ai: 界面里有一批「必须精确」的宽度——侧栏宽度、列表列宽、图表条宽、圆点直径。
///      它们不能用 Space（那是间距语义），也不该散落成裸数字。
///      命名按**角色**而不是按数值，这样改布局时能搜到所有受影响的点。
enum Size {
    /// 侧栏 / 详情栏。
    static let sidebarNarrow: CGFloat = 260
    static let sidebarWide: CGFloat = 300
    static let sidebarPanel: CGFloat = 380
    /// 列表里的对齐列宽。
    static let colWord: CGFloat = 140
    static let colBand: CGFloat = 56
    static let colPercent: CGFloat = 40
    static let colLabel: CGFloat = 72
    static let colCount: CGFloat = 48
    static let colNarrow: CGFloat = 36
    /// 状态圆点。
    static let dot: CGFloat = 8
    static let dotSmall: CGFloat = 7
    /// 图标按钮命中区。
    static let iconButton: CGFloat = 24
    static let iconSmall: CGFloat = 20
    static let iconTiny: CGFloat = 18
    /// 图表。
    static let chartBar: CGFloat = 12
    static let cellTiny: CGFloat = 10
    /// 分隔线。
    static let hairline: CGFloat = 1
    /// 进度条。
    static let meterShort: CGFloat = 120
    /// 分栏宽度（阅读/创作各列）。
    static let paneArticle: CGFloat = 270
    static let paneColumn: CGFloat = 260
    static let paneConfig: CGFloat = 200
    static let panePicker: CGFloat = 320
    static let panePreview: CGFloat = 250
    static let paneReadText: CGFloat = 280
    /// 弹层尺寸。
    static let sheetWide: CGFloat = 520
    static let sheetTall: CGFloat = 560
    static let sheetNarrow: CGFloat = 380
    static let articleMax: CGFloat = 640
    /// 表单控件。
    static let fieldLabel: CGFloat = 110
    static let fieldControl: CGFloat = 220
    /// 活动胶囊。
    static let capsuleWidth: CGFloat = 184
    static let capsulePadding: CGFloat = 14
    static let capsuleInner: CGFloat = 280
    /// 背诵评分按钮。
    static let ratingButtonW: CGFloat = 84
    static let ratingButtonH: CGFloat = 62
    /// 侧栏图标。
    static let navIcon: CGFloat = 20
    static let navIconSmall: CGFloat = 18
}
