#!/usr/bin/env bash
# Exercise Sparkle's real installer in disposable app bundles; never replace Echo.
set -euo pipefail
cd "$(dirname "$0")/.."
TOOLS="$(find .build/artifacts -path '*/Sparkle/bin/generate_appcast' -type f -print -quit)"
[[ -n "$TOOLS" ]] || { echo 'Run swift build first' >&2; exit 1; }
TOOLS="$(dirname "$TOOLS")"
FRAMEWORK="$(dirname "$TOOLS")/Sparkle.xcframework/macos-arm64_x86_64"
TEST_ROOT="$(mktemp -d /tmp/echo-update-test.XXXXXX)"
SIGN_IDENTITY="${ECHO_SIGN_IDENTITY:-Echo Self-Sign}"
SERVER_PID=''
trap 'if [[ -n "$SERVER_PID" ]]; then kill "$SERVER_PID" 2>/dev/null || true; fi' EXIT
# Use an ephemeral test key, never the production Keychain signing account.
swift - "$TEST_ROOT" <<'SWIFT'
import Foundation
import CryptoKit
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let key = Curve25519.Signing.PrivateKey()
let path = root.appendingPathComponent("test-key")
try key.rawRepresentation.base64EncodedString().write(to: path, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
try key.publicKey.rawRepresentation.base64EncodedString().write(to: root.appendingPathComponent("public-key"), atomically: true, encoding: .utf8)
SWIFT
# The private test key is removed even if an assertion fails; evidence stays available.
trap 'rm -f "$TEST_ROOT/test-key"; if [[ -n "$SERVER_PID" ]]; then kill "$SERVER_PID" 2>/dev/null || true; fi' EXIT
# Compile the actual controller, excluding only its SwiftUI view declarations.
python3 - "$TEST_ROOT/UpdateController.swift" <<'PYDRIVER'
import pathlib, sys
source = pathlib.Path('Sources/Echo/UpdateController.swift').read_text()
source = source.split('struct InlineUpdateButton:')[0]
# Only host application dependencies are stubbed; updater logic remains unchanged.
source += '''
final class QuickPanelController {
    static let shared = QuickPanelController()
    var isAnswering = false
}
enum L10n {
    static func text(_ key: String) -> String { key }
    static func format(_ key: String, _ value: String) -> String { key + value }
}
'''
pathlib.Path(sys.argv[1]).write_text(source)
PYDRIVER
swiftc -parse-as-library -F "$FRAMEWORK" "$TEST_ROOT/UpdateController.swift" Tests/UpdateIntegration/UpdateHarness.swift \
  -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks -o "$TEST_ROOT/UpdateHarness"
for SCENARIO in valid archive-tampered feed-tampered; do
  CASE_ROOT="$TEST_ROOT/$SCENARIO"
  mkdir -p "$CASE_ROOT/feed" "$CASE_ROOT/installed" "$CASE_ROOT/new"
  python3 -u - "$CASE_ROOT" > "$CASE_ROOT/server.log" 2>&1 <<'PY' &
import functools, http.server, pathlib, sys
root = pathlib.Path(sys.argv[1])
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(root/'feed')))
(root/'port').write_text(str(server.server_port))
server.serve_forever()
PY
  SERVER_PID=$!
  for ((i=0; i<50; i++)); do [[ -f "$CASE_ROOT/port" ]] && break; sleep 0.1; done
  PORT="$(cat "$CASE_ROOT/port")"
  for VERSION in 1 2; do
    if [[ "$VERSION" == 1 ]]; then APP="$CASE_ROOT/installed/UpdateHarness.app"; else APP="$CASE_ROOT/new/UpdateHarness.app"; fi
    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks"
    cp "$TEST_ROOT/UpdateHarness" "$APP/Contents/MacOS/UpdateHarness"
    ditto "$FRAMEWORK/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
    python3 - "$APP" "$VERSION" "$CASE_ROOT" "$PORT" "$TEST_ROOT/public-key" <<'PY'
import pathlib, plistlib, sys
app, version, root, port, key = sys.argv[1:]
config = dict(CFBundleIdentifier='com.akira82.echo.updatetest.'+pathlib.Path(root).parent.name.split('.')[-1]+'.'+pathlib.Path(root).name,
 CFBundleName='UpdateHarness', CFBundleExecutable='UpdateHarness', CFBundlePackageType='APPL', CFBundleVersion=version,
 CFBundleShortVersionString=version+'.0', LSUIElement=True, LSMinimumSystemVersion='13.0',
 SUFeedURL=f'http://127.0.0.1:{port}/appcast.xml', SUPublicEDKey=pathlib.Path(key).read_text(),
 SURequireSignedFeed=True, SUSignedFeedFailureExpirationInterval=0, SUVerifyUpdateBeforeExtraction=True,
 SUEnableAutomaticChecks=False, SUAllowsAutomaticUpdates=False, UpdateTestRoot=root,
 NSAppTransportSecurity=dict(NSAllowsLocalNetworking=True))
with open(pathlib.Path(app)/'Contents/Info.plist', 'wb') as f: plistlib.dump(config, f)
PY
    FW="$APP/Contents/Frameworks/Sparkle.framework"
    while IFS= read -r -d '' nested; do
      codesign --force --sign "$SIGN_IDENTITY" --preserve-metadata=identifier,entitlements "$nested"
    done < <(find "$FW/Versions/B" -depth \( -name '*.app' -o -name '*.xpc' -o -name Autoupdate \) -print0)
    codesign --force --sign "$SIGN_IDENTITY" "$FW"
    codesign --force --sign "$SIGN_IDENTITY" "$APP"
    codesign --verify --deep --strict "$APP"
  done
  ditto -c -k --sequesterRsrc --keepParent "$CASE_ROOT/new/UpdateHarness.app" "$CASE_ROOT/feed/UpdateHarness-2.zip"
  "$TOOLS/generate_appcast" --ed-key-file "$TEST_ROOT/test-key" --maximum-deltas 0 \
    --download-url-prefix "http://127.0.0.1:$PORT/" "$CASE_ROOT/feed"
  "$TOOLS/sign_update" --ed-key-file "$TEST_ROOT/test-key" --verify "$CASE_ROOT/feed/appcast.xml"
  python3 - "$CASE_ROOT" "$SCENARIO" <<'PY'
import pathlib, sys
root, scenario = pathlib.Path(sys.argv[1]), sys.argv[2]
if scenario == 'archive-tampered':
 p=root/'feed/UpdateHarness-2.zip'; data=bytearray(p.read_bytes()); data[100]^=1; p.write_bytes(data)
elif scenario == 'feed-tampered':
 p=root/'feed/appcast.xml'; data=p.read_bytes(); assert b'<title>2.0</title>' in data
 p.write_bytes(data.replace(b'<title>2.0</title>', b'<title>9.0</title>'))
PY
  OLD_HASH="$(shasum -a 256 "$CASE_ROOT/installed/UpdateHarness.app/Contents/Info.plist")"
  open "$CASE_ROOT/installed/UpdateHarness.app"
  for ((i=0; i<100; i++)); do
    if [[ -f "$CASE_ROOT/events.txt" ]] && rg -q 'SUCCESS|REJECTED|ERROR' "$CASE_ROOT/events.txt"; then break; fi
    sleep 0.5
  done
  cat "$CASE_ROOT/events.txt"
  if [[ "$SCENARIO" == valid ]]; then
    rg -q 'SUCCESS NEW VERSION' "$CASE_ROOT/events.txt"
    rg -q 'WAITING FOR DOWNLOAD CLICK' "$CASE_ROOT/events.txt"
    rg -q 'BLOCKED RESTART VERIFIED' "$CASE_ROOT/events.txt"
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$CASE_ROOT/installed/UpdateHarness.app/Contents/Info.plist")" == 2 ]]
  else
    rg -q 'REJECTED' "$CASE_ROOT/events.txt"
    rg -q 'PHASE failed' "$CASE_ROOT/events.txt"
    if [[ "$SCENARIO" == archive-tampered ]]; then
      rg -q 'REJECTED updates.inline.verifyFailed' "$CASE_ROOT/events.txt"
    else
      rg -q 'REJECTED updates.inline.checkFailed' "$CASE_ROOT/events.txt"
    fi
    if rg -q 'START 2|PHASE ready|PHASE installing' "$CASE_ROOT/events.txt"; then
      echo 'Rejected update reached installation readiness' >&2; exit 1
    fi
    if [[ "$SCENARIO" == feed-tampered ]] && rg -q 'PHASE available|PHASE downloading|PHASE verifying' "$CASE_ROOT/events.txt"; then
      echo 'Tampered feed was accepted' >&2; exit 1
    fi
    [[ "$OLD_HASH" == "$(shasum -a 256 "$CASE_ROOT/installed/UpdateHarness.app/Contents/Info.plist")" ]]
  fi
  codesign --verify --deep --strict "$CASE_ROOT/installed/UpdateHarness.app"
  kill "$SERVER_PID"; wait "$SERVER_PID" 2>/dev/null || true
  SERVER_PID=''
done
echo "PASS real replacement/relaunch and rejection of tampered archive/feed. Evidence: $TEST_ROOT"
