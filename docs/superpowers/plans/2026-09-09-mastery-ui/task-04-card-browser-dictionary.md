# Task 4：卡片浏览 + 词典改造

**Files:**
- Modify: `Sources/WordRecitingApp/UI/CardBrowserView.swift`
- Create: `Sources/WordRecitingApp/UI/Presentation/EventTimelinePresenter.swift`
- Create: `Sources/WordRecitingApp/UI/Components/EventTimelineView.swift`
- Modify: `Sources/WordRecitingApp/UI/SystemDictionaryViewModel.swift`
- Modify: `Sources/WordRecitingApp/UI/SystemDictionaryView.swift`
- Test: `Tests/WordRecitingAppTests/UI/Presentation/EventTimelinePresenterTests.swift`（新建）
- Test: `Tests/WordRecitingAppTests/Dictionary/SystemDictionaryTests.swift`（追加）

**依赖：** Task 1。

**审计对照（README 表格第 4、5 行）：**
- 卡片浏览：`masteryBadge` 只看 mastery → 改概率优先，徽章显示概率档位。
- 词典：只有「标为会」按钮 → 加概率 / 词频带 / 事件时间线。

---

- [ ] **Step 1: 写失败测试**

**1a. 新建 `Tests/WordRecitingAppTests/UI/Presentation/EventTimelinePresenterTests.swift`：**

```swift
import XCTest
@testable import WordRecitingApp

final class EventTimelinePresenterTests: XCTestCase {

    func testKindLabels() {
        XCTAssertEqual(EventTimelinePresenter.kindLabel(.seen), "出现过")
        XCTAssertEqual(EventTimelinePresenter.kindLabel(.lookup), "查词")
        XCTAssertEqual(EventTimelinePresenter.kindLabel(.markKnown), "标记会")
        XCTAssertEqual(EventTimelinePresenter.kindLabel(.markUnknown), "标记不会")
        XCTAssertEqual(EventTimelinePresenter.kindLabel(.quizCorrect), "答对")
        XCTAssertEqual(EventTimelinePresenter.kindLabel(.quizWrong), "答错")
    }

    func testRegionLabels() {
        XCTAssertEqual(EventTimelinePresenter.regionLabel("study"), "复习")
        XCTAssertEqual(EventTimelinePresenter.regionLabel("rss"), "RSS 阅读")
        XCTAssertEqual(EventTimelinePresenter.regionLabel("generate"), "生成文章")
        XCTAssertEqual(EventTimelinePresenter.regionLabel("dictionary"), "词典")
        XCTAssertEqual(EventTimelinePresenter.regionLabel("init"), "词汇初始化")
        XCTAssertEqual(EventTimelinePresenter.regionLabel("unknown"), "其他")
    }

    func testItemsMapTrustToActive() {
        let now = Date()
        let rows = [
            GraphQueries.WordEventRow(eventId: "E1", lemmaId: "L1", regionId: "R1",
                                      kind: "mark_known", trust: 1.0, occurredAt: now),
            GraphQueries.WordEventRow(eventId: "E2", lemmaId: "L1", regionId: "R2",
                                      kind: "seen", trust: 0.0, occurredAt: now)
        ]
        let items = EventTimelinePresenter.items(
            from: rows, regionKinds: ["R1": "dictionary", "R2": "rss"], now: now)

        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].kindLabel, "标记会")
        XCTAssertEqual(items[0].regionLabel, "词典")
        XCTAssertTrue(items[0].isActive)
        XCTAssertEqual(items[1].trustLabel, "被动")
        XCTAssertFalse(items[1].isActive)
    }

    func testUnknownEventKindFallsBackToRawValue() {
        let rows = [GraphQueries.WordEventRow(
            eventId: "E1", lemmaId: "L1", regionId: "R1",
            kind: "legacy", trust: 1.0, occurredAt: Date())]
        XCTAssertEqual(EventTimelinePresenter.items(from: rows).first?.kindLabel, "legacy")
    }

    func testRelativeText() {
        let now = Date()
        XCTAssertEqual(EventTimelinePresenter.relativeText(
            from: now.addingTimeInterval(-10), now: now), "刚刚")
        XCTAssertEqual(EventTimelinePresenter.relativeText(
            from: now.addingTimeInterval(-120), now: now), "2 分钟前")
        XCTAssertEqual(EventTimelinePresenter.relativeText(
            from: now.addingTimeInterval(-7200), now: now), "2 小时前")
        XCTAssertEqual(EventTimelinePresenter.relativeText(
            from: now.addingTimeInterval(-172800), now: now), "2 天前")
    }
}
```

**1b. 在 `Tests/WordRecitingAppTests/Dictionary/SystemDictionaryTests.swift` 末尾追加：**

```swift
    // MARK: - 概率主口径 + 词画像

    private func seedProfileLemma() throws {
        let now = Date()
        try world.registry.insertNode(id: "L1", kind: .lemma, createdAt: now)
        try world.registry.upsertComponent(TextComponent(
            entityId: "L1", textA: "abandon", textB: nil, language: nil))
        try world.registry.upsertComponent(UserKnownComponent(
            entityId: "L1", mastery: 2.0, seenCount: 0,
            source: "init", updatedAt: now))
        try world.registry.upsertComponent(LemmaFrequencyComponent(
            entityId: "L1", band: 2, freqRank: 1001, source: "test"))
        try world.registry.upsertComponent(MasteryBeliefComponent(
            entityId: "L1", belief: 0.10, opportunities: 4,
            lastEventAt: now, updatedAt: now, paramsVersion: "bkt-1"))
        try world.run(RegionSystem(), context: .record(
            lemmaIds: ["L1"], region: .dictionary(), kind: .lookup,
            trust: 1.0, detail: nil))
    }

    func testWordStateIsDrivenByBelief() async throws {
        try seedProfileLemma()
        let vm = SystemDictionaryViewModel(
            world: world,
            lookupOverride: { word in
                DictionaryEntry(word: word, phonetic: nil,
                                partOfSpeech: nil, definition: "d")
            })

        await vm.search("abandon")

        // 用户显式标了「会」，但概率 0.10 → 判定为不会
        XCTAssertEqual(vm.wordState, .unknown)
    }

    func testProfileLoadsBeliefBandAndEvents() async throws {
        try seedProfileLemma()
        let vm = SystemDictionaryViewModel(
            world: world,
            lookupOverride: { word in
                DictionaryEntry(word: word, phonetic: nil,
                                partOfSpeech: nil, definition: "d")
            })

        await vm.search("abandon")

        XCTAssertEqual(vm.belief ?? 0, 0.10, accuracy: 0.0001)
        XCTAssertEqual(vm.frequencyBand, 2)
        XCTAssertEqual(vm.frequencyRank, 1001)
        XCTAssertEqual(vm.recentEvents.count, 1)
        XCTAssertEqual(vm.recentEvents.first?.kindLabel, "查词")
        XCTAssertEqual(vm.recentEvents.first?.regionLabel, "词典")
    }

    func testProfileClearedForUnknownWord() async throws {
        let vm = SystemDictionaryViewModel(
            world: world,
            lookupOverride: { word in
                DictionaryEntry(word: word, phonetic: nil,
                                partOfSpeech: nil, definition: "d")
            })

        await vm.search("zzzzz")

        XCTAssertNil(vm.belief)
        XCTAssertNil(vm.frequencyBand)
        XCTAssertTrue(vm.recentEvents.isEmpty)
    }
```

> `DictionaryEntry` 构造参数顺序按该类型的实际成员顺序调整。

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter EventTimelinePresenterTests 2>&1 | tail -6`
Run: `swift test --filter SystemDictionaryTests 2>&1 | tail -6`
Expected: FAIL（缺类型 / 缺属性）。

- [ ] **Step 3: 实现**

**3a. 新建 `Sources/WordRecitingApp/UI/Presentation/EventTimelinePresenter.swift`：**

```swift
import Foundation

/// 事件时间线的展示模型。
struct EventTimelineItem: Sendable, Equatable, Identifiable {
    var id: EntityID { eventId }
    let eventId: EntityID
    /// 事件种类中文（未知 rawValue 原样显示）。
    let kindLabel: String
    /// 来源上下文中文。
    let regionLabel: String
    /// "主动" / "被动"。
    let trustLabel: String
    /// 是否高可信（trust ≥ 0.5）。
    let isActive: Bool
    let occurredAt: Date
    /// 相对时间文案。
    let timeText: String
}

/// 词事件 → 时间线展示模型（纯函数，可单测）。
enum EventTimelinePresenter {

    static func kindLabel(_ kind: WordEventKind) -> String {
        switch kind {
        case .seen: return "出现过"
        case .lookup: return "查词"
        case .markKnown: return "标记会"
        case .markUnknown: return "标记不会"
        case .quizCorrect: return "答对"
        case .quizWrong: return "答错"
        }
    }

    static func regionLabel(_ kind: String) -> String {
        guard let kind = RegionKind(rawValue: kind) else { return "其他" }
        switch kind {
        case .study: return "复习"
        case .rss: return "RSS 阅读"
        case .generate: return "生成文章"
        case .dictionary: return "词典"
        case .initSession: return "词汇初始化"
        }
    }

    /// - Parameter regionKinds: region id → RegionKind.rawValue（调用方批量查好）。
    static func items(from rows: [GraphQueries.WordEventRow],
                      regionKinds: [EntityID: String] = [:],
                      now: Date = Date()) -> [EventTimelineItem] {
        rows.map { row in
            let kind = WordEventKind(rawValue: row.kind)
            let active = row.trust >= 0.5
            return EventTimelineItem(
                eventId: row.eventId,
                kindLabel: kind.map(kindLabel) ?? row.kind,
                regionLabel: regionLabel(regionKinds[row.regionId] ?? ""),
                trustLabel: active ? "主动" : "被动",
                isActive: active,
                occurredAt: row.occurredAt,
                timeText: relativeText(from: row.occurredAt, now: now))
        }
    }

    static func relativeText(from date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "刚刚" }
        if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前" }
        if seconds < 86400 { return "\(Int(seconds / 3600)) 小时前" }
        if seconds < 86400 * 30 { return "\(Int(seconds / 86400)) 天前" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
```

**3b. 新建 `Sources/WordRecitingApp/UI/Components/EventTimelineView.swift`：**

```swift
import SwiftUI

/// 词事件时间线（最近若干条）。
struct EventTimelineView: View {
    let items: [EventTimelineItem]
    var emptyText = "还没有事件记录"

    var body: some View {
        if items.isEmpty {
            Text(emptyText)
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(items) { item in
                    row(item)
                }
            }
        }
    }

    private func row(_ item: EventTimelineItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: item.isActive ? "hand.tap" : "eye")
                .font(.caption2)
                .foregroundStyle(item.isActive ? Color.accentColor : Color.secondary)
                .frame(width: 14)
            Text(item.kindLabel).font(.caption)
            Text(item.regionLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(item.trustLabel)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 4)
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 3))
            Spacer()
            Text(item.timeText)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
    }
}
```

**3c. `CardBrowserView.swift` 的 `masteryBadge(_:)` 整体替换：**

```swift
    /// 掌握度胶囊：概率优先（无概率回退显式标记）；无记录不显示，避免全库灰点噪音。
    @ViewBuilder
    private func masteryBadge(_ card: CardListItem) -> some View {
        let state = WordMarkState.from(
            belief: card.belief, mastery: card.mastery, seenCount: card.seenCount)
        if state != .pending {
            Text(state.label)
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(state.color.opacity(0.18))
                .foregroundStyle(state.color)
                .clipShape(Capsule())
                .help(badgeHelp(card, state: state))
        }
    }

    private func badgeHelp(_ card: CardListItem, state: WordMarkState) -> String {
        if let belief = card.belief {
            return "\(MasteryPresentation.helpText(belief))；当前档位：\(state.label)"
        }
        return "全局掌握度（用户显式标记）：\(state.label)"
    }
```

**3d. `SystemDictionaryViewModel.swift`：**

- 状态区追加：

```swift
    /// 词画像：BKT 后验概率（nil = 尚无事件）。
    var belief: Double?
    /// 词频带 / 全表排名。
    var frequencyBand: Int?
    var frequencyRank: Int?
    /// 最近 5 条词事件（时间倒序）。
    var recentEvents: [EventTimelineItem] = []
```

- `refreshState(for:)` 整体替换：

```swift
    func refreshState(for word: String) {
        do {
            let lemmaID = try world.graph.findLemmaId(byTextA: word)
            let mastery: Double? = lemmaID.flatMap { id in
                (try? world.graph.lemmaMastery(lemmaId: id)) ?? nil
            }
            let seenCounts = (try? world.graph.allLemmaSeenCounts()) ?? [:]
            let seen: Int = lemmaID.flatMap { seenCounts[$0] } ?? 0
            belief = lemmaID.flatMap { try? world.graph.masteryBelief(lemmaId: $0) } ?? nil
            wordState = WordMarkState.from(belief: belief, mastery: mastery, seenCount: seen)
            loadProfile(lemmaID: lemmaID)
        } catch {
            wordState = .pending
            clearProfile()
        }
    }

    /// 词画像：词频坐标 + 最近事件。
    private func loadProfile(lemmaID: EntityID?) {
        guard let lemmaID else {
            clearProfile()
            return
        }
        let frequency = try? world.graph.lemmaFrequency(lemmaId: lemmaID)
        frequencyBand = frequency?.band
        frequencyRank = frequency?.freqRank

        let rows = (try? world.graph.wordEvents(lemmaId: lemmaID, limit: 5)) ?? []
        let regionIDs = Array(Set(rows.map(\.regionId)))
        let kinds = (try? world.graph.regionKinds(regionIds: regionIDs)) ?? [:]
        recentEvents = EventTimelinePresenter.items(from: rows, regionKinds: kinds)
    }

    private func clearProfile() {
        belief = nil
        frequencyBand = nil
        frequencyRank = nil
        recentEvents = []
    }
```

**3e. `SystemDictionaryView.swift` 的 `entryCard(_:vm:)`：**

- 按钮文案与 tooltip 改：

```swift
                    Button {
                        vm.toggleMark(entry.word)
                    } label: {
                        Text(vm.wordState == .known ? "已会 ✓" : "标为会")
                    }
                    .buttonStyle(.bordered)
                    .tint(vm.wordState.color)
                    .help("当前档位：\(vm.wordState.label)（概率优先判定）。点击切换 会/不会（写入全局掌握度）")
```

- 在「释义全文」之后、「数据来源」之前插入词画像区：

```swift
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("词画像").font(.headline)
                        if let belief = vm.belief {
                            Text(MasteryPresentation.percentText(belief))
                                .font(.caption.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(vm.wordState.color)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(vm.wordState.color.opacity(0.14))
                                .clipShape(Capsule())
                                .help(MasteryPresentation.helpText(belief))
                        } else {
                            Text(MasteryPresentation.noDataText)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        Text(FrequencyBandPresentation.bandLabel(vm.frequencyBand))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.primary.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .help(FrequencyBandPresentation.helpText(
                                band: vm.frequencyBand, rank: vm.frequencyRank))
                        Spacer()
                    }
                    Text("模型估计掌握度 · 词频坐标 · 最近事件（最多 5 条）")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    EventTimelineView(
                        items: vm.recentEvents,
                        emptyText: "这个词还没有事件记录——查词、标记或做题后就会出现")
                }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter EventTimelinePresenterTests 2>&1 | tail -6`
Run: `swift test --filter SystemDictionaryTests 2>&1 | tail -6`
Expected: 全 PASS。

- [ ] **Step 5: Commit**

```bash
git add Sources/WordRecitingApp/UI/CardBrowserView.swift \
        Sources/WordRecitingApp/UI/Presentation/EventTimelinePresenter.swift \
        Sources/WordRecitingApp/UI/Components/EventTimelineView.swift \
        Sources/WordRecitingApp/UI/SystemDictionaryViewModel.swift \
        Sources/WordRecitingApp/UI/SystemDictionaryView.swift \
        Tests/WordRecitingAppTests/UI/Presentation/EventTimelinePresenterTests.swift \
        Tests/WordRecitingAppTests/Dictionary/SystemDictionaryTests.swift
git commit -m "refactor(ui): 卡片浏览与词典改概率口径并展示词画像"
```

---
