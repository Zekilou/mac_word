import SwiftUI
import WordRecitingCore

// MARK: - 造文页 Finder 多列骨架（spec §4.2）：列1 主题 / 列2 生成方式 / 列3 选词器 / 列4 生成过程
// 列壳统一用 ColumnShell；各列内部组件拆分到独立文件：选词器 → GenerateView+PickerColumn、
// 配置 → GenerateView+Config、摘要 → GenerateView+ResultSummary。

extension GenerateView {

    // MARK: 列1 主题（260）

    var topicColumn: some View {
        ColumnShell(
            title: "主题",
            content: {
                VStack(alignment: .leading, spacing: Space.xl) {
                    labeled("文章主题") {
                        TextField("可留空（留空时围绕目标词成文）", text: $vm.topic)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.large)
                            .help("可留空：留空时模型围绕所选目标词本身成文，嵌入更自然")
                    }
                    labeled("或手动输入目标词（逗号 / 换行分隔）") {
                        // 弹性撑满剩余高度（随窗口伸缩），内部滚动
                        editor(text: $vm.targetsText, minHeight: 80)
                            .frame(maxHeight: .infinity)
                    }
                    if !vm.pickedWords.isEmpty {
                        SelectedChips(words: vm.pickedWords)
                    }
                }
                .padding(Space.l)
            },
            footer: {
                DButton("生成文章", rank: .primary, icon: "sparkles",
                        fullWidth: true, disabled: vm.isGenerating) {
                    vm.runGenerate()
                }
                if let err = vm.errorMessage {
                    Text(err).font(Type.caption).foregroundStyle(.red)
                }
            })
        .frame(width: Size.sidebarNarrow)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: 列2 生成方式（200）

    var configColumn: some View {
        ColumnShell(title: "生成方式") {
            ScrollView {
                GenerationConfigSection(
                    generatorTier: $vm.generatorTier,
                    apiConfigs: $vm.apiConfigs,
                    activeAPIConfigID: $vm.activeAPIConfigID,
                    onSelectConfig: { config in vm.applyAPIConfig(config) },
                    parameters: vm.modelParameters,
                    sectionLabel: "生成引擎",
                    isThinking: vm.activeConfigIsThinking,
                    embeddingSource: vm.settings.embeddingSource,
                    embeddingModel: vm.settings.embeddingModel,
                    embeddingVerification: vm.settings.embeddingVerification)
                .padding(Space.l)
            }
        }
        .frame(width: Size.paneConfig)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: 列3 选词器（320，可收起）

    var pickerColumn: some View {
        ColumnShell(
            title: "选词器",
            trailing: {
                IconButton(icon: "chevron.compact.left", help: "收起选词器") {
                    showPicker = false
                }
            },
            content: {
                VStack(alignment: .leading, spacing: Space.m) {
                    deckPicker
                    randomSelector
                    if vm.selectedDeckId == nil {
                        Text("先选择一个词库，勾选要背的单词")
                            .font(Type.caption).foregroundStyle(Ink.tertiary)
                    } else {
                        // 词库清单弹性撑满剩余高度（随窗口伸缩），内部滚动
                        SearchableChecklist(
                            items: vm.deckCards,
                            placeholder: "搜索单词或释义",
                            searchKey: { $0.plainText + " " + ($0.definition ?? "") },
                            title: { $0.plainText },
                            subtitle: { $0.definition },
                            isSelected: { vm.pickedLemmaIds.contains($0.lemmaId) },
                            toggle: { card in
                                if vm.pickedLemmaIds.contains(card.lemmaId) {
                                    vm.pickedLemmaIds.remove(card.lemmaId)
                                } else {
                                    vm.pickedLemmaIds.insert(card.lemmaId)
                                }
                            },
                            badge: { card in
                                let state = vm.pickerState(for: card)
                                guard state != .pending else { return nil }
                                if let belief = card.belief {
                                    return (MasteryPresentation.percentText(belief), state.color)
                                }
                                return (state.label, state.color)
                            })
                            .frame(maxHeight: .infinity)
                    }
                }
                .padding(Space.l)
            },
            footer: {
                DButton("清空已选", rank: .secondary, icon: "xmark.circle",
                        disabled: vm.pickedLemmaIds.isEmpty) {
                    vm.pickedLemmaIds.removeAll()
                }
            })
        .frame(width: Size.panePicker)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: 列4 生成过程（260，含结果摘要）

    var processColumn: some View {
        ColumnShell(title: "生成过程") {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.m) {
                    if vm.isGenerating {
                        GenThinkingLogView(
                            log: vm.thinkingLog,
                            stats: vm.streamStats,
                            modelStage: vm.modelStage,
                            fallbackStage: vm.genStage?.label ?? "准备中…",
                            isGenerating: vm.isGenerating,
                            onStop: { vm.stopGenerating() })
                    } else {
                        Text("等待生成…")
                            .font(Type.caption).foregroundStyle(Ink.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, Space.rowV)
                    }
                    Rule()
                    resultSummary
                }
                .padding(Space.l)
            }
        }
        .frame(width: Size.sidebarNarrow)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: - 通用辅助

    func labeled<Content: View>(
        _ title: String, @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text(title).font(Type.caption).foregroundStyle(Ink.secondary)
            content()
        }
    }

    func editor(text: Binding<String>, minHeight: CGFloat) -> some View {
        TextEditor(text: text)
            .frame(minHeight: minHeight)
            .font(Type.body)
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: Radius.chip))
    }
}
