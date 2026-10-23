#!/bin/zsh
# Builds Elxplorer.app (Apple Silicon + Intel) with the Command Line Tools; no Xcode needed.
set -euo pipefail
cd "$(dirname "$0")"
VERSION=1.0.4
APP=build/Elxplorer.app
rm -rf "$APP" build/Elxplorer.iconset
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for arch in arm64 x86_64; do
    swiftc -parse-as-library -swift-version 5 -O -target $arch-apple-macos14 Sources/*.swift -o build/Elxplorer-$arch
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
    <key>CFBundleVersion</key><string>1</string>
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

codesign --force --sign - "$APP"
echo "Built $APP"
