import SwiftUI

/// 应用主壳：左栏持久导航（hamburger 可收折）+ 右内容区（次级 Tab + 顶部 Edit 工具栏）。
/// @ai: 严格贴合 user_profile：根层透明浮于 NSVisualEffectView 之上；背诵/分析阶段二/三启用。
struct ContentView: View {
    let world: World
    @State private var sidebarCollapsed = false
    @State private var section: AppSection = .creation

    enum AppSection: String, CaseIterable, Identifiable {
        case decks = "词库"
        case creation = "创作"
        case study = "背诵"
        case analytics = "分析"
        var id: String { rawValue }
        var enabled: Bool {
            switch self {
            case .decks, .creation: return true
            case .study, .analytics: return false
            }
        }
        var hint: String {
            switch self {
            case .decks, .creation: return ""
            case .study: return "阶段二"
            case .analytics: return "阶段三"
            }
        }
        var icon: String {
            switch self {
            case .decks: return "rectangle.stack"
            case .creation: return "square.and.pencil"
            case .study: return "book"
            case .analytics: return "chart.bar"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: sidebarCollapsed ? 48 : 200)
                .animation(.easeInOut(duration: 0.2), value: sidebarCollapsed)
            Divider()
            mainArea
        }
    }

    // MARK: - 侧栏

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: { withAnimation { sidebarCollapsed.toggle() } }) {
                    Image(systemName: "line.3.horizontal")
                        .frame(width: 20)
                }
                .buttonStyle(.borderless)
                .help("收起 / 展开侧栏")
                if !sidebarCollapsed {
                    Text("WordReciting").font(.headline)
                    Spacer()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()
            VStack(spacing: 2) {
                ForEach(AppSection.allCases) { s in
                    navRow(s)
                }
            }
            .padding(8)
            Spacer()
        }
    }

    private func navRow(_ s: AppSection) -> some View {
        Button {
            if s.enabled { section = s }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: s.icon)
                    .frame(width: 20)
                    .foregroundStyle(s.enabled ? .primary : .secondary)
                if !sidebarCollapsed {
                    Text(s.rawValue)
                        .foregroundStyle(s.enabled ? .primary : .secondary)
                    Spacer()
                    if !s.enabled {
                        Text(s.hint).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(section == s ? Color.accentColor.opacity(0.15) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(!s.enabled)
    }

    // MARK: - 主区

    private var mainArea: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            content
        }
    }

    private var topBar: some View {
        HStack {
            Text(section.rawValue).font(.title3).fontWeight(.semibold)
            Spacer()
            Button("Edit") {}
                .buttonStyle(.bordered)
                .disabled(true)
                .help("编辑模式（阶段二启用）")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        switch section {
        case .decks: DeckManagerView(world: world)
        case .creation: CreationView(world: world)
        case .study: placeholder("背诵模块阶段二上线")
        case .analytics: placeholder("分析模块阶段三上线")
        }
    }

    private func placeholder(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
