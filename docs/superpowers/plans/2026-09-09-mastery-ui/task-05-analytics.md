# Task 5：分析页改造（概率分布 + 词频带画像）

**Files:**
- Modify: `Sources/WordRecitingApp/Frequency/WordFrequencyProvider.swift`（协议加 2 个只读属性）
- Modify: `Sources/WordRecitingApp/Frequency/BundledWordFrequencyProvider.swift`
- Modify: `Sources/WordRecitingApp/ECS/GraphQueries+Mastery.swift`（加 `masteryDistribution` / `masteryByBand`）
- Create: `Sources/WordRecitingApp/Mastery/VocabularyProfile.swift`
- Modify: `Sources/WordRecitingApp/UI/AnalyticsViewModel.swift`
- Modify: `Sources/WordRecitingApp/UI/AnalyticsView.swift`
- Test: `Tests/WordRecitingAppTests/Frequency/WordFrequencyBandCountsTests.swift`（新建）
- Test: `Tests/WordRecitingAppTests/ECS/GraphQueriesMasteryBandTests.swift`（新建）
- Test: `Tests/WordRecitingAppTests/Mastery/VocabularyProfileBuilderTests.swift`（新建）
- Test: `Tests/WordRecitingAppTests/UI/AnalyticsViewModelTests.swift`（新建）

**依赖：** Task 1。

**审计对照（README 表格第 6 行）：** 现状「词汇能力」四卡全部基于 mastery 极值，没有词频维度。改法：四卡改成**概率档位分布**；新增**词频带画像 + 词汇量估算**。

---

- [ ] **Step 1: 写失败测试**

**1a. 新建 `Tests/WordRecitingAppTests/Frequency/WordFrequencyBandCountsTests.swift`：**

```swift
import XCTest
@testable import WordRecitingApp

final class WordFrequencyBandCountsTests: XCTestCase {

    private let fixture = """
    {"source":"test","families":[
      {"rank":1,"band":1,"members":["the","a"]},
      {"rank":2,"band":1,"members":["be"]},
      {"rank":1001,"band":2,"members":["abandon","abandoned"]},
      {"rank":1002,"band":2,"members":["ability"]}
    ]}
    """

    private func makeProvider() throws -> BundledWordFrequencyProvider {
        try BundledWordFrequencyProvider(data: Data(fixture.utf8))
    }

    func testBandFamilyCountsCountFamiliesNotMembers() throws {
        let provider = try makeProvider()
        XCTAssertEqual(provider.bandFamilyCounts[1], 2)
        XCTAssertEqual(provider.bandFamilyCounts[2], 2)
    }

    func testTotalFamilyCount() throws {
        XCTAssertEqual(try makeProvider().totalFamilyCount, 4)
    }

    func testMissingBandIsAbsent() throws {
        XCTAssertNil(try makeProvider().bandFamilyCounts[9])
    }
}
```

**1b. 新建 `Tests/WordRecitingAppTests/ECS/GraphQueriesMasteryBandTests.swift`：**

```swift
import XCTest
@testable import WordRecitingApp

final class GraphQueriesMasteryBandTests: XCTestCase {
    private var appDB: AppDatabase!
    private var world: World!
    private var graph: GraphQueries { world.graph }

    override func setUpWithError() throws {
        appDB = try AppDatabase.inMemory()
        world = World(database: appDB)
    }

    private func seed(lemmaId: String, band: Int, belief: Double?) throws {
        try world.registry.insertNode(id: lemmaId, kind: .lemma, createdAt: Date())
        try world.registry.upsertComponent(LemmaFrequencyComponent(
            entityId: lemmaId, band: band, freqRank: band * 1000, source: "test"))
        if let belief {
            try world.registry.upsertComponent(MasteryBeliefComponent(
                entityId: lemmaId, belief: belief, opportunities: 1,
                lastEventAt: nil, updatedAt: Date(), paramsVersion: "bkt-1"))
        }
    }

    func testMasteryByBandAggregatesObservedOnly() throws {
        try seed(lemmaId: "L1", band: 1, belief: 0.9)
        try seed(lemmaId: "L2", band: 1, belief: 0.7)
        try seed(lemmaId: "L3", band: 2, belief: nil)

        let stats = try graph.masteryByBand()
        let band1 = try XCTUnwrap(stats.first { $0.band == 1 })
        XCTAssertEqual(band1.observedCount, 2)
        XCTAssertEqual(band1.sumBelief, 1.6, accuracy: 0.0001)

        let band2 = try XCTUnwrap(stats.first { $0.band == 2 })
        XCTAssertEqual(band2.observedCount, 0)
    }

    func testMasteryDistributionUsesThresholds() throws {
        try seed(lemmaId: "L1", band: 1, belief: 0.95)
        try seed(lemmaId: "L2", band: 1, belief: 0.10)
        try seed(lemmaId: "L3", band: 1, belief: 0.50)

        let distribution = try graph.masteryDistribution(
            knownThreshold: WordMarkState.knownThreshold,
            unknownThreshold: WordMarkState.unknownThreshold)

        XCTAssertEqual(distribution.known, 1)
        XCTAssertEqual(distribution.unknown, 1)
        XCTAssertEqual(distribution.learning, 1)
        XCTAssertEqual(distribution.total, 3)
    }
}
```

**1c. 新建 `Tests/WordRecitingAppTests/Mastery/VocabularyProfileBuilderTests.swift`：**

```swift
import XCTest
@testable import WordRecitingApp

final class VocabularyProfileBuilderTests: XCTestCase {

    func testEstimatedKnownCombinesObservedAndPriorExtrapolation() {
        let profile = VocabularyProfileBuilder.build(
            bandStats: [BandStat(band: 1, observedCount: 2, sumBelief: 1.8)],
            bandFamilyCounts: [1: 10])

        let band1 = profile.bands[0]
        XCTAssertEqual(band1.totalFamilies, 10)
        XCTAssertEqual(band1.observedFamilies, 2)
        XCTAssertEqual(band1.meanBelief, 0.9, accuracy: 0.0001)
        XCTAssertEqual(band1.estimatedKnownFamilies, 1.8 + 8 * 0.90, accuracy: 0.0001)
        XCTAssertEqual(profile.estimatedKnownTotal, band1.estimatedKnownFamilies, accuracy: 0.0001)
        XCTAssertEqual(profile.totalFamilies, 10)
    }

    func testBandsAreSortedAscending() {
        let profile = VocabularyProfileBuilder.build(
            bandStats: [BandStat(band: 3, observedCount: 1, sumBelief: 0.5)],
            bandFamilyCounts: [1: 5, 3: 5])
        XCTAssertEqual(profile.bands.map(\.band), [1, 3])
    }

    func testBandWithoutFrequencyTableStillAppears() {
        let profile = VocabularyProfileBuilder.build(
            bandStats: [BandStat(band: 2, observedCount: 1, sumBelief: 0.4)],
            bandFamilyCounts: [:])
        XCTAssertEqual(profile.bands.count, 1)
        XCTAssertEqual(profile.bands[0].totalFamilies, 0)
        XCTAssertEqual(profile.bands[0].estimatedKnownFamilies, 0.4, accuracy: 0.0001)
        XCTAssertNil(profile.bands[0].coverage)
    }

    func testEmptyInput() {
        let profile = VocabularyProfileBuilder.build(bandStats: [], bandFamilyCounts: [:])
        XCTAssertTrue(profile.bands.isEmpty)
        XCTAssertEqual(profile.estimatedKnownTotal, 0, accuracy: 0.0001)
    }
}
```

**1d. 新建 `Tests/WordRecitingAppTests/UI/AnalyticsViewModelTests.swift`：**

```swift
import XCTest
@testable import WordRecitingApp

@MainActor
final class AnalyticsViewModelTests: XCTestCase {
    private var appDB: AppDatabase!
    private var world: World!

    override func setUpWithError() throws {
        appDB = try AppDatabase.inMemory()
        world = World(database: appDB)
    }

    private func seed(lemmaId: String, band: Int, belief: Double) throws {
        try world.registry.insertNode(id: lemmaId, kind: .lemma, createdAt: Date())
        try world.registry.upsertComponent(LemmaFrequencyComponent(
            entityId: lemmaId, band: band, freqRank: band * 1000, source: "test"))
        try world.registry.upsertComponent(MasteryBeliefComponent(
            entityId: lemmaId, belief: belief, opportunities: 1,
            lastEventAt: nil, updatedAt: Date(), paramsVersion: "bkt-1"))
    }

    func testDistributionAndProfileAreBuiltOnReload() throws {
        try seed(lemmaId: "L1", band: 1, belief: 0.9)
        try seed(lemmaId: "L2", band: 1, belief: 0.1)

        let vm = AnalyticsViewModel(world: world)
        vm.reload()

        XCTAssertEqual(vm.distribution?.known, 1)
        XCTAssertEqual(vm.distribution?.unknown, 1)
        let profile = try XCTUnwrap(vm.profile)
        let band1 = try XCTUnwrap(profile.bands.first { $0.band == 1 })
        XCTAssertEqual(band1.observedFamilies, 2)
        XCTAssertGreaterThan(profile.estimatedKnownTotal, 0)
    }

    func testEmptyStateDoesNotCrash() throws {
        let vm = AnalyticsViewModel(world: world)
        vm.reload()
        XCTAssertEqual(vm.distribution?.total ?? 0, 0)
        XCTAssertEqual(vm.profile?.bands.count ?? 0, 0)
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter WordFrequencyBandCountsTests 2>&1 | tail -5`
Run: `swift test --filter GraphQueriesMasteryBandTests 2>&1 | tail -5`
Run: `swift test --filter VocabularyProfileBuilderTests 2>&1 | tail -5`
Run: `swift test --filter AnalyticsViewModelTests 2>&1 | tail -5`
Expected: FAIL。

- [ ] **Step 3: 实现**

**3a. `WordFrequencyProvider.swift`：协议追加（放在 `rank(for:)` 之后）：**

```swift
    /// 每个词族带的词族总数（band → 词族数）。用于词汇量画像的分母。
    var bandFamilyCounts: [Int: Int] { get }
    /// 全表词族总数。
    var totalFamilyCount: Int { get }
```

**3b. `BundledWordFrequencyProvider.swift`：**

- 属性区追加：

```swift
    let bandFamilyCounts: [Int: Int]
    let totalFamilyCount: Int
```

- `init(data:)` 的循环改为同时统计族数：

```swift
        var bands: [String: Int] = [:]
        var ranks: [String: Int] = [:]
        var familyCounts: [Int: Int] = [:]
        for family in payload.families {
            familyCounts[family.band, default: 0] += 1
            for member in family.members {
                let key = member.lowercased()
                if let existing = ranks[key], existing <= family.rank { continue }
                ranks[key] = family.rank
                bands[key] = family.band
            }
        }
        self.sourceName = payload.source
        self.bandByWord = bands
        self.rankByWord = ranks
        self.bandFamilyCounts = familyCounts
        self.totalFamilyCount = payload.families.count
```

**3c. `GraphQueries+Mastery.swift`：追加：**

```swift
    /// 概率档位分布（阈值由调用方传入，避免 ECS 依赖 UI 常量）。
    struct MasteryDistribution: Sendable, Equatable {
        var known: Int
        var unknown: Int
        var learning: Int
        var total: Int
    }

    func masteryDistribution(knownThreshold: Double,
                             unknownThreshold: Double) throws -> MasteryDistribution {
        try database.dbWriter.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT
                    SUM(CASE WHEN belief >= ? THEN 1 ELSE 0 END) AS known,
                    SUM(CASE WHEN belief <= ? THEN 1 ELSE 0 END) AS unknown,
                    SUM(CASE WHEN belief > ? AND belief < ? THEN 1 ELSE 0 END) AS learning,
                    COUNT(*) AS total
                FROM comp_mastery_belief
                """, arguments: [knownThreshold, unknownThreshold,
                                 unknownThreshold, knownThreshold])
            return MasteryDistribution(
                known: row?["known"] ?? 0,
                unknown: row?["unknown"] ?? 0,
                learning: row?["learning"] ?? 0,
                total: row?["total"] ?? 0)
        }
    }

    /// 按词频带聚合已观测词的后验（band → 观测数 + 后验之和）。
    func masteryByBand() throws -> [BandStat] {
        try database.dbWriter.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT f.band AS band,
                       COUNT(b.entity_id) AS observed_count,
                       COALESCE(SUM(b.belief), 0) AS sum_belief
                FROM comp_lemma_frequency f
                LEFT JOIN comp_mastery_belief b ON b.entity_id = f.entity_id
                GROUP BY f.band
                ORDER BY f.band ASC
                """)
            return rows.map { row in
                BandStat(band: row["band"],
                         observedCount: row["observed_count"],
                         sumBelief: row["sum_belief"])
            }
        }
    }
```

**3d. 新建 `Sources/WordRecitingApp/Mastery/VocabularyProfile.swift`：**

```swift
import Foundation

/// 某个词频带的已观测统计（数据库侧）。
struct BandStat: Sendable, Equatable {
    /// 词频带：1 = 最高频 1k 带 … 25 = 25k 带；0 = 表外。
    let band: Int
    /// 该带内已观测（有事件）的词族数。
    let observedCount: Int
    /// 该带内已观测词的后验概率之和。
    let sumBelief: Double
}

/// 某个词频带的覆盖率（画像侧）。
struct BandCoverage: Sendable, Equatable, Identifiable {
    var id: Int { band }
    let band: Int
    let totalFamilies: Int
    let observedFamilies: Int
    let meanBelief: Double
    let estimatedKnownFamilies: Double

    /// 覆盖率（估算认识 / 总词族）；总词族为 0 时 nil。
    var coverage: Double? {
        guard totalFamilies > 0 else { return nil }
        return min(1, estimatedKnownFamilies / Double(totalFamilies))
    }
}

/// 词汇量画像。
struct VocabularyProfile: Sendable, Equatable {
    let bands: [BandCoverage]
    let estimatedKnownTotal: Double
    let totalFamilies: Int
}

/// 画像构建（纯函数，可单测）。
/// @ai: 未观测词用 BKTModel.prior 外推——这是**估计**，不是测量。
enum VocabularyProfileBuilder {

    static func build(bandStats: [BandStat],
                      bandFamilyCounts: [Int: Int],
                      parameters: BKTParameters = .default) -> VocabularyProfile {
        let observedByBand = Dictionary(
            uniqueKeysWithValues: bandStats.map { ($0.band, $0) })
        let allBands = Set(observedByBand.keys).union(bandFamilyCounts.keys).sorted()

        var coverage: [BandCoverage] = []
        var estimatedTotal = 0.0
        var totalFamilies = 0

        for band in allBands {
            let total = bandFamilyCounts[band] ?? 0
            let stat = observedByBand[band]
            let observed = stat?.observedCount ?? 0
            let sumBelief = stat?.sumBelief ?? 0
            let meanBelief = observed > 0 ? sumBelief / Double(observed) : 0
            let unobserved = max(0, total - observed)
            let prior = BKTModel.prior(band: band > 0 ? band : nil, parameters: parameters)
            let estimated = sumBelief + Double(unobserved) * prior

            coverage.append(BandCoverage(
                band: band,
                totalFamilies: total,
                observedFamilies: observed,
                meanBelief: meanBelief,
                estimatedKnownFamilies: estimated))
            estimatedTotal += estimated
            totalFamilies += total
        }

        return VocabularyProfile(bands: coverage,
                                 estimatedKnownTotal: estimatedTotal,
                                 totalFamilies: totalFamilies)
    }
}
```

**3e. `AnalyticsViewModel.swift`：**

- 状态区追加：

```swift
    /// 概率档位分布。
    var distribution: GraphQueries.MasteryDistribution?
    /// 词汇量画像（估算）。
    var profile: VocabularyProfile?
    /// 内置词频表是否已加载。
    var hasFrequencyTable = false
```

- `reload()` 改为：

```swift
    func reload() {
        do {
            overview = try world.graph.masteryOverview()
            stats = try world.graph.studyStats()
            weakLemmas = try world.graph.weakLemmaDetails(limit: 10)
            distribution = try world.graph.masteryDistribution(
                knownThreshold: WordMarkState.knownThreshold,
                unknownThreshold: WordMarkState.unknownThreshold)
            let bandStats = try world.graph.masteryByBand()
            let counts = WordFrequency.bundled?.bandFamilyCounts ?? [:]
            hasFrequencyTable = WordFrequency.bundled != nil
            profile = VocabularyProfileBuilder.build(
                bandStats: bandStats, bandFamilyCounts: counts)
            errorMessage = nil
        } catch {
            overview = nil
            stats = nil
            weakLemmas = []
            distribution = nil
            profile = nil
            errorMessage = "\(error)"
        }
    }
```

**3f. `AnalyticsView.swift`：**

- `abilitySection` 整体替换为概率档位分布：

```swift
    // MARK: - 掌握度分布（BKT 后验概率档位）

    @ViewBuilder
    private var abilitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("掌握度分布").font(.headline)
                Text("BKT 后验概率档位（≥\(MasteryPresentation.percentText(WordMarkState.knownThreshold)) 会 · ≤\(MasteryPresentation.percentText(WordMarkState.unknownThreshold)) 不会 · 中间学习中）")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if let d = vm.distribution, d.total > 0 {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 130), spacing: 10)],
                    alignment: .leading, spacing: 10
                ) {
                    statCard("已会", "\(d.known)", icon: "checkmark.circle.fill", tint: .green)
                    statCard("不会", "\(d.unknown)", icon: "xmark.circle.fill", tint: .red)
                    statCard("学习中", "\(d.learning)", icon: "circle.lefthalf.filled", tint: .orange)
                    statCard("无概率", "\(max(0, (vm.overview?.unmarked ?? 0)))",
                             icon: "circle", tint: .secondary)
                }
            } else {
                Text("还没有概率数据。先在「词汇」页初始化，或阅读 RSS 文章——事件积累后模型会给出概率。")
                    .font(.caption).foregroundStyle(.secondary).padding(.vertical, 4)
            }
        }
    }
```

- `content` 里插入 `profileSection`：

```swift
                abilitySection
                Divider()
                profileSection
                Divider()
                reviewSection
```

- 追加画像区（含免责说明）：

```swift
    // MARK: - 词汇量画像（估算）

    /// 覆盖阈值参照：书面文本 95% ≈ 4,000 词族、98% ≈ 8,000–9,000 词族
    /// （Laufer 1989 / Hu & Nation 2000；Kremmel & Schmitt 2023 指出 98% 并非对所有人可靠）。
    private static let coverage95Families = 4000
    private static let coverage98Families = 8500

    @ViewBuilder
    private var profileSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("词汇量画像").font(.headline)
                Text("按 BNC/COCA 词族带估算").font(.caption).foregroundStyle(.tertiary)
            }
            if let p = vm.profile, !p.bands.isEmpty {
                estimateRow(p)
                bandChart(p)
                coverageHint(p)
                disclaimer
            } else {
                Text("还没有可估算的数据。事件积累后这里会按词频带给出词汇量估算。")
                    .font(.caption).foregroundStyle(.secondary).padding(.vertical, 4)
            }
        }
    }

    private func estimateRow(_ p: VocabularyProfile) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(Int(p.estimatedKnownTotal.rounded()))")
                .font(.system(size: 34, weight: .semibold))
                .monospacedDigit()
            Text("个词族（估算）").font(.callout).foregroundStyle(.secondary)
            if p.totalFamilies > 0 {
                Text(String(format: "约占词表 %.1f%%",
                            p.estimatedKnownTotal / Double(p.totalFamilies) * 100))
                    .font(.caption).foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }

    private func bandChart(_ p: VocabularyProfile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(p.bands) { band in
                HStack(spacing: 10) {
                    Text(FrequencyBandPresentation.bandLabel(band.band))
                        .font(.caption2).monospacedDigit()
                        .frame(width: 56, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.accentColor.opacity(0.12))
                            Capsule()
                                .fill(Color.accentColor.opacity(0.75))
                                .frame(width: geo.size.width * (band.coverage ?? 0))
                        }
                    }
                    .frame(height: 8)
                    Text(band.coverage.map { String(format: "%.0f%%", $0 * 100) } ?? "—")
                        .font(.caption2.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                    Text("已观测 \(band.observedFamilies)/\(band.totalFamilies)")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .frame(width: 110, alignment: .leading)
                }
            }
        }
    }

    private func coverageHint(_ p: VocabularyProfile) -> some View {
        let known = p.estimatedKnownTotal
        return VStack(alignment: .leading, spacing: 4) {
            Text("覆盖阈值参照（书面文本）").font(.caption.weight(.semibold))
            Text("95% 阅读覆盖 ≈ \(Self.coverage95Families) 词族 · 98% ≈ \(Self.coverage98Families) 词族")
                .font(.caption2).foregroundStyle(.secondary)
            Text(known >= Double(Self.coverage98Families)
                 ? "按当前估算已达到 98% 覆盖参照线"
                 : (known >= Double(Self.coverage95Families)
                    ? "按当前估算已达到 95% 覆盖参照线"
                    : "距 95% 覆盖参照线还差约 \(Int(Double(Self.coverage95Families) - known)) 个词族"))
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var disclaimer: some View {
        Text("说明：估算 = 已观测词的后验概率之和 + 未观测词按词频先验外推。\(vm.hasFrequencyTable ? "" : "当前未加载词频表，只统计已观测词。")词频带只是参考坐标，不作硬标准；概率是模型推断值，不是精确测量。")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter WordFrequencyBandCountsTests 2>&1 | tail -5`
Run: `swift test --filter GraphQueriesMasteryBandTests 2>&1 | tail -5`
Run: `swift test --filter VocabularyProfileBuilderTests 2>&1 | tail -5`
Run: `swift test --filter AnalyticsViewModelTests 2>&1 | tail -5`
Expected: 全 PASS。

- [ ] **Step 5: 回归词频与画像相关**

Run: `swift test --filter BundledWordFrequencyProviderTests 2>&1 | tail -5`
Run: `swift test --filter WordFamilyResourceTests 2>&1 | tail -5`
Expected: 全 PASS。

- [ ] **Step 6: Commit**

```bash
git add Sources/WordRecitingApp/Frequency/WordFrequencyProvider.swift \
        Sources/WordRecitingApp/Frequency/BundledWordFrequencyProvider.swift \
        Sources/WordRecitingApp/ECS/GraphQueries+Mastery.swift \
        Sources/WordRecitingApp/Mastery/VocabularyProfile.swift \
        Sources/WordRecitingApp/UI/AnalyticsViewModel.swift \
        Sources/WordRecitingApp/UI/AnalyticsView.swift \
        Tests/WordRecitingAppTests/Frequency/WordFrequencyBandCountsTests.swift \
        Tests/WordRecitingAppTests/ECS/GraphQueriesMasteryBandTests.swift \
        Tests/WordRecitingAppTests/Mastery/VocabularyProfileBuilderTests.swift \
        Tests/WordRecitingAppTests/UI/AnalyticsViewModelTests.swift
git commit -m "refactor(ui): 分析页改概率分布并新增词频带画像"
```

---
