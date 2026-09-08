# Task 1：词频资源落地（BNC/COCA 词族表）

**Files:**
- Modify: `scripts/build_word_families.py`（支持按带分目录输入）
- Create: `Sources/WordRecitingApp/Resources/word_families.json`（脚本生成，**不手写**）
- Modify: `Package.swift`（登记资源）
- Create: `Tests/WordRecitingAppTests/Frequency/WordFamilyResourceTests.swift`
- Modify: `Tests/WordRecitingAppTests/Frequency/BundledWordFrequencyProviderTests.swift`（修掉「永远 skip」的假测试）

**依赖：** 无（阶段一 task-05 的代码已在仓库里）。

**数据源：** Nation 的 BNC/COCA word family lists（1k~25k 词族带，公开可下载）。需要你先把源文件放到 `external_src/bnc_coca_word_families/`（每个带一个 `.txt`，文件内一行一个词族），或准备成一个合并 TSV。

---

- [ ] **Step 1: 写失败测试**

**1a. 新建 `Tests/WordRecitingAppTests/Frequency/WordFamilyResourceTests.swift`：**

```swift
import XCTest
@testable import WordRecitingApp

/// 真实内置词频表校验：资源必须存在、可用、带序单调。
final class WordFamilyResourceTests: XCTestCase {

    private struct Payload: Decodable {
        struct Family: Decodable { let rank: Int; let band: Int; let members: [String] }
        let source: String
        let families: [Family]
    }

    func testBundledProviderIsAvailable() throws {
        let provider = try XCTUnwrap(
            WordFrequency.bundled,
            "word_families.json 未生成或未登记进 Package.swift")
        XCTAssertFalse(provider.sourceName.isEmpty)
    }

    func testCommonWordsHaveBands() throws {
        let provider = try XCTUnwrap(WordFrequency.bundled)
        for word in ["the", "be", "have", "make", "government"] {
            XCTAssertNotNil(provider.band(for: word), "缺常用词：\(word)")
        }
    }

    func testHighFrequencyWordRanksBeforeLowFrequencyWord() throws {
        let provider = try XCTUnwrap(WordFrequency.bundled)
        let high = try XCTUnwrap(provider.rank(for: "the"))
        let low = try XCTUnwrap(provider.rank(for: "government"))
        XCTAssertLessThan(high, low)
    }

    func testRankIsStrictlyIncreasingAndBandIsNonDecreasing() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "word_families", withExtension: "json"),
            "资源未登记进 Package.swift")
        let payload = try JSONDecoder().decode(Payload.self, from: Data(contentsOf: url))
        XCTAssertGreaterThanOrEqual(payload.families.count, 2000, "词族数过少，疑似只生成了片段")

        var previousRank = 0
        var previousBand = 1
        for family in payload.families {
            XCTAssertGreaterThan(family.rank, previousRank, "rank 必须严格递增")
            XCTAssertGreaterThanOrEqual(family.band, previousBand, "band 不得随 rank 下降")
            XCTAssertTrue((1...25).contains(family.band), "band 越界：\(family.band)")
            XCTAssertFalse(family.members.isEmpty, "词族为空：rank \(family.rank)")
            previousRank = family.rank
            previousBand = family.band
        }
    }
}
```

**1b. 修改 `Tests/WordRecitingAppTests/Frequency/BundledWordFrequencyProviderTests.swift`** 里的 `testBundledResourceLoadsIfPresent`：

> 现有实现用 `BundledWordFrequencyProvider(bundledIn: .module)`，`.module` 在**测试 target** 里解析成测试包，永远找不到 App 的资源，所以这条测试永远 skip——是假测试。改成走 App 侧门面。

```swift
    /// 资源缺失时优雅降级：不崩溃，返回 nil。
    func testBundledResourceLoadsIfPresent() throws {
        guard let provider = WordFrequency.bundled else {
            throw XCTSkip("word_families.json 未生成，跳过")
        }
        XCTAssertFalse(provider.sourceName.isEmpty)
    }
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter WordFamilyResourceTests 2>&1 | tail -8`
Expected: FAIL（`word_families.json 未生成或未登记进 Package.swift`）。

- [ ] **Step 3: 实现**

**3a. 覆盖 `scripts/build_word_families.py` 为支持两种输入布局的版本：**

```python
#!/usr/bin/env python3
"""从 BNC/COCA 词族表生成内置 word_families.json。

数据源：Nation 的 BNC/COCA word family lists（1k~25k 词族带）。
支持两种输入布局：
  1) --input <tsv>      单文件：每行一个词族，空格/逗号分隔成员；行序即词族频次排序。
  2) --input-dir <dir>  目录：读取目录下 *.txt/*.tsv，按文件名里的数字（1、2…25 或 1k…25k）
                        排序，每个文件 = 一个词族带；文件内行序为族序。
用法：
    python3 scripts/build_word_families.py \
        --input-dir external_src/bnc_coca_word_families \
        --output Sources/WordRecitingApp/Resources/word_families.json
"""
import argparse
import json
import re
import sys
from pathlib import Path


def parse_members(line):
    return [part for part in line.replace(",", " ").split() if part]


def parse_single(path):
    families = []
    rank = 0
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        members = parse_members(line)
        if not members:
            continue
        rank += 1
        band = min((rank - 1) // 1000 + 1, 25)
        families.append({"rank": rank, "band": band, "members": members})
    return families


def band_from_name(name):
    numbers = re.findall(r"\d+", name)
    if not numbers:
        return None
    value = int(numbers[0])
    if value > 25 and value % 1000 == 0:
        value //= 1000
    return min(max(value, 1), 25)


def parse_directory(directory):
    files = sorted(
        [p for p in directory.iterdir() if p.suffix.lower() in {".txt", ".tsv"}],
        key=lambda p: (band_from_name(p.name) or 99, p.name),
    )
    if not files:
        sys.exit("目录内没有 .txt/.tsv 文件：%s" % directory)
    families = []
    rank = 0
    for path in files:
        band = band_from_name(path.name) or min((rank // 1000) + 1, 25)
        for raw in path.read_text(encoding="utf-8").splitlines():
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            members = parse_members(line)
            if not members:
                continue
            rank += 1
            families.append({"rank": rank, "band": band, "members": members})
    return families


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", help="单文件词族表（每行一个词族）")
    parser.add_argument("--input-dir", help="按带分文件的目录（1k~25k）")
    parser.add_argument("--output", required=True)
    parser.add_argument("--source", default="bnc-coca-25k")
    args = parser.parse_args()

    if bool(args.input) == bool(args.input_dir):
        sys.exit("必须且只能指定 --input 或 --input-dir 之一")

    if args.input:
        path = Path(args.input)
        if not path.exists():
            sys.exit("输入文件不存在：%s" % path)
        families = parse_single(path)
    else:
        directory = Path(args.input_dir)
        if not directory.is_dir():
            sys.exit("输入目录不存在：%s" % directory)
        families = parse_directory(directory)

    if not families:
        sys.exit("解析结果为空")

    payload = {"source": args.source, "families": families}
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
    print("写入 %d 个词族 -> %s" % (len(families), output))


if __name__ == "__main__":
    main()
```

**3b. 生成资源（必须执行，不手写）：**

```bash
# 按带分目录（推荐）
python3 scripts/build_word_families.py \
    --input-dir external_src/bnc_coca_word_families \
    --output Sources/WordRecitingApp/Resources/word_families.json

# 或：合并好的单文件
python3 scripts/build_word_families.py \
    --input external_src/word_families.tsv \
    --output Sources/WordRecitingApp/Resources/word_families.json
```

预期输出形如 `写入 25000 个词族 -> Sources/WordRecitingApp/Resources/word_families.json`。

**3c. 修改 `Package.swift`**，把资源数组改成：

```swift
            resources: [
                .process("Resources/glove50d.bin"),
                .process("Resources/word_families.json")
            ]
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter WordFamilyResourceTests 2>&1 | tail -8`
Expected: 4 tests PASS。

Run: `swift test --filter BundledWordFrequencyProviderTests 2>&1 | tail -5`
Expected: 7 tests PASS（`testBundledResourceLoadsIfPresent` 不再 skip）。

- [ ] **Step 5: 让词频回填真正生效（回归）**

Run: `swift test --filter VocabularyMaintenanceTests 2>&1 | tail -5`
Expected: 全 PASS。

> 注意：`VocabularyMaintenance.backfillLemmaFrequency` 默认参数是 `WordFrequency.bundled`，资源补齐后生产中会自动开始打标，无需改代码。

- [ ] **Step 6: Commit**

```bash
git add scripts/build_word_families.py \
        Sources/WordRecitingApp/Resources/word_families.json \
        Package.swift \
        Tests/WordRecitingAppTests/Frequency/WordFamilyResourceTests.swift \
        Tests/WordRecitingAppTests/Frequency/BundledWordFrequencyProviderTests.swift
git commit -m "feat(frequency): 落地 BNC/COCA 词族表资源并修掉假测试"
```

---
