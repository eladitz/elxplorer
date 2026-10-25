#!/bin/zsh
# Packages Elxplorer:
#   ./package.sh            build/Elxplorer.dmg for downloads. With a Developer ID certificate in the keychain it's
#                           signed and notarized (no "Open Anyway"), using the notarytool profile "notary",
#                           made once with: xcrun notarytool store-credentials notary --apple-id <you>
#   ./package.sh appstore   build/Elxplorer.pkg for the Mac App Store, signed with Mac Installer Distribution.
set -euo pipefail
cd "$(dirname "$0")"
MODE=${1:-direct}
APP=build/Elxplorer.app
identity() { security find-identity -v $1 | grep -o "\"$2[^\"]*\"" | head -1 | tr -d '"' || true }

if [[ $MODE == appstore ]]; then
    ./build.sh appstore
    INSTALLER=$(identity "" "3rd Party Mac Developer Installer"); [[ -n $INSTALLER ]] || INSTALLER=$(identity "" "Mac Installer Distribution")
    [[ -n $INSTALLER ]] || { echo "No Mac Installer Distribution certificate in the keychain"; exit 1 }
    productbuild --component "$APP" /Applications --sign "$INSTALLER" build/Elxplorer.pkg
    echo "Packaged build/Elxplorer.pkg for App Store Connect"
    exit 0
fi

./build.sh
DMG=build/Elxplorer.dmg   # unversioned, so "releases/latest/download/Elxplorer.dmg" always works
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Elxplorer" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

DEVELOPER_ID=$(identity "-p codesigning" "Developer ID Application")
if [[ -n $DEVELOPER_ID ]]; then
    codesign --sign "$DEVELOPER_ID" --timestamp "$DMG"
    xcrun notarytool submit "$DMG" --keychain-profile "${NOTARY_PROFILE:-notary}" --wait
    xcrun stapler staple "$DMG"
fi
echo "Packaged $DMG ($(du -h "$DMG" | cut -f1))${DEVELOPER_ID:+, notarized}"
