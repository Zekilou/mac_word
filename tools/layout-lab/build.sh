#!/bin/bash
# LayoutLab 构建/运行脚本（独立小程序，不碰主 App 的 SPM 构建）
#
#   tools/layout-lab/build.sh          # 编译
#   tools/layout-lab/build.sh --run    # 编译并运行
#   tools/layout-lab/build.sh --clean  # 清理产物
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LAB="$ROOT/tools/layout-lab"
OUT="$LAB/.build"
APP="$OUT/LayoutLab.app"

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
    <key>CFBundleExecutable</key>       <string>LayoutLab</string>
    <key>CFBundleIdentifier</key>       <string>com.zekilou.layoutlab</string>
    <key>CFBundleName</key>             <string>LayoutLab</string>
    <key>CFBundlePackageType</key>      <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>LSMinimumSystemVersion</key>   <string>14.0</string>
    <key>NSHighResolutionCapable</key>  <true/>
</dict>
</plist>
PLIST

echo "编译 LayoutLab…"
swiftc -O \
    -target arm64-apple-macosx14.0 \
    -parse-as-library \
    "$LAB/LayoutLab.swift" \
    -o "$APP/Contents/MacOS/LayoutLab"

echo "完成：$APP"

if [[ "${1:-}" == "--run" ]]; then
    pkill -f "LayoutLab.app/Contents/MacOS/LayoutLab" 2>/dev/null || true
    sleep 0.3
    open "$APP"
fi
