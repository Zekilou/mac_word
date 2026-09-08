# Task 5：词频坐标（Provider + 内置词频族表）

**Files:**
- Create: `Sources/WordRecitingApp/Frequency/WordFrequencyProvider.swift`
- Create: `Sources/WordRecitingApp/Frequency/BundledWordFrequencyProvider.swift`
- Create: `Sources/WordRecitingApp/Resources/word_families.json`（由脚本生成，**不手写**）
- Create: `scripts/build_word_families.py`
- Modify: `Package.swift`（登记资源）
- Test: `Tests/WordRecitingAppTests/Frequency/BundledWordFrequencyProviderTests.swift`（新建）

**依赖：** Task 1。

**数据来源与诚实边界：**
- 词频族表采用 **Nation 的 BNC/COCA word family lists（1k~25k 词族带）**，这是公开可下载的研究用词表。
- 仓库**不手写词表内容**：`word_families.json` 由 `scripts/build_word_families.py` 从源文件（TSV，一行一个词族）生成后提交。
- 资源缺失时 provider 返回 `nil`（`WordFrequency.bundled == nil`），App 仍可正常运行，只是没有词频坐标——**不阻塞、不崩溃**。
- 测试**只依赖内联夹具**，不依赖大文件；另有一个「资源若存在则校验」的跳过型测试。

---

- [ ] **Step 1: 写失败测试**

创建 `Tests/WordRecitingAppTests/Frequency/BundledWordFrequencyProviderTests.swift`：

```swift
import XCTest
@testable import WordRecitingApp

final class BundledWordFrequencyProviderTests: XCTestCase {

    private let fixture = """
    {"source":"test-3k","families":[
      {"rank":1,"band":1,"members":["the","a","an"]},
      {"rank":2,"band":1,"members":["be","is","was"]},
      {"rank":1001,"band":2,"members":["abandon","abandoned","abandonment"]}
    ]}
    """

    private func makeProvider() throws -> BundledWordFrequencyProvider {
        try BundledWordFrequencyProvider(data: Data(fixture.utf8))
    }

    func testSourceName() throws {
        XCTAssertEqual(try makeProvider().sourceName, "test-3k")
    }

    func testBandLookupIsCaseInsensitiveAndFamilyAware() throws {
        let p = try makeProvider()
        XCTAssertEqual(p.band(for: "The"), 1)
        XCTAssertEqual(p.band(for: "abandoned"), 2)
        XCTAssertEqual(p.band(for: "abandonment"), 2)
    }

    func testRankLookup() throws {
        let p = try makeProvider()
        XCTAssertEqual(p.rank(for: "the"), 1)
        XCTAssertEqual(p.rank(for: "abandon"), 1001)
    }

    func testUnknownWordReturnsNil() throws {
        let p = try makeProvider()
        XCTAssertNil(p.band(for: "zzzzz"))
        XCTAssertNil(p.rank(for: "zzzzz"))
    }

    func testDuplicateMemberKeepsBestRank() throws {
        let json = """
        {"source":"dup","families":[
          {"rank":50,"band":1,"members":["run"]},
          {"rank":5,"band":1,"members":["run"]}
        ]}
        """
        let p = try BundledWordFrequencyProvider(data: Data(json.utf8))
        XCTAssertEqual(p.rank(for: "run"), 5)
    }

    func testInvalidFormatThrows() {
        XCTAssertThrowsError(try BundledWordFrequencyProvider(data: Data("{}".utf8)))
    }

    /// 资源缺失时优雅降级：不崩溃，返回 nil。
    func testBundledResourceLoadsIfPresent() throws {
        guard let provider = BundledWordFrequencyProvider(bundledIn: .module) else {
            throw XCTSkip("word_families.json 未生成，跳过")
        }
        XCTAssertFalse(provider.sourceName.isEmpty)
    }

    func testFacadeDoesNotCrashWhenResourceMissing() {
        _ = WordFrequency.bundled
    }
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter BundledWordFrequencyProviderTests 2>&1 | tail -5`
Expected: FAIL（`cannot find 'BundledWordFrequencyProvider' in scope`）。

- [ ] **Step 3: 实现**

**3a. 新建 `Sources/WordRecitingApp/Frequency/WordFrequencyProvider.swift`：**

```swift
import Foundation

/// 词频族坐标提供者：把词映射到 BNC/COCA 词族带（1k~25k）。
/// @ai: 词频带只是「参考坐标」，不是硬阈值，不得用它直接判定用户会不会。
protocol WordFrequencyProvider: Sendable {
    /// 数据源标识，写入 comp_lemma_frequency.source。
    var sourceName: String { get }
    /// 词族带：1 = 最高频 1k 带 … 25 = 25k 带；表外或未知返回 nil。
    func band(for word: String) -> Int?
    /// 词族在全表中的排序（1 起）；未知返回 nil。
    func rank(for word: String) -> Int?
}

enum WordFrequencyLoadError: LocalizedError, Equatable {
    case invalidFormat(String)

    var errorDescription: String? {
        switch self {
        case .invalidFormat(let message): return "词频表格式错误：\(message)"
        }
    }
}

/// 全局门面：内置词频表。资源缺失时为 nil，调用方需降级处理。
enum WordFrequency {
    static let bundled: (any WordFrequencyProvider)? =
        BundledWordFrequencyProvider(bundledIn: .module)
}
```

**3b. 新建 `Sources/WordRecitingApp/Frequency/BundledWordFrequencyProvider.swift`：**

```swift
import Foundation

/// 内置精简词频族表：从 bundle 的 word_families.json 加载。
/// 文件格式：
/// {
///   "source": "bnc-coca-25k",
///   "families": [ { "rank": 1, "band": 1, "members": ["the", "a", "an"] } ]
/// }
final class BundledWordFrequencyProvider: WordFrequencyProvider {
    let sourceName: String
    private let bandByWord: [String: Int]
    private let rankByWord: [String: Int]

    private struct Payload: Decodable {
        struct Family: Decodable {
            let rank: Int
            let band: Int
            let members: [String]
        }
        let source: String
        let families: [Family]
    }

    init(data: Data) throws {
        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw WordFrequencyLoadError.invalidFormat("\(error)")
        }
        var bands: [String: Int] = [:]
        var ranks: [String: Int] = [:]
        for family in payload.families {
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
    }

    /// 从 bundle 加载；资源不存在时返回 nil（优雅降级）。
    convenience init?(bundledIn bundle: Bundle = .module) {
        guard let url = bundle.url(forResource: "word_families", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        try? self.init(data: data)
    }

    convenience init?(fileAt url: URL) {
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? self.init(data: data)
    }

    func band(for word: String) -> Int? { bandByWord[word.lowercased()] }
    func rank(for word: String) -> Int? { rankByWord[word.lowercased()] }
}
```

**3c. 新建 `scripts/build_word_families.py`：**

```python
#!/usr/bin/env python3
"""从 BNC/COCA 词族表生成内置 word_families.json。

数据源：Nation 的 BNC/COCA word family lists（1k~25k，每 1000 词族一个带）。
输入格式：每行一个词族，空格/逗号分隔成员；行序即词族频次排序（第 1 行最高频）。
用法：
    python3 scripts/build_word_families.py \
        --input external_src/word_families.tsv \
        --output Sources/WordRecitingApp/Resources/word_families.json
"""
import argparse
import json
import sys
from pathlib import Path


def parse_families(path: Path):
    families = []
    rank = 0
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        members = [part for part in line.replace(",", " ").split() if part]
        if not members:
            continue
        rank += 1
        band = min((rank - 1) // 1000 + 1, 25)
        families.append({"rank": rank, "band": band, "members": members})
    return families


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, help="词族源文件（TSV/纯文本）")
    parser.add_argument("--output", required=True, help="输出的 word_families.json")
    parser.add_argument("--source", default="bnc-coca-25k")
    args = parser.parse_args()

    input_path = Path(args.input)
    if not input_path.exists():
        sys.exit("输入文件不存在：%s" % input_path)

    families = parse_families(input_path)
    if not families:
        sys.exit("输入为空：%s" % input_path)

    payload = {"source": args.source, "families": families}
    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
    print("写入 %d 个词族 -> %s" % (len(families), output_path))


if __name__ == "__main__":
    main()
```

**3d. 生成资源文件（必须执行，不手写）：**

```bash
python3 scripts/build_word_families.py \
    --input external_src/word_families.tsv \
    --output Sources/WordRecitingApp/Resources/word_families.json
```

> 若暂时拿不到源文件，先跳过此步：测试中 `testBundledResourceLoadsIfPresent` 会走 `XCTSkip`，其余测试用内联夹具全部通过。资源补齐后重跑即可。

**3e. 修改 `Package.swift`：** 在 `resources:` 中追加：

```swift
            resources: [
                .process("Resources/glove50d.bin"),
                .process("Resources/word_families.json"),
            ]
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter BundledWordFrequencyProviderTests 2>&1 | tail -5`
Expected: 7 tests PASS（1 项可能 SKIP）。

- [ ] **Step 5: Commit**

```bash
git add Sources/WordRecitingApp/Frequency/ \
        Sources/WordRecitingApp/Resources/word_families.json \
        scripts/build_word_families.py \
        Package.swift \
        Tests/WordRecitingAppTests/Frequency/BundledWordFrequencyProviderTests.swift
git commit -m "feat(frequency): 内置词频族表 provider 与生成脚本"
```

---
