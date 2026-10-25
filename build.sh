#!/bin/zsh
# Builds Elxplorer.app (Apple Silicon + Intel) with the Command Line Tools; no Xcode needed.
#   ./build.sh               for downloads
#   ./build.sh appstore      for the Mac App Store (sandboxed, no update check)
#   ./build.sh sandbox-test  the App Store build signed ad hoc, to try the sandbox here
set -euo pipefail
MODE=${1:-direct}
BUILD=${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}   # must grow with every App Store upload
FLAGS=()
[[ $MODE != direct ]] && FLAGS=(-D APPSTORE)
cd "$(dirname "$0")"
VERSION=1.0.4
APP=build/Elxplorer.app
rm -rf "$APP" build/Elxplorer.iconset
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for arch in arm64 x86_64; do
    swiftc -parse-as-library -swift-version 5 -O -target $arch-apple-macos14 "${FLAGS[@]}" Sources/*.swift -o build/Elxplorer-$arch
done
lipo -create build/Elxplorer-arm64 build/Elxplorer-x86_64 -output "$APP/Contents/MacOS/Elxplorer"
rm build/Elxplorer-arm64 build/Elxplorer-x86_64

swift Icon.swift build/Elxplorer.iconset
iconutil -c icns build/Elxplorer.iconset -o "$APP/Contents/Resources/Elxplorer.icns"
rm -rf build/Elxplorer.iconset

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Elxplorer</string>
    <key>CFBundleDisplayName</key><string>Elxplorer</string>
    <key>CFBundleIdentifier</key><string>com.itzkin.elxplorer</string>
    <key>CFBundleExecutable</key><string>Elxplorer</string>
    <key>CFBundleIconFile</key><string>Elxplorer</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>ITSAppUsesNonExemptEncryption</key><false/>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Elad Itzkin</string>
    <key>NSAppleEventsUsageDescription</key><string>Elxplorer asks Finder to show items when you choose “Show in Finder”.</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Folder</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Default</string>
            <key>LSItemContentTypes</key><array><string>public.folder</string><string>public.directory</string><string>public.volume</string></array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key><string>Any item (reveal in its folder)</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key><array><string>public.item</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

./sign.sh "$APP" "$MODE"
echo "Built $APP ($MODE)"
