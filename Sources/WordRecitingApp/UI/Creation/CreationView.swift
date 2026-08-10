import SwiftUI

/// 创作视图：造文 / 改写 两个 Tab。改写先跑通，造文 Tab 留 placeholder（阶段二 LocalLLM）。
struct CreationView: View {
    let world: World
    @State private var tab: CreationTab = .rewrite

    enum CreationTab: String, CaseIterable, Identifiable {
        case rewrite = "改写"
        case generate = "造文"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            content
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(CreationTab.allCases) { t in
                tabButton(t)
            }
            Spacer()
        }
        .padding(.leading, 8)
        .padding(.vertical, 4)
    }

    private func tabButton(_ t: CreationTab) -> some View {
        Button {
            tab = t
        } label: {
            Text(t.rawValue)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .foregroundStyle(tab == t ? .primary : .secondary)
                .background(tab == t ? Color.accentColor.opacity(0.12) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .disabled(t == .generate)
        .help(t == .generate ? "造文模块阶段二上线（LocalLLMGenerator）" : "")
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .rewrite: RewriteView(world: world)
        case .generate:
            placeholder("造文模块阶段二上线（LocalLLMGenerator）")
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
