#!/bin/zsh
# Signs a built app for where it's going (the same script in each of the apps):
#   direct        downloads from GitHub: Developer ID with the hardened runtime, so it can be notarized.
#                 Without that certificate, the private one from make-signing-identity.sh, else ad hoc.
#   appstore      Mac App Store: Apple Distribution, the sandbox, and the app's provisioning profile, from
#                 ~/Library/Application Support/Itzkin Signing/profiles/<App>.provisionprofile (or $PROFILE).
#   sandbox-test  the App Store's sandbox rules, signed ad hoc, to try the sandbox on this Mac.
# Entitlements: AppStore.entitlements (sandbox), and Direct.entitlements (hardened-runtime extras) if present.
# Programs in Contents/Helpers (Elconvo's ffmpeg and cwebp) are signed first; in the App Store build they
# inherit the app's sandbox, as Apple requires of helper tools.
set -euo pipefail
APP=$1
MODE=${2:-direct}
HERE=$(cd "$(dirname "$0")" && pwd)
NAME=$(basename "$APP" .app)
SIGNING="$HOME/Library/Application Support/Itzkin Signing"

identity() { security find-identity -v -p codesigning | grep -o "\"$1[^\"]*\"" | head -1 | tr -d '"' || true }

helpers() {   # codesign arguments for each helper
    [[ -d "$APP/Contents/Helpers" ]] || return 0
    for tool in "$APP"/Contents/Helpers/*(N); do codesign --force "$@" "$tool"; done
}
INHERIT=$(mktemp)
cat > "$INHERIT" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>com.apple.security.app-sandbox</key><true/>
    <key>com.apple.security.inherit</key><true/>
</dict></plist>
PLIST

case $MODE in
appstore)
    PROFILE=${PROFILE:-"$SIGNING/profiles/$NAME.provisionprofile"}
    [[ -f $PROFILE ]] || { echo "No App Store profile at $PROFILE"; exit 1 }
    ID=$(identity "Apple Distribution"); [[ -n $ID ]] || ID=$(identity "3rd Party Mac Developer Application")
    [[ -n $ID ]] || { echo "No Apple Distribution certificate in the keychain"; exit 1 }
    cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
    # Files carry extended attributes (like "downloaded from the internet" on the profile); the App Store
    # refuses packages that contain any, so strip them all before signing.
    xattr -cr "$APP"
    helpers --options runtime --entitlements "$INHERIT" --sign "$ID"
    # The profile's app and team identifiers, plus the sandbox entitlements.
    WORK=$(mktemp -d)
    security cms -D -i "$PROFILE" > "$WORK/profile.plist"
    /usr/libexec/PlistBuddy -x -c "Print :Entitlements" "$WORK/profile.plist" > "$WORK/entitlements.plist"
    /usr/libexec/PlistBuddy -c "Merge $HERE/AppStore.entitlements" "$WORK/entitlements.plist" >/dev/null
    codesign --force --options runtime --entitlements "$WORK/entitlements.plist" --sign "$ID" "$APP"
    rm -rf "$WORK"
    ;;
sandbox-test)
    helpers --entitlements "$INHERIT" --sign -
    codesign --force --entitlements "$HERE/AppStore.entitlements" --sign - "$APP"
    ;;
*)
    EXTRA=()
    [[ -f "$HERE/Direct.entitlements" ]] && EXTRA=(--entitlements "$HERE/Direct.entitlements")
    ID=$(identity "Developer ID Application")
    if [[ -n $ID ]]; then
        helpers --options runtime --timestamp --sign "$ID"
        codesign --force --options runtime --timestamp "${EXTRA[@]}" --sign "$ID" "$APP"
    elif [[ -f "$SIGNING/identity" ]]; then
        KEYCHAIN=$(ls "$SIGNING"/signing.keychain* | head -1)
        security unlock-keychain -p "$(cat "$SIGNING/password")" "$KEYCHAIN"
        helpers --keychain "$KEYCHAIN" --sign "$(cat "$SIGNING/identity")"
        codesign --force --keychain "$KEYCHAIN" "${EXTRA[@]}" --sign "$(cat "$SIGNING/identity")" "$APP"
    else
        helpers --sign -
        codesign --force --sign - "$APP"
    fi
    ;;
esac
rm -f "$INHERIT"
