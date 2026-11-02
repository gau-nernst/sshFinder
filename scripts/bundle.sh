#!/bin/sh
# Build build/sshFinder.app. Needs only the Xcode Command Line Tools.
set -eu
cd "$(dirname "$0")/.."

swift build -c release
APP=build/sshFinder.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/sshFinder "$APP/Contents/MacOS/sshFinder"
swift scripts/make-icon.swift "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>io.github.gau-nernst.sshFinder</string>
  <key>CFBundleName</key><string>sshFinder</string>
  <key>CFBundleExecutable</key><string>sshFinder</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>sshFinder opens iTerm2 or Terminal with ssh to the host and folder you are viewing.</string>
</dict>
</plist>
EOF
codesign --force --sign - "$APP"
echo "Built $APP"
