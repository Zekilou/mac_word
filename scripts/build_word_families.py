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
