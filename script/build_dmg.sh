#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Companion"
LEGACY_APP_NAME="CompanionV2"
DISPLAY_NAME="Companion"
PRODUCT_NAME="Companion"
BUNDLE_ID="com.santiagoalonso.companion"
SIGN_IDENTITY="Developer ID Application: Santiago Alonso Alexandre (QAMM2A6WRQ)"
SWIFT_BUILD_FLAGS=(-c release --arch arm64 --arch x86_64)
NOTARY_PROFILE="${NOTARY_PROFILE:-notarytool}"
SHOULD_NOTARIZE=false

for arg in "$@"; do
  case "$arg" in
    --notarize|notarize)
      SHOULD_NOTARIZE=true
      ;;
    --help|-h)
      echo "usage: $0 [--notarize]" >&2
      exit 0
      ;;
    *)
      echo "unknown argument: $arg" >&2
      echo "usage: $0 [--notarize]" >&2
      exit 2
      ;;
  esac
done

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGE_DIR="$ROOT_DIR/Companion"
DIST_DIR="$ROOT_DIR/dist"
RELEASE_DIR="$PACKAGE_DIR/.release"
STAGING_DIR="$RELEASE_DIR/dmg-staging-companion"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
INSTALLED_APP_BUNDLE="/Applications/$APP_NAME.app"
LEGACY_INSTALLED_APP_BUNDLE="/Applications/$LEGACY_APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
APP_BINARY="$MACOS_DIR/$APP_NAME"
INFO_PLIST="$PACKAGE_DIR/Sources/Companion/Resources/Info.plist"
ICON_FILE="$PACKAGE_DIR/Sources/Companion/Resources/AppIcon.icns"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
BUILD_BINARY=""
DMG_NAME="$APP_NAME-$VERSION.dmg"
REPO_DMG="$RELEASE_DIR/$DMG_NAME"
DESKTOP_DMG="$HOME/Desktop/$DMG_NAME"
APP_NOTARY_ZIP="$RELEASE_DIR/$APP_NAME-$VERSION-notary.zip"

has_signing_identity() {
  security find-identity -v -p codesigning | grep -Fq "$SIGN_IDENTITY"
}

require_signing_identity() {
  if ! has_signing_identity; then
    echo "error: signing identity not found: $SIGN_IDENTITY" >&2
    exit 1
  fi
}

sign_app() {
  if has_signing_identity; then
    codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_BUNDLE"
  else
    echo "warning: signing identity not found; app will not be Developer ID signed" >&2
  fi
}

sign_dmg() {
  if has_signing_identity; then
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$REPO_DMG"
  else
    echo "warning: signing identity not found; dmg will not be Developer ID signed" >&2
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
  codesign --verify --deep --strict --verbose=2 "$INSTALLED_APP_BUNDLE" >/dev/null
}

build_app() {
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

  sign_app
}

notarize_app() {
  require_signing_identity
  rm -f "$APP_NOTARY_ZIP"
  ditto -c -k --keepParent "$APP_BUNDLE" "$APP_NOTARY_ZIP"
  xcrun notarytool submit "$APP_NOTARY_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP_BUNDLE"
  xcrun stapler validate "$APP_BUNDLE"
}

stage_dmg_contents() {
  rm -rf "$STAGING_DIR"
  mkdir -p "$STAGING_DIR"
  cp -R "$APP_BUNDLE" "$STAGING_DIR/$APP_NAME.app"
  ln -s /Applications "$STAGING_DIR/Applications"
  cp "$ROOT_DIR/LICENSE" "$STAGING_DIR/LICENSE"
  cat > "$STAGING_DIR/README.txt" <<EOF
$DISPLAY_NAME $VERSION

Install:
1. Drag $APP_NAME.app to Applications.
2. Open $DISPLAY_NAME from Applications.
3. Grant Accessibility and Input Monitoring when macOS asks.
4. Open Settings and add a provider key, or configure LM Studio for local models.

This build uses bundle ID $BUNDLE_ID and replaces older Companion or CompanionV2 installs.
EOF
}

create_dmg() {
  mkdir -p "$RELEASE_DIR"
  rm -f "$REPO_DMG" "$DESKTOP_DMG"

  hdiutil create \
    -volname "$DISPLAY_NAME $VERSION" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$REPO_DMG"

  sign_dmg
}

notarize_dmg() {
  require_signing_identity
  xcrun notarytool submit "$REPO_DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$REPO_DMG"
  xcrun stapler validate "$REPO_DMG"
}

publish_dmg() {
  cp "$REPO_DMG" "$DESKTOP_DMG"
}

verify_artifacts() {
  codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
  codesign --verify --verbose=2 "$REPO_DMG"
  hdiutil verify "$REPO_DMG"
  hdiutil verify "$DESKTOP_DMG"
  if [[ "$SHOULD_NOTARIZE" == true ]]; then
    xcrun stapler validate "$APP_BUNDLE"
    xcrun stapler validate "$REPO_DMG"
  fi
  spctl --assess --type exec --verbose=4 "$APP_BUNDLE" || true
  spctl --assess --type open --context context:primary-signature --verbose=4 "$REPO_DMG" || true
}

build_app
if [[ "$SHOULD_NOTARIZE" == true ]]; then
  notarize_app
fi
replace_installed_app
stage_dmg_contents
create_dmg
if [[ "$SHOULD_NOTARIZE" == true ]]; then
  notarize_dmg
fi
publish_dmg
verify_artifacts

echo "Created:"
echo "  $REPO_DMG"
echo "  $DESKTOP_DMG"
echo "Installed:"
echo "  $INSTALLED_APP_BUNDLE"
