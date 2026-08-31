#!/usr/bin/env bash
set -euo pipefail

# ---- 解析参数 ----
SKIP_BUILD=0
MAKE_ZIP=0
OUTPUT_DIR=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-build) SKIP_BUILD=1; shift ;;
        --zip)        MAKE_ZIP=1; shift ;;
        -o|--output)  OUTPUT_DIR="$2"; shift 2 ;;
        -h|--help)    cat <<'HELP'; exit 0 ;;
用法:
  ./scripts/create-app-bundle.sh                swift build -c release -> 组装 .app
  ./scripts/create-app-bundle.sh --skip-build   跳构建，复用已有 .build/release/
  ./scripts/create-app-bundle.sh -o ./dist      指定输出目录
  ./scripts/create-app-bundle.sh --zip          同时产出 APP-VER-macos-arm64.zip
HELP
        *) echo "未知参数: $1"; exit 1 ;;
    esac
done

# ---- 身份常量（与 Sources/WordRecitingApp/App/AppIdentity.swift 保持同步）----
# SPM 内部产品/模块名 = WordRecitingApp（改了会牵 Package.resolved / Bundle.module）
# 用户可见品牌名 = wordincontxt
SPM_PRODUCT="WordRecitingApp"
APP_NAME="wordincontxt"
APP_DISPLAY="wordincontxt"
VER_SHORT="1.0.0"
VER_BUILD="1"
BUNDLE_ID="com.zekilou.wordincontxt"
MIN_OS="14.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_ROOT/.build/release"
if [[ -z "$OUTPUT_DIR" ]]; then OUTPUT_DIR="$PROJECT_ROOT"; fi
APP_BUNDLE="$OUTPUT_DIR/$APP_NAME.app"

# 输入文件路径（都用 SPM 原始产物名）
BIN_IN="$BUILD_DIR/$SPM_PRODUCT"
RES_BUNDLE="$BUILD_DIR/${SPM_PRODUCT}_${SPM_PRODUCT}.bundle"
GRDB_BUNDLE="$BUILD_DIR/GRDB_GRDB.bundle"
FRAMEWORK="$BUILD_DIR/llama.framework"

log()  { printf '\033[1;34m==>\033[0m  %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m  %s\n' "$*"; }
ok()   { printf '\033[1;32m::\033[0m  %s\n' "$*"; }

# ========= Step 1: 可选构建 =========
if [[ $SKIP_BUILD -eq 0 ]]; then
    log "swift build -c release --disable-sandbox ..."
    # --disable-sandbox：避免 SwiftPM 在受限 shell 中 manifest 编译报 sandbox_apply: Operation not permitted
    (cd "$PROJECT_ROOT" && swift build -c release --disable-sandbox 2>&1 | tail -5)
else
    warn "--skip-build：跳过构建"
fi

# ========= Step 2: 校验 release 产物 =========
log "校验 release 产物 ..."
MISSING=0
for f in "$BIN_IN" "$RES_BUNDLE" "$GRDB_BUNDLE" "$FRAMEWORK"; do
    if [[ ! -e "$f" ]]; then warn "  缺失: $f"; MISSING=1; fi
done
if [[ $MISSING -eq 1 ]]; then echo "中止：release 不完整"; exit 1; fi
ok "  就位"

# ========= Step 3: 清理 + 建结构 =========
log "组装 $APP_NAME.app bundle ..."
if [[ -e "$APP_BUNDLE" ]]; then warn "  移除旧 $APP_BUNDLE"; rm -rf "$APP_BUNDLE"; fi
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Frameworks"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# ========= Step 4: 拷贝（注意二进制改名：WordRecitingApp -> wordincontxt）=========
log "拷贝二进制/Frameworks/Resources ..."
# 二进制：SPM 产出叫 WordRecitingApp，拷贝到 .app 里改名为 wordincontxt
cp    "$BIN_IN"        "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp -R "$RES_BUNDLE"    "$APP_BUNDLE/Contents/Resources/"
cp -R "$GRDB_BUNDLE"   "$APP_BUNDLE/Contents/Resources/"
cp -R "$FRAMEWORK"     "$APP_BUNDLE/Contents/Frameworks/"
find "$APP_BUNDLE" -name ".DS_Store" -delete 2>/dev/null || true
ok "  完成"

# ========= Step 5: RPATH 校正 =========
log "校正 RPATH ..."
APP_BIN="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_BIN" 2>/dev/null \
    || warn "  @executable_path/../Frameworks 已存在，跳过"

# 清理 Xcode 工具链 rpath
otool -l "$APP_BIN" | grep -A2 "LC_RPATH" | grep "Xcode.app" \
  | while IFS= read -r line; do
        rpath="$(echo "$line" | sed -E 's/^[[:space:]]*path[[:space:]]+//' \
                              | sed -E 's/[[:space:]]*\(offset[[:space:]][0-9]+\)[[:space:]]*$//')"
        if install_name_tool -delete_rpath "$rpath" "$APP_BIN" 2>/dev/null; then
            ok "  移除 Xcode RPATH: $rpath"
        fi
    done
ok "  RPATH 校正完成"

# ========= Step 6: Info.plist =========
log "写入 Info.plist ..."
PLIST="$APP_BUNDLE/Contents/Info.plist"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${APP_DISPLAY}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_DISPLAY}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VER_SHORT}</string>
    <key>CFBundleVersion</key>
    <string>${VER_BUILD}</string>
    <key>LSMinimumSystemVersion</key>
    <string>${MIN_OS}</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright (c) 2026. Pure local app. No telemetry.</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.education</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSSupportsAutomaticTermination</key>
    <false/>
    <key>LSSupportsSuddenTermination</key>
    <false/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
</dict>
</plist>
EOF
ok "  ID=${BUNDLE_ID}, 版本=${VER_SHORT} build ${VER_BUILD}"

# ========= Step 7: 结构校验 =========
log "校验结构 ..."
ERRS=0
check() { if [[ ! -e "$1" ]]; then warn "  缺: $1"; ERRS=1; fi; }
check "$APP_BUNDLE/Contents/Info.plist"
check "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
check "$APP_BUNDLE/Contents/Frameworks/llama.framework/Versions/A/llama"
check "$APP_BUNDLE/Contents/Resources/${SPM_PRODUCT}_${SPM_PRODUCT}.bundle/glove50d.bin"
check "$APP_BUNDLE/Contents/Resources/GRDB_GRDB.bundle/PrivacyInfo.xcprivacy"
if [[ $ERRS -eq 1 ]]; then echo "中止：结构校验失败"; exit 1; fi
ok "  完整"

# ========= Step 8: dyld 一览 =========
log "链接与 RPATH："
otool -L "$APP_BIN" | grep -E "llama|rpath" || true
echo "    RPATH:"
otool -l "$APP_BIN" | grep -A2 "LC_RPATH" | grep "path " | sed 's/^/        /'

# ========= Step 9: 可选 zip =========
ZIP_PATH=""
if [[ $MAKE_ZIP -eq 1 ]]; then
    log "打 zip 资产 ..."
    ZIP_NAME="${APP_NAME}-${VER_SHORT}-macos-arm64.zip"
    ZIP_PATH="$OUTPUT_DIR/$ZIP_NAME"
    rm -f "$ZIP_PATH"
    # 使用 ditto（+ zip 内保留 .app 的隔离扩展属性元数据更好）
    (cd "$OUTPUT_DIR" && /usr/bin/ditto -c -k --keepParent --sequesterRsrc "$APP_NAME.app" "$ZIP_NAME")
    ok "  输出 $ZIP_PATH ($(du -sh "$ZIP_PATH" | cut -f1))"
fi

# ========= Done =========
SIZE="$(du -sh "$APP_BUNDLE" | cut -f1)"
echo
echo "=========================================================="
ok "打包完成！"
echo
echo "  App:   $APP_BUNDLE ($SIZE)"
[[ -n "$ZIP_PATH" ]] && echo "  Zip:   $ZIP_PATH"
echo
echo "  本机打开:  open '$APP_BUNDLE'"
echo
echo "  他人机器首次打开（绕 Gatekeeper）:"
echo "    右键 $APP_NAME.app -> 打开 -> 在弹窗中再点「打开」"
echo "    或终端:  xattr -d com.apple.quarantine $APP_NAME.app"
echo "=========================================================="
