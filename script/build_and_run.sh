#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Companion"
LEGACY_APP_NAME="CompanionV2"
PRODUCT_NAME="Companion"
BUNDLE_ID="com.santiagoalonso.companion"
SIGN_IDENTITY="Developer ID Application: Santiago Alonso Alexandre (QAMM2A6WRQ)"
SWIFT_BUILD_FLAGS=(-c release --arch arm64 --arch x86_64)

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="$ROOT_DIR/Companion"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
INSTALLED_APP_BUNDLE="/Applications/$APP_NAME.app"
LEGACY_INSTALLED_APP_BUNDLE="/Applications/$LEGACY_APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
APP_BINARY="$MACOS_DIR/$APP_NAME"
INSTALLED_APP_BINARY="$INSTALLED_APP_BUNDLE/Contents/MacOS/$APP_NAME"
INFO_PLIST="$PACKAGE_DIR/Sources/Companion/Resources/Info.plist"
ICON_FILE="$PACKAGE_DIR/Sources/Companion/Resources/AppIcon.icns"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
pkill -x "$LEGACY_APP_NAME" >/dev/null 2>&1 || true

cd "$PACKAGE_DIR"
swift build "${SWIFT_BUILD_FLAGS[@]}"
BUILD_BINARY="$(swift build "${SWIFT_BUILD_FLAGS[@]}" --show-bin-path)/$PRODUCT_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
cp "$INFO_PLIST" "$CONTENTS_DIR/Info.plist"
if [[ -f "$ICON_FILE" ]]; then
  cp "$ICON_FILE" "$RESOURCES_DIR/AppIcon.icns"
fi

sign_app() {
  if security find-identity -v -p codesigning | grep -Fq "$SIGN_IDENTITY"; then
    codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
  fi
}

replace_installed_app() {
  if [[ -d "$LEGACY_INSTALLED_APP_BUNDLE" ]]; then
    if [[ -x /usr/bin/trash ]]; then
      /usr/bin/trash "$LEGACY_INSTALLED_APP_BUNDLE"
    else
      /usr/bin/osascript -e "tell application \"Finder\" to delete POSIX file \"$LEGACY_INSTALLED_APP_BUNDLE\"" >/dev/null
    fi
  fi
  if [[ -d "$INSTALLED_APP_BUNDLE" ]]; then
    if [[ -x /usr/bin/trash ]]; then
      /usr/bin/trash "$INSTALLED_APP_BUNDLE"
    else
      /usr/bin/osascript -e "tell application \"Finder\" to delete POSIX file \"$INSTALLED_APP_BUNDLE\"" >/dev/null
    fi
  fi
  /usr/bin/ditto "$APP_BUNDLE" "$INSTALLED_APP_BUNDLE"
  /usr/bin/xattr -dr com.apple.quarantine "$INSTALLED_APP_BUNDLE" >/dev/null 2>&1 || true
}

install_app() {
  sign_app
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  pkill -x "$LEGACY_APP_NAME" >/dev/null 2>&1 || true
  replace_installed_app
  codesign --verify --deep --strict --verbose=2 "$INSTALLED_APP_BUNDLE" >/dev/null
}

open_app() {
  install_app
  /usr/bin/open -n "$INSTALLED_APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --install|install)
    install_app
    /usr/bin/open -n "$INSTALLED_APP_BUNDLE"
    ;;
  --debug|debug)
    install_app
    lldb -- "$INSTALLED_APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    echo "$APP_NAME is running from $INSTALLED_APP_BUNDLE"
    ;;
  *)
    echo "usage: $0 [run|--install|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
