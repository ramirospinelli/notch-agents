#!/bin/zsh
set -euo pipefail

root=${0:A:h:h}
app="$root/dist/NotchAgents.app"

cd "$root"
rm -rf .build
swift build -c release
mkdir -p "$app/Contents/MacOS"
cp .build/release/NotchAgents "$app/Contents/MacOS/NotchAgents"
cp App/Info.plist "$app/Contents/Info.plist"
codesign --force --deep --sign - "$app"

echo "Built $app"
