#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP_DIR="$ROOT_DIR/dist/Codex Credit Bar.app"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/CodexMenuBarCredit" "$APP_DIR/Contents/MacOS/CodexMenuBarCredit"
cp "$ROOT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"

ICONSET_ROOT="$(mktemp -d)"
ICONSET_DIR="$ICONSET_ROOT/CodexMenuBarCredit.iconset"
mkdir "$ICONSET_DIR"
trap 'rm -rf "$ICONSET_ROOT"' EXIT
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ROOT_DIR/Assets/CodexMenuBarCreditLogo.png" \
        --out "$ICONSET_DIR/icon_${size}x${size}.png" >/dev/null
    double_size=$((size * 2))
    sips -z "$double_size" "$double_size" "$ROOT_DIR/Assets/CodexMenuBarCreditLogo.png" \
        --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil --convert icns \
    --output "$APP_DIR/Contents/Resources/Codex Credit Bar.icns" "$ICONSET_DIR"
if [[ -n "${APP_REVISION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleSourceRevision $APP_REVISION" \
        "$APP_DIR/Contents/Info.plist"
fi

codesign --force --deep --sign - "$APP_DIR" >/dev/null
printf 'Built %s\n' "$APP_DIR"
