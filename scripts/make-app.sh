#!/usr/bin/env bash
# Builds tblink and wraps it in tblink.app so Input Monitoring permission
# is granted to tblink itself instead of to your terminal.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

APP=tblink.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/tblink "$APP/Contents/MacOS/tblink"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>tblink</string>
    <key>CFBundleIdentifier</key><string>com.diegocabello.tblink</string>
    <key>CFBundleName</key><string>tblink</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>LSMinimumSystemVersion</key><string>12.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP. Run it with: open $APP"
