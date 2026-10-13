#!/bin/sh
# Install ChargeCap's privileged helper. Runs as root (ChargeCap uses the macOS admin prompt).
# Usage: install-helper.sh <ChargeCap.app/Contents/Resources>
set -eu
RES="$1"
LABEL=dev.abenbjohn.chargecap.helper
HELPER=/Library/PrivilegedHelperTools/$LABEL
PLIST=/Library/LaunchDaemons/$LABEL.plist

# Refuse to install a helper that isn't signed by our team.
/usr/bin/codesign --verify --strict \
  -R="anchor apple generic and identifier \"$LABEL\" and certificate leaf[subject.OU] = \"ZPJ7XARQ4A\"" \
  "$RES/chargecap-helper"

/bin/launchctl bootout "system/$LABEL" 2>/dev/null || true
/bin/mkdir -p /Library/PrivilegedHelperTools
/usr/bin/install -m 755 -o root -g wheel "$RES/chargecap-helper" "$HELPER"
/usr/bin/install -m 644 -o root -g wheel "$RES/$LABEL.plist" "$PLIST"
/bin/launchctl bootstrap system "$PLIST"
