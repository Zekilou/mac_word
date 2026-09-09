#!/usr/bin/env python3
"""从 BNC/COCA 词族表生成内置 word_families.json。

数据源：Nation 的 BNC/COCA word family lists（1k~25k，每 1000 词族一个带）。
支持两种输入布局：
  1) --input <tsv>      单文件：每行一个词族，空格/逗号分隔成员；行序即词族频次排序。
  2) --input-dir <dir>  目录：读取目录下 *.txt/*.tsv，按文件名里的数字（1、2…25 或 1k…25k）
                        排序，每个文件 = 一个词族带；文件内行序为族序。

文件内容布局由 --layout 控制：
  auto（默认）  自动探测；含缩进行（行首空白）即视为官方 baseword 布局。
  baseword      官方 basewrdN.txt 布局：顶格行为词头（新词族开始），缩进行为同族成员，
                行尾可带频次；成员含词头本身。
  lines         每行一个词族，行内以空格/逗号分隔成员。

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


def read_lines(path):
    return path.read_text(encoding="utf-8").splitlines()


def detect_layout(path):
    """存在任何缩进行即判定为官方 baseword 布局（首行词头不缩进）。"""
    for raw in read_lines(path):
        if raw.strip() and not raw.lstrip().startswith("#") and raw[:1].isspace():
            return "baseword"
    return "lines"


def dedupe(members):
    seen = set()
    result = []
    for member in members:
        key = member.lower()
        if not key or key in seen:
            continue
        seen.add(key)
        result.append(key)
    return result


def parse_lines(path):
    """每行一个词族，返回 (频次=0, 成员)。"""
    families = []
    for raw in read_lines(path):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        members = dedupe(parse_members(line))
        if members:
            families.append((0, members))
    return families


def parse_baseword(path):
    """官方 basewrdN.txt：顶格 = 词头（行尾为其族频次），缩进 = 同族成员。

    返回 (族频次, 成员)，成员含词头本身。
    """
    families = []
    current = None
    for raw in read_lines(path):
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        token = raw.split()
        if not token:
            continue
        word = token[0]
        freq = int(token[-1]) if token[-1].isdigit() else 0
        if raw[:1].isspace():
            if current is None:
                continue
            current.append(word)
        else:
            current = [word]
            families.append((freq, current))
    return [(freq, dedupe(family)) for freq, family in families if family]


def parse_file(path, layout):
    if layout == "auto":
        layout = detect_layout(path)
    if layout == "baseword":
        return parse_baseword(path)
    return parse_lines(path)


def band_from_name(name):
    numbers = re.findall(r"\d+", name)
    if not numbers:
        return None
    value = int(numbers[0])
    if value > 25 and value % 1000 == 0:
        value //= 1000
    return min(max(value, 1), 25)


def build_families(family_lists):
    """把「每个带一组词族」展平成 rank/band 递增的条目。"""
    families = []
    rank = 0
    for band, members in family_lists:
        rank += 1
        families.append({"rank": rank, "band": band, "members": members})
    return families


def collect_single(path, layout):
    entries = []
    for index, (freq, members) in enumerate(parse_file(path, layout)):
        entries.append((min(index // 1000 + 1, 25), freq, members))
    return order_entries(entries)


def collect_directory(directory, layout):
    files = sorted(
        [p for p in directory.iterdir() if p.suffix.lower() in {".txt", ".tsv"}],
        key=lambda p: (band_from_name(p.name) or 99, p.name),
    )
    if not files:
        sys.exit("目录内没有 .txt/.tsv 文件：%s" % directory)
    entries = []
    rank = 0
    for path in files:
        band = band_from_name(path.name) or min((rank // 1000) + 1, 25)
        for freq, members in parse_file(path, layout):
            rank += 1
            entries.append((band, freq, members))
    return order_entries(entries)


def order_entries(entries):
    """带内按族频次降序（官方文件同带内为字母序，这里还原频次序）。"""
    ordered = sorted(entries, key=lambda item: (item[0], -item[1]))
    return [(band, members) for band, _freq, members in ordered]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", help="单文件词族表（每行一个词族）")
    parser.add_argument("--input-dir", help="按带分文件的目录（1k~25k）")
    parser.add_argument("--output", required=True)
    parser.add_argument("--source", default="bnc-coca-25k")
    parser.add_argument("--layout", default="auto",
                        choices=["auto", "baseword", "lines"])
    args = parser.parse_args()

    if bool(args.input) == bool(args.input_dir):
        sys.exit("必须且只能指定 --input 或 --input-dir 之一")

    if args.input:
        path = Path(args.input)
        if not path.exists():
            sys.exit("输入文件不存在：%s" % path)
        family_lists = collect_single(path, args.layout)
    else:
        directory = Path(args.input_dir)
        if not directory.is_dir():
            sys.exit("输入目录不存在：%s" % directory)
        family_lists = collect_directory(directory, args.layout)

    if not family_lists:
        sys.exit("解析结果为空")

    families = build_families(family_lists)
    payload = {"source": args.source, "families": families}
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
    print("写入 %d 个词族 -> %s" % (len(families), output))


if __name__ == "__main__":
    main()
