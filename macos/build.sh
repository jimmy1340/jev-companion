#!/bin/bash
# Local build only: does not install software, request permissions, or launch the app.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${JEV_OUTPUT_DIR:-$PROJECT_DIR/../dist}"
BUILD_DIR="${JEV_BUILD_DIR:-$PROJECT_DIR/.build}"
APP_PATH="$OUTPUT_DIR/Jev伴聊.app"
BUNDLE_ID="local.jev.wechatcompanion"
TEST_ONLY=false
if [[ "${1:-}" == "--test-only" ]]; then
    TEST_ONLY=true
elif [[ -n "${1:-}" ]]; then
    printf 'Usage: %s [--test-only]\n' "$0" >&2
    exit 2
fi

mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"
BUILD_DIR="$(cd "$BUILD_DIR" && pwd)"
SWIFTC="$(/usr/bin/xcrun --find swiftc)"
SDK_PATH="$(/usr/bin/xcrun --show-sdk-path)"
COMPILER_FLAGS=(-swift-version 5 -sdk "$SDK_PATH" -target "$(uname -m)-apple-macosx13.0"
    -module-cache-path "$BUILD_DIR/module-cache")

# Some CLT upgrades leave two SwiftBridging module maps. Mask the legacy duplicate
# for this invocation only. Never edit /Library/Developer or the selected toolchain.
DEVELOPER_DIR_PATH="$(/usr/bin/xcode-select -p)"
SWIFT_HEADERS="$DEVELOPER_DIR_PATH/usr/include/swift"
if [[ -f "$SWIFT_HEADERS/module.modulemap" && -f "$SWIFT_HEADERS/bridging.modulemap" ]] &&
   /usr/bin/grep -q 'module SwiftBridging' "$SWIFT_HEADERS/module.modulemap" &&
   /usr/bin/grep -q 'module SwiftBridging' "$SWIFT_HEADERS/bridging.modulemap"; then
    /usr/bin/python3 - "$BUILD_DIR" "$SWIFT_HEADERS/module.modulemap" <<'PY'
import json
import pathlib
import sys
build = pathlib.Path(sys.argv[1])
empty = build / "empty-legacy.modulemap"
empty.write_text("// Legacy duplicate masked for this build only.\n", encoding="utf-8")
(build / "toolchain-overlay.json").write_text(json.dumps({
    "version": 0,
    "roots": [{"type": "file", "name": sys.argv[2], "external-contents": str(empty)}]
}), encoding="utf-8")
PY
    COMPILER_FLAGS+=(-vfsoverlay "$BUILD_DIR/toolchain-overlay.json")
    printf 'Using a local VFS overlay for duplicate CLT SwiftBridging metadata.\n'
fi

if [[ "$TEST_ONLY" == true ]]; then
    printf 'Compiling synthetic reader fixtures...\n'
    "$SWIFTC" "${COMPILER_FLAGS[@]}" "$PROJECT_DIR/Sources/WeChatReader.swift" \
        "$PROJECT_DIR/Tests/ReaderFixtures.swift" -o "$BUILD_DIR/reader-fixtures"
    "$BUILD_DIR/reader-fixtures"
    printf 'Compiling synthetic AppModel state fixtures...\n'
    "$SWIFTC" "${COMPILER_FLAGS[@]}" "$PROJECT_DIR/Sources/WeChatReader.swift" \
        "$PROJECT_DIR/Sources/AppModel.swift" "$PROJECT_DIR/Tests/AppModelFixtures.swift" \
        -framework AppKit -framework SwiftUI -framework ApplicationServices -framework CryptoKit \
        -o "$BUILD_DIR/app-model-fixtures"
    "$BUILD_DIR/app-model-fixtures"
    PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 -m unittest discover -s "$PROJECT_DIR/backend/tests" -v
    exit 0
fi

for REQUIRED_FILE in Sources/App.swift Sources/AppModel.swift Sources/WeChatReader.swift backend/engine.py Info.plist; do
    if [[ ! -f "$PROJECT_DIR/$REQUIRED_FILE" ]]; then
        printf 'Missing required source: %s\n' "$REQUIRED_FILE" >&2
        exit 1
    fi
done
/usr/bin/plutil -lint "$PROJECT_DIR/Info.plist"
if [[ -e "$APP_PATH" ]]; then
    EXISTING_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)"
    if [[ "$EXISTING_ID" != "$BUNDLE_ID" ]]; then
        printf 'Refusing to replace unrelated output at %s\n' "$APP_PATH" >&2
        exit 1
    fi
fi

STAGING_DIR="$(mktemp -d "$BUILD_DIR/staging.XXXXXX")"
STAGING_APP="$STAGING_DIR/Jev伴聊.app"
PREVIOUS_APP=""
cleanup() {
    if [[ -n "$PREVIOUS_APP" && -e "$PREVIOUS_APP" && ! -e "$APP_PATH" ]]; then
        mv "$PREVIOUS_APP" "$APP_PATH"
    fi
    if [[ -d "$STAGING_DIR" ]]; then /bin/rm -rf "$STAGING_DIR"; fi
}
trap cleanup EXIT
mkdir -p "$STAGING_APP/Contents/MacOS" "$STAGING_APP/Contents/Resources"
cp "$PROJECT_DIR/Info.plist" "$STAGING_APP/Contents/Info.plist"
printf 'Compiling Jev伴聊 for macOS 13+...\n'
"$SWIFTC" "${COMPILER_FLAGS[@]}" -O -parse-as-library \
    "$PROJECT_DIR"/Sources/*.swift \
    -framework AppKit -framework SwiftUI -framework ApplicationServices -framework CryptoKit \
    -o "$STAGING_APP/Contents/MacOS/JevWeChatAssistant"
/usr/bin/python3 - "$PROJECT_DIR/backend" "$STAGING_APP/Contents/Resources/Backend" <<'PY'
import shutil
import sys
shutil.copytree(sys.argv[1], sys.argv[2], ignore=shutil.ignore_patterns("__pycache__", "*.pyc", ".DS_Store"))
PY
/usr/bin/codesign --force --sign - --timestamp=none --identifier "$BUNDLE_ID" "$STAGING_APP"
/usr/bin/codesign --verify --deep --strict "$STAGING_APP"

if [[ -e "$APP_PATH" ]]; then
    PREVIOUS_DIR="$(mktemp -d "$BUILD_DIR/previous.XXXXXX")"
    PREVIOUS_APP="$PREVIOUS_DIR/Jev伴聊.app"
    mv "$APP_PATH" "$PREVIOUS_APP"
fi
if ! mv "$STAGING_APP" "$APP_PATH"; then
    if [[ -n "$PREVIOUS_APP" && -e "$PREVIOUS_APP" && ! -e "$APP_PATH" ]]; then
        mv "$PREVIOUS_APP" "$APP_PATH"
    fi
    printf 'Could not place the new app. The prior app was restored when available.\n' >&2
    exit 1
fi
printf 'Built: %s\n' "$APP_PATH"
printf 'Local ad-hoc signature only; this is not an App Store or notarized distribution.\n'
if [[ -n "$PREVIOUS_APP" ]]; then printf 'Previous build preserved: %s\n' "$PREVIOUS_APP"; fi
