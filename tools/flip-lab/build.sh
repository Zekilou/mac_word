#!/bin/bash
# FlipLab 构建/运行脚本（独立小程序，不碰主 App 的 SPM 构建）
#
#   tools/flip-lab/build.sh          # 编译
#   tools/flip-lab/build.sh --run    # 编译并运行
#   tools/flip-lab/build.sh --clean  # 清理产物
#
# 为什么不用 swift build：
#   主工程是 SPM 单 target，加一个可执行 target 会牵动整个 Package.resolved 与
#   主 App 的编译单元；调参只需要「2 秒看到效果」，所以用 swiftc 直接编成 .app。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LAB="$ROOT/tools/flip-lab"
OUT="$LAB/.build"
APP="$OUT/FlipLab.app"

if [[ "${1:-}" == "--clean" ]]; then
    rm -rf "$OUT"
    echo "已清理 $OUT"
    exit 0
fi

mkdir -p "$APP/Contents/MacOS"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>       <string>FlipLab</string>
    <key>CFBundleIdentifier</key>       <string>com.zekilou.fliplab</string>
    <key>CFBundleName</key>             <string>FlipLab</string>
    <key>CFBundlePackageType</key>      <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>LSMinimumSystemVersion</key>   <string>14.0</string>
    <key>NSHighResolutionCapable</key>  <true/>
</dict>
</plist>
PLIST

echo "编译 FlipLab…"
swiftc -O \
    -target arm64-apple-macosx14.0 \
    -parse-as-library \
    "$LAB/FlipLab.swift" \
    -o "$APP/Contents/MacOS/FlipLab"

echo "完成：$APP"

if [[ "${1:-}" == "--run" ]]; then
    pkill -f "FlipLab.app/Contents/MacOS/FlipLab" 2>/dev/null || true
    sleep 0.3
    open "$APP"
fi
