# Task 1：合同扩展（AppTypes）

**Files:**
- Modify: `Sources/WordRecitingApp/AppTypes.swift`（**只追加，不改顺序 / 不改 rawValue / 不删 case**）
- Test: `Tests/WordRecitingAppTests/ECS/RegionTypesTests.swift`（新建）

---

- [ ] **Step 1: 写失败测试**

创建 `Tests/WordRecitingAppTests/ECS/RegionTypesTests.swift`：

```swift
import XCTest
@testable import WordRecitingApp

/// 阶段一：region / 词事件 / 词频坐标的合同枚举。
final class RegionTypesTests: XCTestCase {

    func testRegionKindRawValues() {
        XCTAssertEqual(RegionKind.study.rawValue, "study")
        XCTAssertEqual(RegionKind.rss.rawValue, "rss")
        XCTAssertEqual(RegionKind.generate.rawValue, "generate")
        XCTAssertEqual(RegionKind.dictionary.rawValue, "dictionary")
        XCTAssertEqual(RegionKind.initSession.rawValue, "init")
        XCTAssertEqual(RegionKind.allCases.count, 5)
    }

    func testWordEventKindRawValues() {
        XCTAssertEqual(WordEventKind.seen.rawValue, "seen")
        XCTAssertEqual(WordEventKind.lookup.rawValue, "lookup")
        XCTAssertEqual(WordEventKind.markKnown.rawValue, "mark_known")
        XCTAssertEqual(WordEventKind.markUnknown.rawValue, "mark_unknown")
        XCTAssertEqual(WordEventKind.quizCorrect.rawValue, "quiz_correct")
        XCTAssertEqual(WordEventKind.quizWrong.rawValue, "quiz_wrong")
        XCTAssertEqual(WordEventKind.allCases.count, 6)
    }

    /// 合同铁律：新 case 只能追加到末尾，既有 rawValue 不得变动。
    func testNewCasesAppendedAtEnd() {
        XCTAssertEqual(NodeKind.allCases.last, .region)
        XCTAssertEqual(Array(ComponentID.allCases.suffix(3)),
                       [.region, .wordEvent, .lemmaFrequency])
        XCTAssertEqual(ComponentID.region.rawValue, "region")
        XCTAssertEqual(ComponentID.wordEvent.rawValue, "word_event")
        XCTAssertEqual(ComponentID.lemmaFrequency.rawValue, "lemma_frequency")
    }

    func testWordEventKindRoundTrip() throws {
        let data = try JSONEncoder().encode(WordEventKind.quizWrong)
        XCTAssertEqual(try JSONDecoder().decode(WordEventKind.self, from: data), .quizWrong)
    }

    func testRegionKindRoundTrip() throws {
        let data = try JSONEncoder().encode(RegionKind.initSession)
        XCTAssertEqual(try JSONDecoder().decode(RegionKind.self, from: data), .initSession)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter RegionTypesTests 2>&1 | tail -5`
Expected: FAIL（`cannot find 'RegionKind' in scope` 等编译错误）。

- [ ] **Step 3: 实现枚举**

修改 `Sources/WordRecitingApp/AppTypes.swift`。

**3a. `NodeKind` 末尾追加**（在 `case edge` 之后）：

```swift
    /// 一次「显示词汇的上下文」（页面/会话级）。
    case region
```

**3b. `ComponentID` 末尾追加**（在 `case lemmaDefinition = "lemma_definition"` 之后）：

```swift
    /// 词汇显示上下文（挂 Region 节点）。
    case region
    /// 单次词事件（全量事件流，挂 Event 节点）。
    case wordEvent = "word_event"
    /// 词频族坐标（挂 Lemma 节点）。
    case lemmaFrequency = "lemma_frequency"
```

**3c. 文件末尾追加两个新枚举**（放在 `enum RemoteProvider` 之后）：

```swift
/// 词汇显示上下文的种类（region 的业务分类）。
enum RegionKind: String, Sendable, Codable, CaseIterable {
    /// 复习卡片：用户主动做题。
    case study
    /// RSS 文章：被动阅读。
    case rss
    /// 生成文章：被动阅读。
    case generate
    /// 词典查词：用户主动查询。
    case dictionary
    /// 词汇初始化会话：用户主动标记。
    case initSession = "init"
}

/// 单次词事件的种类（有限枚举，全量记录）。
enum WordEventKind: String, Sendable, Codable, CaseIterable {
    /// 在文章中被动出现。
    case seen
    /// 用户主动查词。
    case lookup
    /// 用户标记「会」。
    case markKnown = "mark_known"
    /// 用户标记「不会」。
    case markUnknown = "mark_unknown"
    /// 做题答对。
    case quizCorrect = "quiz_correct"
    /// 做题答错。
    case quizWrong = "quiz_wrong"
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter RegionTypesTests 2>&1 | tail -5`
Expected: 5 tests PASS。

- [ ] **Step 5: 回归既有合同测试**

Run: `swift test --filter AppTypesTests 2>&1 | tail -5`
Expected: 全 PASS。若 `testNodeKindRawValues` / `testComponentIDRawValues` 用的是**精确集合断言**，把 `.region` / `.wordEvent` / `.lemmaFrequency` 追加到期望列表末尾（**只追加**）。

- [ ] **Step 6: Commit**

```bash
git add Sources/WordRecitingApp/AppTypes.swift Tests/WordRecitingAppTests/ECS/RegionTypesTests.swift
git commit -m "feat(ecs): 合同扩展 region/词事件/词频坐标枚举"
```

---
