#!/bin/zsh
# Signs a built app for where it's going (the same script in each of the apps):
#   direct        downloads from GitHub: Developer ID with the hardened runtime, so it can be notarized.
#                 Without that certificate, the private one from make-signing-identity.sh, else ad hoc.
#   appstore      Mac App Store: Apple Distribution, the sandbox, and the app's provisioning profile, from
#                 ~/Library/Application Support/Itzkin Signing/profiles/<App>.provisionprofile (or $PROFILE).
#   sandbox-test  the App Store's sandbox rules, signed ad hoc, to try the sandbox on this Mac.
# Entitlements: AppStore.entitlements (sandbox), and Direct.entitlements (hardened-runtime extras) if present.
set -euo pipefail
APP=$1
MODE=${2:-direct}
HERE=$(cd "$(dirname "$0")" && pwd)
NAME=$(basename "$APP" .app)
SIGNING="$HOME/Library/Application Support/Itzkin Signing"

identity() { security find-identity -v -p codesigning | grep -o "\"$1[^\"]*\"" | head -1 | tr -d '"' || true }

case $MODE in
appstore)
    PROFILE=${PROFILE:-"$SIGNING/profiles/$NAME.provisionprofile"}
    [[ -f $PROFILE ]] || { echo "No App Store profile at $PROFILE"; exit 1 }
    ID=$(identity "Apple Distribution"); [[ -n $ID ]] || ID=$(identity "3rd Party Mac Developer Application")
    [[ -n $ID ]] || { echo "No Apple Distribution certificate in the keychain"; exit 1 }
    cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
    # The profile's app and team identifiers, plus the sandbox entitlements.
    WORK=$(mktemp -d)
    security cms -D -i "$PROFILE" > "$WORK/profile.plist"
    /usr/libexec/PlistBuddy -x -c "Print :Entitlements" "$WORK/profile.plist" > "$WORK/entitlements.plist"
    /usr/libexec/PlistBuddy -c "Merge $HERE/AppStore.entitlements" "$WORK/entitlements.plist" >/dev/null
    codesign --force --options runtime --entitlements "$WORK/entitlements.plist" --sign "$ID" "$APP"
    rm -rf "$WORK"
    ;;
sandbox-test)
    codesign --force --entitlements "$HERE/AppStore.entitlements" --sign - "$APP"
    ;;
*)
    EXTRA=()
    [[ -f "$HERE/Direct.entitlements" ]] && EXTRA=(--entitlements "$HERE/Direct.entitlements")
    ID=$(identity "Developer ID Application")
    if [[ -n $ID ]]; then
        codesign --force --options runtime --timestamp "${EXTRA[@]}" --sign "$ID" "$APP"
    elif [[ -f "$SIGNING/identity" ]]; then
        KEYCHAIN=$(ls "$SIGNING"/signing.keychain* | head -1)
        security unlock-keychain -p "$(cat "$SIGNING/password")" "$KEYCHAIN"
        codesign --force --keychain "$KEYCHAIN" "${EXTRA[@]}" --sign "$(cat "$SIGNING/identity")" "$APP"
    else
        codesign --force --sign - "$APP"
    fi
    ;;
esac
