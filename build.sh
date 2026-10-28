#!/bin/zsh
# Builds BatteryWatch.app and installs it to ~/Applications.
set -e
cd "$(dirname "$0")"
APP=build/BatteryWatch.app
rm -rf build && mkdir -p $APP/Contents/MacOS
swiftc -O -swift-version 5 -target arm64-apple-macos13 Sources/*.swift -o $APP/Contents/MacOS/BatteryWatch
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>BatteryWatch</string>
  <key>CFBundleIdentifier</key><string>com.local.batterywatch</string>
  <key>CFBundleExecutable</key><string>BatteryWatch</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
codesign --force --sign - $APP
mkdir -p ~/Applications
pkill -x BatteryWatch || true
rm -rf ~/Applications/BatteryWatch.app && cp -R $APP ~/Applications/
echo "Installed to ~/Applications/BatteryWatch.app"
