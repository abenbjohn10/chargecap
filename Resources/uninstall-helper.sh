#!/bin/sh
# Remove ChargeCap's helper. On SIGTERM the helper turns the adapter back on and clears any
# charge inhibit. The macOS native charge limit is left as set (System Settings -> Battery).
set -u
LABEL=dev.abenbjohn.chargecap.helper
/bin/launchctl bootout "system/$LABEL" 2>/dev/null || true
/bin/rm -f "/Library/PrivilegedHelperTools/$LABEL" "/Library/LaunchDaemons/$LABEL.plist"
/bin/rm -rf "/Library/Application Support/ChargeCap"
