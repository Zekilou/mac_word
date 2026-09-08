# Task 3：组件结构与注册表登记

**Files:**
- Create: `Sources/WordRecitingApp/ECS/RegionComponents.swift`
- Modify: `Sources/WordRecitingApp/ECS/EntityRegistry.swift`（`tableNameMap` 追加 3 项）
- Test: `Tests/WordRecitingAppTests/ECS/RegionComponentsTests.swift`（新建）

**依赖：** Task 1、Task 2。

> 为什么新建文件：`ECS/Components.swift` 已 331 行，超过「文件 ≤ 300 行」铁律，新组件必须另起文件。

---

- [ ] **Step 1: 写失败测试**

创建 `Tests/WordRecitingAppTests/ECS/RegionComponentsTests.swift`：

```swift
import XCTest
@testable import WordRecitingApp

/// 阶段一：region / 词事件 / 词频组件的 round-trip 与注册表登记。
final class RegionComponentsTests: XCTestCase {
    private var appDB: AppDatabase!
    private var world: World!
    private var registry: EntityRegistry { world.registry }

    override func setUpWithError() throws {
        appDB = try AppDatabase.inMemory()
        world = World(database: appDB)
    }

    func testTableNameMapRegistersNewComponents() {
        XCTAssertEqual(EntityRegistry.tableNameMap[.region], "comp_region")
        XCTAssertEqual(EntityRegistry.tableNameMap[.wordEvent], "comp_word_event")
        XCTAssertEqual(EntityRegistry.tableNameMap[.lemmaFrequency], "comp_lemma_frequency")
    }

    func testRegionComponentRoundTrip() throws {
        try registry.insertNode(id: "R1", kind: .region, createdAt: Date())
        try registry.upsertComponent(RegionComponent(
            entityId: "R1", kind: RegionKind.rss.rawValue, label: "一篇文章",
            sourceId: "A1", trust: 0, createdAt: Date()))

        let back: RegionComponent? = try registry.fetchComponents(for: "R1", table: "comp_region")
        XCTAssertEqual(back?.kind, "rss")
        XCTAssertEqual(back?.label, "一篇文章")
        XCTAssertEqual(back?.sourceId, "A1")
        XCTAssertEqual(back?.trust, 0)
    }

    func testWordEventComponentRoundTrip() throws {
        let now = Date()
        try registry.insertNode(id: "E1", kind: .event, createdAt: now)
        try registry.upsertComponent(WordEventComponent(
            entityId: "E1", lemmaId: "L1", regionId: "R1",
            eventKind: WordEventKind.markUnknown.rawValue, trust: 1,
            occurredAt: now, detailJson: #"{"surface":"abandoned"}"#))

        let back: WordEventComponent? = try registry.fetchComponents(for: "E1", table: "comp_word_event")
        XCTAssertEqual(back?.lemmaId, "L1")
        XCTAssertEqual(back?.regionId, "R1")
        XCTAssertEqual(back?.eventKind, "mark_unknown")
        XCTAssertEqual(back?.trust, 1)
        XCTAssertEqual(back?.detailJson, #"{"surface":"abandoned"}"#)
    }

    func testLemmaFrequencyComponentRoundTrip() throws {
        try registry.insertNode(id: "L1", kind: .lemma, createdAt: Date())
        try registry.upsertComponent(LemmaFrequencyComponent(
            entityId: "L1", band: 2, freqRank: 1001, source: "bnc-coca-25k"))

        let back: LemmaFrequencyComponent? = try registry.fetchComponents(
            for: "L1", table: "comp_lemma_frequency")
        XCTAssertEqual(back?.band, 2)
        XCTAssertEqual(back?.freqRank, 1001)
        XCTAssertEqual(back?.source, "bnc-coca-25k")
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter RegionComponentsTests 2>&1 | tail -5`
Expected: FAIL（`cannot find 'RegionComponent' in scope`）。

- [ ] **Step 3: 实现**

**3a. 新建 `Sources/WordRecitingApp/ECS/RegionComponents.swift`：**

```swift
import Foundation
import GRDB

/// Region：一次「显示词汇的上下文」（页面/会话级）。
/// @ai: id 由调用方按业务键构造，保证同一上下文复用同一 region。
struct RegionComponent: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "comp_region"
    var entityId: String
    /// RegionKind.rawValue。
    var kind: String
    var label: String?
    /// 触发该 region 的实体（文章 id / 卡片 id / nil）。
    var sourceId: String?
    /// 该上下文的基础可信度：主动上下文 1.0，被动上下文 0.0。
    var trust: Double
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case entityId = "entity_id"
        case kind
        case label
        case sourceId = "source_id"
        case trust
        case createdAt = "created_at"
    }
}

/// 单次词事件（全量事件流的一条记录，挂 Event 节点）。
struct WordEventComponent: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "comp_word_event"
    var entityId: String
    /// 冗余外键：便于按词索引查询。
    var lemmaId: String
    /// 冗余外键：便于按上下文索引查询。
    var regionId: String
    /// WordEventKind.rawValue。
    var eventKind: String
    /// 事件级可信度（= 覆盖值 ?? region.trust）。
    var trust: Double
    var occurredAt: Date
    var detailJson: String?

    enum CodingKeys: String, CodingKey {
        case entityId = "entity_id"
        case lemmaId = "lemma_id"
        case regionId = "region_id"
        case eventKind = "event_kind"
        case trust
        case occurredAt = "occurred_at"
        case detailJson = "detail_json"
    }
}

/// 词频族坐标（BNC/COCA 词族带，挂 Lemma 节点）。
struct LemmaFrequencyComponent: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "comp_lemma_frequency"
    var entityId: String
    /// 词族带：1 = 最高频 1k 带 … 25 = 25k 带。
    var band: Int
    /// 词族在全表中的排序（1 起）。
    var freqRank: Int
    var source: String

    enum CodingKeys: String, CodingKey {
        case entityId = "entity_id"
        case band
        case freqRank = "freq_rank"
        case source
    }
}
```

**3b. 修改 `Sources/WordRecitingApp/ECS/EntityRegistry.swift`：**

在 `tableNameMap` 的 `.lemmaDefinition: "comp_lemma_definitions",` 之后追加：

```swift
        .region: "comp_region",
        .wordEvent: "comp_word_event",
        .lemmaFrequency: "comp_lemma_frequency",
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter RegionComponentsTests 2>&1 | tail -5`
Expected: 4 tests PASS。

- [ ] **Step 5: 回归注册表测试**

Run: `swift test --filter EntityRegistryTests 2>&1 | tail -5`
Expected: 全 PASS（`testTableNameMapCoversAllComponentIDs` 覆盖新 case）。

- [ ] **Step 6: Commit**

```bash
git add Sources/WordRecitingApp/ECS/RegionComponents.swift \
        Sources/WordRecitingApp/ECS/EntityRegistry.swift \
        Tests/WordRecitingAppTests/ECS/RegionComponentsTests.swift
git commit -m "feat(ecs): 新增 region/词事件/词频组件并登记注册表"
```

---
