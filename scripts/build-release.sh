#!/usr/bin/env bash
#
# Build, sign, and package DNP Remote Mac for a single architecture.
# Produces a notarization-ready DMG at build/DNPRemoteMac-<version>-<arch>.dmg.
#
# Designed to run both locally (when the maintainer wants to cut a build
# manually) and in GitHub Actions. Required certificates / Sparkle keys
# are passed in via flags so the script stays generic — secrets never
# touch this file.
#
# Usage:
#   scripts/build-release.sh \
#       --arch arm64 \
#       --version 0.2.0 \
#       --sign-identity "Developer ID Application: Foo (TEAMID)" \
#       --sparkle-public-key "BASE64==" \
#       --sparkle-feed-url "https://github.com/rotem221/DNPRemoteIDE/releases/latest/download/appcast-arm64.xml"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MAC_PROJECT_DIR="$PROJECT_ROOT/apps/DNPRemoteMac"

ARCH=""
VERSION=""
SIGN_IDENTITY=""
SPARKLE_PUBLIC_KEY=""
SPARKLE_FEED_URL=""
# Apple Developer team id that issued the Developer ID Application
# certificate. Has to be passed in explicitly because the project no
# longer carries a team identifier in source — contributors put their
# own team in a gitignored `Local.xcconfig`, and CI passes its team
# in via this flag (sourced from the `APPLE_TEAM_ID` repo secret).
DEVELOPMENT_TEAM=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch) ARCH="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --sign-identity) SIGN_IDENTITY="$2"; shift 2 ;;
    --development-team) DEVELOPMENT_TEAM="$2"; shift 2 ;;
    --sparkle-public-key) SPARKLE_PUBLIC_KEY="$2"; shift 2 ;;
    --sparkle-feed-url) SPARKLE_FEED_URL="$2"; shift 2 ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

for required in ARCH VERSION SIGN_IDENTITY DEVELOPMENT_TEAM SPARKLE_PUBLIC_KEY SPARKLE_FEED_URL; do
  if [[ -z "${!required}" ]]; then
    echo "Missing required flag: --${required,,}" >&2
    exit 1
  fi
done

echo "==> Generating Xcode project via XcodeGen"
(cd "$MAC_PROJECT_DIR" && xcodegen generate)

# Sparkle's public key + feed URL are baked into Info.plist at build
# time so the released app can verify update signatures and knows which
# appcast to poll without us having to ship a hardcoded value in source
# control. We pipe both into xcodebuild via build settings — XcodeGen
# already wired the matching `$(SPARKLE_PUBLIC_KEY)` / `$(SUFeedURL)`
# placeholders into project.yml.
DERIVED="$PROJECT_ROOT/build/DerivedData-${ARCH}"
EXPORT_DIR="$PROJECT_ROOT/build"
mkdir -p "$EXPORT_DIR"
ARCHIVE_PATH="$EXPORT_DIR/DNPRemoteMac-${ARCH}.xcarchive"

echo "==> Archiving DNPRemoteMac (${ARCH})"
# `-skipPackagePluginValidation` and `-skipMacroValidation` bypass the
# interactive "trust this build plug-in / macro?" prompt Xcode 15+ adds
# to package-supplied build tool plug-ins (CodeEditSourceEditor pulls in
# SwiftLintPlugin) and macros. The prompt is impossible to answer on CI,
# so without these flags the archive fails immediately at "Validate
# plug-in" with an exit code 65.
xcodebuild \
  -project "$MAC_PROJECT_DIR/DNPRemoteMac.xcodeproj" \
  -scheme DNPRemoteMac \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  -derivedDataPath "$DERIVED" \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  ARCHS="$ARCH" \
  ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$VERSION" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  SPARKLE_PUBLIC_KEY="$SPARKLE_PUBLIC_KEY" \
  SPARKLE_FEED_URL="$SPARKLE_FEED_URL" \
  archive

echo "==> Exporting archive"
EXPORT_OPTIONS_PLIST="$(mktemp -t exportOptions).plist"
cat > "$EXPORT_OPTIONS_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>${SIGN_IDENTITY}</string>
  <key>destination</key><string>export</string>
</dict>
</plist>
EOF

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR/export-${ARCH}" \
  -exportOptionsPlist "$EXPORT_OPTIONS_PLIST"

APP_PATH="$EXPORT_DIR/export-${ARCH}/DNP Remote Mac.app"
if [[ ! -d "$APP_PATH" ]]; then
  # XcodeGen renamed `CFBundleDisplayName` to "DNP Remote Mac" but the
  # archive output sometimes uses the target name verbatim. Try the
  # alternate path before giving up.
  APP_PATH="$EXPORT_DIR/export-${ARCH}/DNPRemoteMac.app"
fi
if [[ ! -d "$APP_PATH" ]]; then
  echo "ERROR: could not find exported .app under $EXPORT_DIR/export-${ARCH}" >&2
  exit 1
fi

echo "==> Building DMG"
DMG_PATH="$EXPORT_DIR/DNPRemoteMac-${VERSION}-${ARCH}.dmg"
rm -f "$DMG_PATH"
# `create-dmg` is the same tool muxy uses; we install it via npm in CI.
# Fall back to hdiutil if the user doesn't have create-dmg installed.
if command -v create-dmg >/dev/null 2>&1; then
  (cd "$EXPORT_DIR" && create-dmg "$APP_PATH" --overwrite || true)
  # create-dmg's filename includes the marketing version; rename to our
  # canonical scheme so the appcast script can find it.
  CREATED=$(ls "$EXPORT_DIR"/*.dmg 2>/dev/null | grep -v "DNPRemoteMac-${VERSION}-${ARCH}.dmg" | head -1 || true)
  if [[ -n "$CREATED" ]]; then
    mv "$CREATED" "$DMG_PATH"
  fi
else
  hdiutil create -volname "DNP Remote Mac" -srcfolder "$APP_PATH" -ov -format UDZO "$DMG_PATH"
fi

echo "==> Built $DMG_PATH"
