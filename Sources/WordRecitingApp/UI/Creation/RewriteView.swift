import SwiftUI

/// 改写视图：左源文 + 目标词 + 快速改写按钮，中 diff 结果，右生成历史。
/// @ai: 不写 SQL；所有写通过 vm.runRewrite() → World.run(ContentGenSystem)。
struct RewriteView: View {
    @State private var vm: RewriteViewModel

    init(world: World) {
        _vm = State(initialValue: RewriteViewModel(world: world))
    }

    var body: some View {
        HSplitView {
            inputPane.frame(minWidth: 280, idealWidth: 340)
            outputPane.frame(minWidth: 300)
            historyPane.frame(minWidth: 200, idealWidth: 250)
        }
        .onAppear { vm.loadHistory() }
    }

    // MARK: - 左：输入

    private var inputPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            labeled("源文") {
                editor(text: $vm.sourceText, minHeight: 180)
            }
            labeled("目标词（逗号 / 分号 / 换行分隔）") {
                editor(text: $vm.targetsText, minHeight: 70)
            }
            HStack(spacing: 8) {
                Button {
                    Task { await vm.runRewrite() }
                } label: {
                    Label("快速改写", systemImage: "bolt.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.isGenerating)
                if vm.isGenerating { ProgressView().scaleEffect(0.7) }
                Spacer()
            }
            if let err = vm.errorMessage {
                Text(err).font(.caption).foregroundStyle(.red)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    // MARK: - 中：diff 结果

    private var outputPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("改写结果").font(.headline)
                Spacer()
                if let article = vm.resultArticle, !article.spans.isEmpty {
                    Text("\(article.spans.count) 处替换")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            ScrollView {
                if let article = vm.resultArticle {
                    diffText(body: article.body, spans: article.spans)
                } else if let stored = vm.selectedArticle {
                    diffText(body: stored.body, spans: stored.spans)
                } else {
                    Text("点击「快速改写」生成；或从右侧历史选择一篇回看。")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
            }
            legend
        }
        .padding(16)
    }

    private func diffText(body: String, spans: [SpanInfo]) -> some View {
        Text(diffAttributedString(body: body, spans: spans))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
    }

    private var legend: some View {
        HStack(spacing: 12) {
            legendItem("原词", color: .secondary, strike: true)
            legendItem("替换词", color: .accentColor, strike: false)
            legendItem("目标词", color: .orange, strike: false)
            Spacer()
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private func legendItem(_ text: String, color: Color, strike: Bool) -> some View {
        HStack(spacing: 4) {
            Text(text).strikethrough(strike).foregroundStyle(color)
        }
    }

    // MARK: - 右：历史

    private var historyPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("生成历史").font(.headline)
                Spacer()
                Button { vm.loadHistory() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("刷新历史")
            }
            List {
                ForEach(vm.history) { item in
                    Button { vm.selectHistory(item.id) } label: {
                        historyCard(item)
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.plain)
        }
        .padding(16)
    }

    private func historyCard(_ item: ArticleHistoryItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.bodyPreview.isEmpty ? "(空)" : item.bodyPreview)
                .font(.caption)
                .lineLimit(3)
                .foregroundStyle(.primary)
            HStack {
                Text(item.generatorId).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text(item.createdAt, style: .date).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(8)
        .background(vm.selectedArticle?.id == item.id ? Color.accentColor.opacity(0.12) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }

    // MARK: - 复用组件

    private func labeled<Content: View>(
        _ title: String, @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content()
        }
    }

    private func editor(text: Binding<String>, minHeight: CGFloat) -> some View {
        TextEditor(text: text)
            .frame(minHeight: minHeight)
            .font(.body)
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - diff AttributedString 构建

/// 把改写后的 body + spans 渲染成 inline diff AttributedString：
/// - 替换型 span：原词（删除线灰色）+ " → " + 新词（品牌色高亮）
/// - 直达目标词 span：黄色高亮
/// @ai: 偏移基于 body 字符索引；越界 span 安全跳过。
private func diffAttributedString(body: String, spans: [SpanInfo]) -> AttributedString {
    let chars = Array(body)
    var result = AttributedString()
    var cursor = 0
    for span in spans.sorted(by: { $0.start < $1.start }) {
        guard span.start >= cursor, span.start <= chars.count,
              span.end > span.start, span.end <= chars.count else { continue }
        if span.start > cursor {
            result += AttributedString(String(chars[cursor..<span.start]))
        }
        let surface = String(chars[span.start..<span.end])
        if let original = span.replacedFrom {
            var del = AttributedString(original)
            del.strikethroughStyle = .single
            del.foregroundColor = .secondary
            result += del
            var arrow = AttributedString(" → ")
            arrow.foregroundColor = .secondary
            result += arrow
            var rep = AttributedString(surface)
            rep.foregroundColor = .accentColor
            rep.backgroundColor = Color.accentColor.opacity(0.18)
            result += rep
        } else {
            var hi = AttributedString(surface)
            hi.foregroundColor = .orange
            hi.backgroundColor = Color.orange.opacity(0.18)
            result += hi
        }
        cursor = span.end
    }
    if cursor < chars.count {
        result += AttributedString(String(chars[cursor..<chars.count]))
    }
    return result
}
