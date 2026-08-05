#!/usr/bin/env bash
# Echo .app 打包脚本
# 把 SPM release 产物套上标准 macOS bundle 外壳,双击即可运行
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Echo"
DIST_DIR="dist"
APP_BUNDLE="$DIST_DIR/${APP_NAME}.app"

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

# 清除 quarantine,避免本机构建被 Gatekeeper 拦截
xattr -cr "$APP_BUNDLE" 2>/dev/null || true

echo
echo "✅ 完成 → $APP_BUNDLE"
echo "   双击运行: open '$APP_BUNDLE'"
echo "   拖进 /Applications 即可常驻"
