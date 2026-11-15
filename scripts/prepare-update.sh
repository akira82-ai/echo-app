#!/usr/bin/env bash
# Prepare a signed stable update locally. This script never uploads or publishes.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# != 3 ]]; then
    echo 'Usage: scripts/prepare-update.sh /path/Echo.app https://github.com/OWNER/REPO/releases/download/TAG/ /path/release-notes.txt' >&2
    exit 1
fi
APP="$1"
PREFIX="$2"
NOTES="$3"
[[ -d "$APP" && -f "$NOTES" ]] || { echo 'App or release notes missing' >&2; exit 1; }
# Gatekeeper assessment requires the real distribution identity and notarization.
ARCHS="$(lipo -archs "$APP/Contents/MacOS/Echo")"
[[ "$ARCHS" == *arm64* && "$ARCHS" == *x86_64* ]] || { echo 'Stable updates require a universal build (ECHO_UNIVERSAL=1)' >&2; exit 1; }
codesign --verify --deep --strict "$APP"
spctl --assess --type execute "$APP"
xcrun stapler validate "$APP"
python3 - "$APP/Contents/Info.plist" "$PREFIX" <<'PY'
import base64, plistlib, sys, urllib.parse
with open(sys.argv[1], 'rb') as f: info = plistlib.load(f)
for value in [info.get('SUFeedURL', ''), sys.argv[2]]:
    url = urllib.parse.urlparse(value)
    if url.scheme != 'https' or not url.hostname or url.username or url.password or url.fragment:
        raise SystemExit('HTTPS feed and download URLs without credentials required')
if not sys.argv[2].endswith('/'): raise SystemExit('Download URL prefix must end in /')
try:
    if len(base64.b64decode(info.get('SUPublicEDKey', ''), validate=True)) != 32: raise ValueError()
except ValueError: raise SystemExit('A valid update public key is required')
if not str(info['CFBundleVersion']).isdigit(): raise SystemExit('Build must be a monotonically increasing integer')
if info.get('SUAutomaticallyUpdate') or info.get('SUAllowsAutomaticUpdates'):
    raise SystemExit('Automatic installation is outside the first-release scope')
PY
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
OUT="dist/update-$BUILD"
[[ ! -e "$OUT" ]] || { echo "Refusing to overwrite $OUT" >&2; exit 1; }
GENERATOR="$(find .build/artifacts -path '*/Sparkle/bin/generate_appcast' -type f -print -quit)"
[[ -n "$GENERATOR" ]] || { echo 'Run swift build to resolve Sparkle tools first' >&2; exit 1; }
mkdir -p "$OUT"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/Echo-$BUILD.zip"
cp "$NOTES" "$OUT/Echo-$BUILD.txt"
# The signing key is read directly from Keychain, never passed as a command argument.
"$GENERATOR" --account "${ECHO_UPDATE_KEY_ACCOUNT:-ed25519}" --maximum-deltas 0 \
    --embed-release-notes --download-url-prefix "$PREFIX" \
    --link 'https://github.com/akira82-ai/echo-app' "$OUT"
swift scripts/verify-update.swift "$APP/Contents/Info.plist" "$OUT/appcast.xml" "$OUT/Echo-$BUILD.zip" "$PREFIX"
echo "Prepared $OUT. Upload the immutable ZIP first; publish appcast.xml at SUFeedURL only after verifying its download."
echo 'Preserve older compatible appcast entries when combining releases. Never overwrite an already published ZIP.'
