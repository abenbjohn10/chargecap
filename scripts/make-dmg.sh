#!/bin/sh
# Package build/ChargeCap.app into a drag-to-Applications DMG.
#
# Optional notarization (needs a "Developer ID Application" certificate and a notarytool profile):
#   IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=chargecap ./scripts/make-dmg.sh
# Without them the DMG works on Macs where the signing certificate is trusted (your own Mac),
# but Gatekeeper blocks it on others.
set -eu
cd "$(dirname "$0")/.."

./scripts/bundle.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" build/ChargeCap.app/Contents/Info.plist)
DMG="build/ChargeCap-$VERSION.dmg"  # also upload as ChargeCap.dmg so releases/latest/download/ChargeCap.dmg stays valid
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

cp -R build/ChargeCap.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "ChargeCap $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
codesign --force --sign "${IDENTITY:-Apple Development: abenbjohn10@gmail.com (FG24BQFK5G)}" "$DMG"

if [ -n "${NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
fi

echo "Built $DMG"
