import SwiftUI

// MARK: - 造文页 列3 选词器：词库选择 / 随机选词（词库清单用 SearchableChecklist 复合组件）

extension GenerateView {

    /// 词库选择器。
    var deckPicker: some View {
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

    /// 随机批量（重新设计）：范围独立一行（segmented），数量 + 随机按钮一行，清空独立一行——
    /// 不再把 5 个控件挤在一行（spec §4.2 选词器列）。
    var randomSelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("随机批量").font(.caption).foregroundStyle(.secondary)
            Picker("范围", selection: $vm.wordFilter) {
                ForEach(WordFilter.allCases) { f in
                    Text(f.label).tag(f)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Picker("选词策略", selection: $vm.wordScoringID) {
                ForEach(WordScoringID.allCases, id: \.rawValue) { id in
                    Text(label(for: id)).tag(id)
                }
            }
            .labelsHidden()
            HStack(spacing: 8) {
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
                    Label(vm.wordScoringID == .random ? "随机选词" : "按策略选词",
                          systemImage: vm.wordScoringID == .random ? "dice" : "target")
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.selectedDeckId == nil || vm.deckCards.isEmpty)
            }
            Text("从「\(vm.wordFilter.label)」的词中按「\(label(for: vm.wordScoringID))」选 \(max(1, vm.randomCount)) 个作为目标词")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    /// 策略中文名（选词器展示）。
    private func label(for id: WordScoringID) -> String {
        switch id {
        case .random: return "随机"
        case .criticalWords: return "临界词优先"
        case .frequencyTier: return "词频优先"
        }
    }
}
