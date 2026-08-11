import SwiftUI

/// 造文主界面：左侧「主题 + 目标词（从词库勾选 / 手动输入）」→ 生成 → 右侧阅读（目标词高亮）+ 历史。
/// @ai: 主路径视图；不写 SQL；生成走 vm.runGenerate() → World.run(ContentGenSystem)。
struct GenerateView: View {
    @State private var vm: GenerateViewModel
    @State private var showAdvisor = false
    @State private var tappedToken: GenerateView.ReadToken?
    /// 左侧输入面板（侧栏）展开状态。
    @State private var showInput = true
    /// 右侧生成历史（侧栏）展开状态。
    @State private var showHistory = true

    init(world: World) {
        _vm = State(initialValue: GenerateViewModel(world: world))
    }

    var body: some View {
        // 左侧输入面板与主内容并列（不悬浮）；右侧历史保持抽屉式覆盖滑入。
        HStack(spacing: 0) {
            if showInput {
                inputPanel.transition(.move(edge: .leading))
                Divider()
            }
            outputPane
        }
        .overlay(alignment: .trailing) {
            if showHistory {
                historyDrawer.transition(.move(edge: .trailing))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.9), value: showInput)
        .animation(.spring(response: 0.32, dampingFraction: 0.9), value: showHistory)
        // 裁剪到内容区边界：右侧抽屉滑入/滑出动画不会盖到左侧全局导航栏
        .clipped()
        .onAppear {
            vm.loadDecks()
            vm.loadHistory()
        }
    }

    // MARK: - 左：输入设置（并列面板）

    /// 左侧输入面板：与主内容并排（HStack 内固定宽度，不悬浮不覆盖）。
    private var inputPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("输入设置").font(.headline)
                Spacer()
                Button { showInput = false } label: {
                    Image(systemName: "chevron.compact.left")
                }
                .buttonStyle(.borderless)
                .help("收起输入面板")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            inputPane
        }
        .frame(width: 380)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    /// 右侧抽屉：生成历史（覆盖式滑入）。
    private var historyDrawer: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("生成历史").font(.headline)
                Spacer()
                Button { vm.loadHistory() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("刷新历史")
                Button { showHistory = false } label: {
                    Image(systemName: "chevron.compact.right")
                }
                .buttonStyle(.borderless)
                .help("收起侧栏")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(vm.history) { item in
                        Button { vm.selectHistory(item.id) } label: {
                            historyCard(item)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .frame(width: 250)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial)
        .shadow(color: .black.opacity(0.22), radius: 10, x: -4, y: 0)
    }

    // MARK: - 左：主题 + 目标词

    private var inputPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("告诉我你想读什么、想背什么").font(.headline)

                labeled("生成方式") {
                    Picker("", selection: $vm.generatorTier) {
                        ForEach(GeneratorTier.allCases) { tier in
                            Text(tier.rawValue).tag(tier)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    switch vm.generatorTier {
                    case .processLocal:
                        processLocalPlaceholder
                    case .remote:
                        llmConfig
                    }
                }

                labeled("文章主题") {
                    TextField("例如：科技趋势、环保、体育", text: $vm.topic)
                        .textFieldStyle(.roundedBorder)
                }

                labeled("从词库选词（推荐）") {
                    deckPicker
                    randomSelector
                    if let deckId = vm.selectedDeckId {
                        wordChecklist(deckId: deckId)
                    } else {
                        Text("先选择一个词库，勾选要背的单词")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }

                labeled("或手动输入目标词（逗号 / 换行分隔）") {
                    editor(text: $vm.targetsText, minHeight: 60)
                }

                if !vm.pickedWords.isEmpty {
                    FlowChips(words: vm.pickedWords)
                }

                HStack(spacing: 8) {
                    Button {
                        vm.runGenerate()
                    } label: {
                        Label("生成文章", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(vm.isGenerating)
                    if vm.isGenerating { progressSection }
                    Spacer()
                }

                if let err = vm.errorMessage {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(16)
        }
    }

    private var deckPicker: some View {
        Picker("词库", selection: Binding(
            get: { vm.selectedDeckId ?? "" },
            set: { newValue in
                guard !newValue.isEmpty else { return }
                vm.selectDeck(newValue)
            }
        )) {
            Text("选择词库…").tag("")
            ForEach(vm.decks) { deck in
                Text("\(deck.name)（\(deck.cardCount) 张）").tag(deck.id)
            }
        }
        .labelsHidden()
    }

    /// 随机选词：范围筛选（学过/未学过/全部）+ 数量 + 一键随机（主选词方式）。
    private var randomSelector: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Picker("范围", selection: $vm.wordFilter) {
                    ForEach(WordFilter.allCases) { f in
                        Text(f.label).tag(f)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 110)
                Text("数量")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("", value: $vm.randomCount, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 56)
                Button {
                    if vm.randomPick().isEmpty {
                        vm.errorMessage = "当前范围没有可选单词"
                    }
                } label: {
                    Label("随机选词", systemImage: "dice")
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.selectedDeckId == nil || vm.deckCards.isEmpty)
                Button {
                    vm.pickedLemmaIds.removeAll()
                } label: {
                    Label("清空", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .disabled(vm.pickedLemmaIds.isEmpty)
                Spacer()
            }
            Text("从「\(vm.wordFilter.label)」的词中随机选 \(max(1, vm.randomCount)) 个作为目标词")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    /// 生成进度：阶段标签 + 步骤进度条（生成→自查→保存 共 3 步，可预测）。
    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(
                value: Double((vm.genStage?.rawValue ?? 0) + 1),
                total: Double(GenStage.allCases.count))
                .progressViewStyle(.linear)
            Text(vm.genStage?.label ?? "正在生成…")
                .font(.caption).foregroundStyle(.secondary)
            if let p = vm.embedWordProgress {
                Text("正在融入 \(p.done + 1)/\(p.total)：\(p.word)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 180)
    }

    /// 生成过程中的实时流式输出（打字机效果）。
    private var liveStreamView: some View {
        Text(vm.streamedText.isEmpty ? "正在生成…" : vm.streamedText)
            .font(.body)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
    }

    /// 远端 LLM 配置：服务类型（Ollama / OpenAI API）+ 模型名 + 地址 + API Key。
    private var llmConfig: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("服务类型", selection: $vm.remoteProvider) {
                ForEach(RemoteProvider.allCases) { p in
                    Text(p.rawValue).tag(p)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: vm.remoteProvider) { _, _ in
                vm.applyProviderDefaults()
            }
            HStack(spacing: 6) {
                TextField("模型名", text: $vm.llmModel)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 140)
                TextField("服务地址", text: $vm.llmBaseURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
            }
            if vm.remoteProvider.needsAPIKey {
                TextField("API Key", text: $vm.llmAPIKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
            }
            Text(vm.remoteProvider.hint)
                .font(.caption2).foregroundStyle(.tertiary)
            HStack(spacing: 8) {
                Button {
                    showAdvisor = true
                } label: {
                    Label("模型顾问：检测硬件并推荐", systemImage: "cpu")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Text("按你的内存推荐模型与量化档")
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.top, 2)
        }
        .sheet(isPresented: $showAdvisor) {
            ModelAdvisorView()
                .frame(width: 520, height: 560)
        }
        .onReceive(NotificationCenter.default.publisher(for: .modelAdvisorApply)) { note in
            if let info = note.userInfo,
               let modelID = info["modelID"] as? String,
               let quant = info["quant"] as? String {
                vm.llmModel = "\(modelID) (\(quant))"
                showAdvisor = false
            }
        }
    }

    /// 进程内本地引擎引导（未选模型时的提示）。
    private var processLocalPlaceholder: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "cpu")
                    .foregroundStyle(.secondary)
                Text("进程内本地引擎：使用本机 CPU/Metal 推理，完全离线。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("请先在「设置」→「进程内模型」选择 GGUF 模型文件（可导入 .gguf 或从 Ollama 一键提取）。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func wordChecklist(deckId: EntityID) -> some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(spacing: 0) {
                ForEach(vm.deckCards) { card in
                    checkboxRow(card)
                }
            }
        }
        .frame(maxHeight: 260)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func checkboxRow(_ card: CardListItem) -> some View {
        Button {
            if vm.pickedLemmaIds.contains(card.lemmaId) {
                vm.pickedLemmaIds.remove(card.lemmaId)
            } else {
                vm.pickedLemmaIds.insert(card.lemmaId)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: vm.pickedLemmaIds.contains(card.lemmaId)
                      ? "checkmark.square.fill" : "square")
                    .foregroundStyle(vm.pickedLemmaIds.contains(card.lemmaId)
                                     ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(card.plainText).font(.body)
                    if let def = card.definition, !def.isEmpty {
                        Text(def)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 中：阅读文章

    private var outputPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { showInput.toggle() } label: {
                    Image(systemName: "sidebar.left")
                }
                .buttonStyle(.borderless)
                .help(showInput ? "收起输入面板" : "展开输入面板")
                Text("生成的文章").font(.headline)
                Spacer()
                if let article = vm.resultArticle, !article.spans.isEmpty {
                    Text("\(article.spans.count) 个目标词")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button { showHistory.toggle() } label: {
                    Image(systemName: "sidebar.right")
                }
                .buttonStyle(.borderless)
                .help(showHistory ? "收起生成历史" : "展开生成历史")
            }
            ScrollView {
                if vm.isGenerating {
                    liveStreamView
                } else if let article = vm.resultArticle {
                    readFlow(body: article.body, spans: article.spans)
                } else if let stored = vm.selectedArticle {
                    readFlow(body: stored.body, spans: stored.spans)
                } else {
                    Text("输入主题并选择目标词后，点击「生成文章」。")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
            }
            resultSummary
            legend
        }
        .padding(16)
        .popover(item: $tappedToken, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) { token in
            readingPopover(token)
        }
    }

    /// 流式渲染：普通文本 + 橙色可点击目标词。
    private func readFlow(body: String, spans: [SpanInfo]) -> some View {
        let segments = Self.readSegments(body: body, spans: spans)
        return ReadFlowLayout(spacing: 4) {
            ForEach(segments) { item in
                switch item.segment {
                case .plain(let text):
                    Text(text).font(.body).textSelection(.enabled)
                case .highlight(let text):
                    Text(text)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                case .target(let token):
                    targetWordChip(token)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
    }

    /// 可点击目标词词块：橙色高亮；已标记的显示为绿色。
    private func targetWordChip(_ token: GenerateView.ReadToken) -> some View {
        let rated = vm.ratedLemmaIds.contains(token.lemmaId)
        return Button {
            tappedToken = token
        } label: {
            Text(token.surface)
                .font(.body.weight(.semibold))
                .foregroundStyle(.orange)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill((rated ? Color.green : Color.orange).opacity(0.22))
                )
        }
        .buttonStyle(.plain)
        .help("查看释义并标记")
    }

    /// 点击目标词后的弹窗：释义 + 认识/不认识。
    private func readingPopover(_ token: GenerateView.ReadToken) -> some View {
        let definition = vm.cardForReading(token.lemmaId)?.definition
        return VStack(alignment: .leading, spacing: 12) {
            Text(token.surface).font(.title3.weight(.semibold))
            Text(definition ?? "词库中暂无释义")
                .font(.body)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Divider()
            HStack(spacing: 8) {
                Button {
                    markReading(token, .good)
                } label: {
                    Label("认识", systemImage: "checkmark.circle")
                }
                .buttonStyle(.bordered)
                Button {
                    markReading(token, .again)
                } label: {
                    Label("不认识", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(14)
        .frame(width: 280, alignment: .leading)
    }

    /// 标记目标词并关闭弹窗（走 StudySystem 调度）。
    private func markReading(_ token: GenerateView.ReadToken, _ rating: Rating) {
        vm.markReadingWord(lemmaId: token.lemmaId, rating: rating)
        tappedToken = nil
    }

    /// 生成结果摘要：目标词覆盖（哪些成功加入/哪些没有）+ 思维链（策略决策 + 写作计划展示）。
    private var resultSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !vm.coverage.isEmpty {
                HStack(spacing: 6) {
                    Text("目标词覆盖").font(.caption).foregroundStyle(.secondary)
                    Text("\(vm.coverage.filter(\.hit).count)/\(vm.coverage.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(vm.coverage.allSatisfy(\.hit) ? .green : .orange)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 70), spacing: 6)],
                          alignment: .leading, spacing: 6) {
                    ForEach(vm.coverage) { c in
                        HStack(spacing: 3) {
                            Image(systemName: c.hit ? "checkmark.circle.fill" : "xmark.circle")
                                .foregroundStyle(c.hit ? Color.green : Color.red)
                            Text(c.word).font(.caption)
                                .help(vm.skippedReason(for: c.word) ?? "未嵌入正文")
                        }
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(c.hit ? Color.green.opacity(0.10) : Color.red.opacity(0.08))
                        .clipShape(Capsule())
                    }
                }
            }
            if vm.lastStrategy != nil {
                DisclosureGroup("生成策略（模型决策链）") {
                    strategyChain
                }
                .font(.caption)
            }
            if let plan = vm.lastPlan, !plan.isEmpty {
                DisclosureGroup("写作计划（模型先联想并打草稿）") {
                    Text(plan)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption)
            }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 策略决策链：生成方式 / 改写窗口 / 嵌入兜底（模型三行决策的可读展示）。
    private var strategyChain: some View {
        HStack(spacing: 8) {
            if let s = vm.lastStrategy {
                strategyChip("生成方式", s.mode.label)
                strategyChip("改写窗口", s.window.label)
                strategyChip("嵌入兜底", s.fallback.label)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func strategyChip(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name).font(.caption2).foregroundStyle(.tertiary)
            Text(value).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color.accentColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var legend: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 3).fill(Color.orange).frame(width: 10, height: 10)
                Text("目标词 · 点击看释义并标记")
                    .font(.caption2)
            }
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 3).fill(Color.green).frame(width: 10, height: 10)
                Text("已标记")
                    .font(.caption2)
            }
            Spacer()
        }
        .foregroundStyle(.secondary)
    }

    // MARK: - 右：历史

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
        VStack(alignment: .leading, spacing: 6) {
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

// MARK: - 目标词标签流式布局

/// 已选目标词的简单换行标签。
struct FlowChips: View {
    let words: [String]
    var body: some View {
        let columns = [GridItem(.adaptive(minimum: 80), spacing: 6)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(words, id: \.self) { w in
                Text(w)
                    .font(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(Capsule())
            }
        }
    }
}

