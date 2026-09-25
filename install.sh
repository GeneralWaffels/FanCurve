#!/bin/bash
# Installs the root fan daemon (launchd) and the menu bar app. Run with: sudo ./install.sh
set -euo pipefail
cd "$(dirname "$0")"
[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
USER_NAME=${SUDO_USER:-$(stat -f %Su /dev/console)}
[[ -x build/fancurved ]] || sudo -u "$USER_NAME" ./build.sh

LABEL=local.fancurve.daemon
PLIST=/Library/LaunchDaemons/$LABEL.plist
launchctl bootout system "$PLIST" 2>/dev/null || true

install -d -m 755 /Library/PrivilegedHelperTools
install -m 755 -o root -g wheel build/fancurved /Library/PrivilegedHelperTools/fancurved

# Config dir owned by you so the app can write the curve; daemon (root) reads it.
install -d -m 755 -o "$USER_NAME" "/Library/Application Support/FanCurve"
touch "/Library/Application Support/FanCurve/status.json"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>/Library/PrivilegedHelperTools/fancurved</string><string>run</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/var/log/fancurved.log</string>
  <key>StandardErrorPath</key><string>/var/log/fancurved.log</string>
</dict></plist>
PLIST
chmod 644 "$PLIST"
launchctl bootstrap system "$PLIST"

rm -rf /Applications/FanCurve.app
cp -R build/FanCurve.app /Applications/
[[ -f build/VERSION ]] && cp build/VERSION "/Library/Application Support/FanCurve/VERSION"
chown -R "$USER_NAME" /Applications/FanCurve.app
pkill -f "FanCurve.app/Contents/MacOS/FanCurve" 2>/dev/null || true
sudo -u "$USER_NAME" open /Applications/FanCurve.app || true
echo "installed $(cat build/VERSION 2>/dev/null). open /Applications/FanCurve.app  ·  logs: tail -f /var/log/fancurved.log"
