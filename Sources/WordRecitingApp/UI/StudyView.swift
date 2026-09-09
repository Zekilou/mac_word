import SwiftUI

/// 背诵闪卡视图：到期卡片队列，正面单词 / 背面释义，4 键评分。
/// @ai: 评分走 vm.rate → StudySystem；查询走 vm.reload → GraphQueries。
struct StudyView: View {
    @State private var vm: StudyViewModel

    init(world: World) {
        _vm = State(initialValue: StudyViewModel(world: world))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .onAppear { vm.reload() }
    }

    // MARK: - 顶部：统计

    private var header: some View {
        HStack(spacing: 16) {
            if let s = vm.stats {
                statItem("词库", "\(s.totalCards)")
                statItem("已学", "\(s.studiedCards)")
                statItem("今日到期", "\(s.dueCount)")
                statItem("今日已复习", "\(s.reviewedToday)")
                statItem("AGAIN 率", String(format: "%.0f%%", s.againRatio * 100))
            }
            Spacer()
            Button { vm.reload() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("刷新队列")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func statItem(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.headline).monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - 内容：闪卡

    @ViewBuilder
    private var content: some View {
        if let err = vm.errorMessage {
            Text(err).font(.caption).foregroundStyle(.red).padding(8)
        }
        if let card = vm.currentCard {
            flashcardArea(card)
        } else {
            emptyState
        }
    }

    private func flashcardArea(_ card: CardListItem) -> some View {
        VStack(spacing: 20) {
            Spacer()
            // 卡片
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.6))
                    .shadow(radius: 4, y: 2)
                VStack(spacing: 12) {
                    if vm.isFront {
                        Text(card.plainText)
                            .font(.system(size: 34, weight: .semibold))
                        Text("点击翻转查看释义")
                            .font(.caption).foregroundStyle(.tertiary)
                    } else {
                        Text(card.definition ?? "（无释义）")
                            .font(.title2)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                        HStack(spacing: 10) {
                            if let belief = vm.currentBelief {
                                Text(MasteryPresentation.percentText(belief))
                                    .font(.caption.weight(.semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(stateColor(vm.currentBelief))
                                    .help(MasteryPresentation.helpText(belief))
                            } else {
                                Text(MasteryPresentation.noDataText)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            Text(FrequencyBandPresentation.bandLabel(vm.currentBand))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .help(FrequencyBandPresentation.helpText(
                                    band: vm.currentBand, rank: vm.currentRank))
                        }
                        if let summary = vm.currentEventSummary {
                            Text(summary)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Text("点击翻回正面")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .padding(40)
            }
            .frame(maxWidth: 420, minHeight: 200)
            .contentShape(Rectangle())
            .onTapGesture { vm.flip() }
            .animation(.easeInOut(duration: 0.15), value: vm.isFront)

            // 评分按钮
            HStack(spacing: 12) {
                ratingButton("不认识", rating: .again, color: .red) {
                    Image(systemName: "xmark")
                }
                Spacer().frame(width: 16)
                ratingButton("有点难", rating: .hard, color: .orange) {
                    Image(systemName: "minus")
                }
                ratingButton("认识", rating: .good, color: .green) {
                    Image(systemName: "checkmark")
                }
                ratingButton("很熟", rating: .easy, color: .blue) {
                    Image(systemName: "star.fill")
                }
            }

            Text("剩余 \(vm.remaining) 张")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func ratingButton<Icon: View>(
        _ title: String, rating: Rating, color: Color, @ViewBuilder icon: () -> Icon
    ) -> some View {
        Button {
            vm.rate(rating)
        } label: {
            VStack(spacing: 4) {
                icon().font(.system(size: 18))
                Text(title).font(.caption)
                Text(keyLabel(rating))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 76, height: 64)
            .background(color.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(color.opacity(0.4), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .keyboardShortcut(keyForRating(rating), modifiers: [])
    }

    private func keyForRating(_ rating: Rating) -> KeyEquivalent {
        switch rating {
        case .again: return "1"
        case .hard: return "2"
        case .good: return "3"
        case .easy: return "4"
        }
    }

    private func keyLabel(_ rating: Rating) -> String {
        switch rating {
        case .again: return "1"
        case .hard: return "2"
        case .good: return "3"
        case .easy: return "4"
        }
    }

    private func stateColor(_ belief: Double?) -> Color {
        WordMarkState.from(belief: belief, mastery: nil, seenCount: 0).color
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("今天的复习完成！").font(.title3)
            Text("到期卡片已清空。去「创作」生成文章，或等待明天的新卡片。")
            Text("已确认会或模型高置信的词会自动跳过背诵队列。")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
