#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
minimum_os="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
work="$(mktemp -d "${TMPDIR:-/tmp}/chekku.XXXXXX")"
trap 'rm -rf "$work"' EXIT

for arch in arm64 x86_64; do
    xcrun swiftc -sdk "$sdk" -target "${arch}-apple-macos${minimum_os}" \
        -swift-version 6 -strict-concurrency=complete -parse-as-library -O \
        -module-name Chekku -module-cache-path "$work/ModuleCache" \
        -file-prefix-map "$PWD=." -debug-prefix-map "$PWD=." \
        ./*.swift -framework SwiftUI -framework AppKit -framework Security \
        -o "$work/$arch"
done

app="$work/Chekku.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
xcrun lipo -create "$work/arm64" "$work/x86_64" -output "$app/Contents/MacOS/Chekku"
cp Info.plist "$app/Contents/Info.plist"
cp AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp Credits.rtf "$app/Contents/Resources/Credits.rtf"
xattr -cr "$app"
codesign --force --sign - --identifier com.chekku.app \
    --options runtime --entitlements Chekku.entitlements "$app"
codesign --verify --strict "$app"
for arch in arm64 x86_64; do
    xcrun lipo "$app/Contents/MacOS/Chekku" -verify_arch "$arch"
done

rm -rf Chekku.app
mv "$app" Chekku.app
echo "Built Chekku.app"
