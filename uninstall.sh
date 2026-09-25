#!/bin/bash
# Removes the daemon (fans go back to macOS control) and the app. Run with: sudo ./uninstall.sh
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
PLIST=/Library/LaunchDaemons/local.fancurve.daemon.plist
launchctl bootout system "$PLIST" 2>/dev/null || true
/Library/PrivilegedHelperTools/fancurved auto 2>/dev/null || true
rm -f "$PLIST" /Library/PrivilegedHelperTools/fancurved
rm -rf /Applications/FanCurve.app "/Library/Application Support/FanCurve"
echo "uninstalled — fans are back under macOS control"
