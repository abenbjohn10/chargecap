#!/bin/sh
# Build ChargeCap.app (app + privileged helper), signed with the Apple Development identity.
set -eu
cd "$(dirname "$0")/.."
IDENTITY="${IDENTITY:-Apple Development: abenbjohn10@gmail.com (FG24BQFK5G)}"

swift build -c release
APP=build/ChargeCap.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/ChargeCap "$APP/Contents/MacOS/ChargeCap"
cp .build/release/chargecap-helper "$APP/Contents/Resources/chargecap-helper"
# App icon: rendered from AppIconView, then packed with iconutil.
ICONSET=$(mktemp -d)/AppIcon.iconset
.build/release/ChargeCap --render-icon "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cp Resources/install-helper.sh Resources/uninstall-helper.sh Resources/dev.abenbjohn.chargecap.helper.plist "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>ChargeCap</string>
  <key>CFBundleIdentifier</key><string>dev.abenbjohn.chargecap</string>
  <key>CFBundleName</key><string>ChargeCap</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2.0</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSBluetoothAlwaysUsageDescription</key>
  <string>ChargeCap shows the battery level of your connected Bluetooth accessories.</string>
</dict>
</plist>
PLIST

codesign --force --options runtime --identifier dev.abenbjohn.chargecap.helper --sign "$IDENTITY" "$APP/Contents/Resources/chargecap-helper"
codesign --force --options runtime --identifier dev.abenbjohn.chargecap --sign "$IDENTITY" "$APP"
codesign --verify --strict --deep "$APP"
echo "Built $APP"
