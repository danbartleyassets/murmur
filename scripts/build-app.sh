#!/bin/bash
# Builds Murmur.app into build/. Add --install to copy it to /Applications and relaunch.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Murmur"
BUNDLE_ID="com.danbartley.murmur"
VERSION="1.0"
BUILD="$(date +%Y%m%d%H%M)"
SIGN_NAME="Murmur Local Signing"

echo "==> Building release binary"
swift build -c release --product Murmur

BIN=".build/release"
APP="build/${APP_NAME}.app"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources/Fonts"

cp "${BIN}/Murmur" "${APP}/Contents/MacOS/${APP_NAME}"
cp assets/AppIcon.icns "${APP}/Contents/Resources/AppIcon.icns"
cp assets/fonts/GoogleSansFlex.ttf assets/fonts/OFL.txt "${APP}/Contents/Resources/Fonts/"

# SwiftPM resource bundles from dependencies, if any, go in Resources.
for b in "${BIN}"/*.bundle; do
  [ -e "$b" ] || continue
  cp -R "$b" "${APP}/Contents/Resources/"
done

cat > "${APP}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>${APP_NAME}</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD}</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSUIElement</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>Murmur turns your speech into text, on this Mac.</string>
    <key>NSHumanReadableCopyright</key><string>Google Sans Flex © The Google Sans Flex Authors, SIL Open Font License 1.1.</string>
</dict>
</plist>
PLIST

# A stable signing identity keeps macOS permissions across rebuilds; without
# one, ad-hoc signing works but Accessibility must be re-granted after updates.
if security find-identity -p codesigning 2>/dev/null | grep -q "${SIGN_NAME}"; then
  ID="${SIGN_NAME}"
else
  ID="-"
fi
echo "==> Signing (${ID})"
codesign --force --deep --sign "${ID}" --identifier "${BUNDLE_ID}" "${APP}"
codesign --verify --deep "${APP}" && echo "   signature OK"

echo "==> Built ${APP}"

if [ "${1:-}" = "--install" ]; then
  echo "==> Installing to /Applications"
  pkill -x "${APP_NAME}" 2>/dev/null || true
  sleep 0.5
  rm -rf "/Applications/${APP_NAME}.app"
  cp -R "${APP}" "/Applications/${APP_NAME}.app"
  open "/Applications/${APP_NAME}.app"
  echo "   launched"
fi
