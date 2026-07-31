#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP_DIR="$ROOT_DIR/dist/CodexCredit.app"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/CodexCredit" "$APP_DIR/Contents/MacOS/CodexCredit"
cp "$ROOT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"

codesign --force --deep --sign - "$APP_DIR" >/dev/null
printf 'Built %s\n' "$APP_DIR"
