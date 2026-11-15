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
DMG_ARCHIVE="$DIST_DIR/${APP_NAME}.dmg"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Info.plist)"

# 签名身份:优先用固定自签证书(见 setup-codesign.sh),回退到 adhoc。
# 两者都会固定 identifier=com.akira82.echo —— 这点是 TCC 识别 App 的关键,
# 缺了它,linker 自带签名会把 identifier 退化成裸名 "Echo",TCC 认不出。
SIGN_IDENTITY="${ECHO_SIGN_IDENTITY:--}"   # Explicit distribution identity, or local signing
if [[ "$SIGN_IDENTITY" == "-" ]] && security find-identity -v -p codesigning 2>/dev/null | grep -q "Echo Self-Sign"; then
    SIGN_IDENTITY="Echo Self-Sign"
fi

# Updates are opt-in per distribution build; never ship a placeholder key or feed.
python3 - <<'PYCONFIG'
import os, base64, urllib.parse
feed, key = os.environ.get("ECHO_UPDATE_FEED_URL", ""), os.environ.get("ECHO_UPDATE_PUBLIC_KEY", "")
if feed or key:
    url = urllib.parse.urlparse(feed)
    if url.scheme != "https" or not url.hostname or url.username or url.password or url.fragment:
        raise SystemExit("Invalid ECHO_UPDATE_FEED_URL: HTTPS without credentials required")
    try:
        if len(base64.b64decode(key, validate=True)) != 32: raise ValueError()
    except ValueError:
        raise SystemExit("ECHO_UPDATE_PUBLIC_KEY must be a base64 Ed25519 public key")
PYCONFIG

echo "🔨 编译 Echo v${VERSION} (build ${BUILD_NUMBER}) release 产物..."
BUILD_ARGS=(-c release)
if [[ "${ECHO_UNIVERSAL:-0}" == "1" ]]; then
    # Build each slice separately: multi-arch SwiftPM otherwise requires full Xcode/xcbuild.
    swift build -c release --arch arm64
    BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"
    swift build -c release --arch x86_64
    INTEL_BIN_DIR="$(swift build -c release --arch x86_64 --show-bin-path)"
else
    swift build "${BUILD_ARGS[@]}"
    BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
fi

echo "📦 组装 .app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# 可执行文件 → Contents/MacOS/
if [[ "${ECHO_UNIVERSAL:-0}" == "1" ]]; then
    lipo -create "$BIN_DIR/$APP_NAME" "$INTEL_BIN_DIR/$APP_NAME" -output "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
else
    cp "$BIN_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
fi

# SwiftPM 本地化资源 → Contents/Resources/
RESOURCE_BUNDLE="$BIN_DIR/${APP_NAME}_${APP_NAME}.bundle"
if [[ ! -d "$RESOURCE_BUNDLE" ]]; then
    echo "❌ Missing localization bundle: $RESOURCE_BUNDLE" >&2
    exit 1
fi
cp -R "$RESOURCE_BUNDLE" "$APP_BUNDLE/Contents/Resources/"
MARKDOWN_BUNDLE="$BIN_DIR/Echo_MarkdownConversion.bundle"
if [[ ! -d "$MARKDOWN_BUNDLE" ]]; then
    echo "❌ Missing Markdown conversion bundle: $MARKDOWN_BUNDLE" >&2
    exit 1
fi
cp -R "$MARKDOWN_BUNDLE" "$APP_BUNDLE/Contents/Resources/"

# Embed the exact framework SwiftPM linked, including its installer helpers.
SPARKLE_FRAMEWORK="$(find .build/artifacts -path '*/macos-arm64_x86_64/Sparkle.framework' -type d -print -quit)"
if [[ -z "$SPARKLE_FRAMEWORK" ]]; then
    echo "Missing Sparkle.framework" >&2
    exit 1
fi
mkdir -p "$APP_BUNDLE/Contents/Frameworks"
ditto "$SPARKLE_FRAMEWORK" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath '@executable_path/../Frameworks' "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Info.plist 的系统级文案必须位于主 App bundle 的语言目录中。
for LPROJ_DIR in Sources/Echo/Resources/*.lproj; do
    if [[ -f "$LPROJ_DIR/InfoPlist.strings" ]]; then
        DEST_LPROJ="$APP_BUNDLE/Contents/Resources/$(basename "$LPROJ_DIR")"
        mkdir -p "$DEST_LPROJ"
        cp "$LPROJ_DIR/InfoPlist.strings" "$DEST_LPROJ/InfoPlist.strings"
    fi
done

# Info.plist → Contents/
cp Info.plist "$APP_BUNDLE/Contents/Info.plist"
python3 - "$APP_BUNDLE/Contents/Info.plist" <<'PYPLIST'
import os, plistlib, sys
path = sys.argv[1]
with open(path, "rb") as f: info = plistlib.load(f)
if os.environ.get("ECHO_UPDATE_FEED_URL"):
    info["SUFeedURL"] = os.environ["ECHO_UPDATE_FEED_URL"]
    info["SUPublicEDKey"] = os.environ["ECHO_UPDATE_PUBLIC_KEY"]
with open(path, "wb") as f: plistlib.dump(info, f)
PYPLIST

# Fail early if the bundle version ever drifts from the project source.
BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_BUNDLE/Contents/Info.plist")"
BUNDLE_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_BUNDLE/Contents/Info.plist")"
if [[ "$BUNDLE_VERSION" != "$VERSION" || "$BUNDLE_BUILD" != "$BUILD_NUMBER" ]]; then
    echo "❌ Bundle version mismatch: expected ${VERSION} (${BUILD_NUMBER}), got ${BUNDLE_VERSION} (${BUNDLE_BUILD})" >&2
    exit 1
fi

# 图标(若有)
[ -f "AppIcon.icns" ] && cp AppIcon.icns "$APP_BUNDLE/Contents/Resources/$APP_NAME.icns"

# 签名:固定 identifier,让 TCC 能按 bundleID 稳定识别。
# 关键修复 —— 不签名时 macOS 用 linker 自带的 adhoc 签名,identifier 退化成裸名,
# 且每次编译 cdhash 变,导致辅助功能权限(Accessibility/TCC)失效,Paster 降级不粘。
echo "✍️  签名 (identity: ${SIGN_IDENTITY}, identifier: ${BUNDLE_ID})..."
# Sign nested Sparkle executables from the inside out; never rely on --deep signing.
FRAMEWORK="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B"
for COMPONENT in "$FRAMEWORK/XPCServices/Downloader.xpc" "$FRAMEWORK/XPCServices/Installer.xpc" \
                 "$FRAMEWORK/Autoupdate" "$FRAMEWORK/Updater.app" \
                 "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"; do
    codesign --force --sign "$SIGN_IDENTITY" --preserve-metadata=identifier,entitlements --options runtime --timestamp "$COMPONENT"
done
codesign --force --sign "$SIGN_IDENTITY" --identifier "$BUNDLE_ID" --options runtime --timestamp "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"

# 清除 quarantine,避免本机构建被 Gatekeeper 拦截
xattr -cr "$APP_BUNDLE" 2>/dev/null || true

# 同步生成 Release 可上传的压缩包,避免沿用旧产物。
rm -f "$ZIP_ARCHIVE"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_ARCHIVE"

echo "💿 创建 DMG..."
DMG_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/echo-dmg.XXXXXX")"
trap 'rm -rf "$DMG_STAGE"' EXIT
cp -R "$APP_BUNDLE" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"
rm -f "$DMG_ARCHIVE"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGE" -format UDZO "$DMG_ARCHIVE" >/dev/null

echo
echo "✅ 完成 → $APP_BUNDLE (v${VERSION}, build ${BUILD_NUMBER})"
echo "📦 Release 资产 → $ZIP_ARCHIVE"
echo "💿 Release 资产 → $DMG_ARCHIVE"
echo "   签名验证:"
codesign -dv "$APP_BUNDLE" 2>&1 | grep -E "Identifier|Signature|TeamIdentifier" | sed 's/^/     /'
echo
echo "   双击运行: open '$APP_BUNDLE'"
echo "   拖进 /Applications 即可常驻"
