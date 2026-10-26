#!/bin/zsh
# Builds "build/MCP Doctor.app". Works with Xcode or with only the Command Line Tools.
#   scripts/build-app.sh            release build, ad-hoc signed
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh
set -euo pipefail
cd "${0:A:h}/.."

swift build -c release --arch arm64
bin_dir=$(swift build -c release --arch arm64 --show-bin-path)
app="build/MCP Doctor.app"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/MCPDoctor" "$app/Contents/MacOS/MCPDoctor"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
codesign --force --options runtime --sign "${SIGN_IDENTITY:--}" "$app"

echo "Built $app"
