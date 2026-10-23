#!/bin/zsh
# Builds Elxplorer and wraps it in a drag-to-Applications DMG for download.
#
# Without an Apple Developer ID the app is ad-hoc signed: it works, but first-time users must
# allow it in System Settings → Privacy & Security → "Open Anyway". With a Developer ID ($99/yr)
# set these and the DMG is signed and notarized, so it opens with no warning:
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)"
#   NOTARY_PROFILE=elxplorer   # made once with: xcrun notarytool store-credentials elxplorer
set -euo pipefail
cd "$(dirname "$0")"
./build.sh

APP=build/Elxplorer.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG=build/Elxplorer.dmg   # unversioned, so "releases/latest/download/Elxplorer.dmg" always works

if [[ -n "${DEVELOPER_ID:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP"
fi

STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Elxplorer" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

if [[ -n "${DEVELOPER_ID:-}" ]]; then
    codesign --sign "$DEVELOPER_ID" --timestamp "$DMG"
    xcrun notarytool submit "$DMG" --keychain-profile "${NOTARY_PROFILE:?set NOTARY_PROFILE}" --wait
    xcrun stapler staple "$DMG"
fi
echo "Packaged $DMG ($(du -h "$DMG" | cut -f1))"
