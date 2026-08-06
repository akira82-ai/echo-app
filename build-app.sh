#!/usr/bin/env bash
# Echo .app 打包脚本
# 把 SPM release 产物套上标准 macOS bundle 外壳,双击即可运行
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Echo"
BUNDLE_ID="com.akira82.echo"
DIST_DIR="dist"
APP_BUNDLE="$DIST_DIR/${APP_NAME}.app"
ZIP_ARCHIVE="$DIST_DIR/${APP_NAME}.app.zip"

# 签名身份:优先用固定自签证书(见 setup-codesign.sh),回退到 adhoc。
# 两者都会固定 identifier=com.akira82.echo —— 这点是 TCC 识别 App 的关键,
# 缺了它,linker 自带签名会把 identifier 退化成裸名 "Echo",TCC 认不出。
SIGN_IDENTITY="-"   # 默认 adhoc
if security find-identity -v -p codesigning 2>/dev/null | grep -q "Echo Self-Sign"; then
    SIGN_IDENTITY="Echo Self-Sign"
fi

echo "🔨 编译 release 产物..."
swift build -c release

echo "📦 组装 .app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# 可执行文件 → Contents/MacOS/
cp ".build/release/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Info.plist → Contents/
cp Info.plist "$APP_BUNDLE/Contents/Info.plist"

# 图标(若有)
[ -f "AppIcon.icns" ] && cp AppIcon.icns "$APP_BUNDLE/Contents/Resources/$APP_NAME.icns"

# 签名:固定 identifier,让 TCC 能按 bundleID 稳定识别。
# 关键修复 —— 不签名时 macOS 用 linker 自带的 adhoc 签名,identifier 退化成裸名,
# 且每次编译 cdhash 变,导致辅助功能权限(Accessibility/TCC)失效,Paster 降级不粘。
echo "✍️  签名 (identity: ${SIGN_IDENTITY}, identifier: ${BUNDLE_ID})..."
codesign --force \
    --sign "$SIGN_IDENTITY" \
    --identifier "$BUNDLE_ID" \
    --options runtime \
    "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# 清除 quarantine,避免本机构建被 Gatekeeper 拦截
xattr -cr "$APP_BUNDLE" 2>/dev/null || true

# 同步生成 Release 可上传的压缩包,避免沿用旧产物。
rm -f "$ZIP_ARCHIVE"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_ARCHIVE"

echo
echo "✅ 完成 → $APP_BUNDLE"
echo "📦 Release 资产 → $ZIP_ARCHIVE"
echo "   签名验证:"
codesign -dv "$APP_BUNDLE" 2>&1 | grep -E "Identifier|Signature|TeamIdentifier" | sed 's/^/     /'
echo
echo "   双击运行: open '$APP_BUNDLE'"
echo "   拖进 /Applications 即可常驻"
