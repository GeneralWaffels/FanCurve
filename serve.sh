#!/bin/bash
# Update server for your other Macs. Run on the Mac you develop on.
#   ./serve.sh on      build, package, and start serving on the local network
#   ./serve.sh off     stop serving
#   ./serve.sh status  show whether it's running and the update URL
# Files are served from a secret, random path, so only Macs that know the URL can find them.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$PWD"
PORT=8765
LABEL=local.fancurve.updateserver
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DIST="$ROOT/dist"
TOKEN_FILE="$DIST/.token"

token() {
  mkdir -p "$DIST"
  [[ -s "$TOKEN_FILE" ]] || openssl rand -hex 16 > "$TOKEN_FILE"
  cat "$TOKEN_FILE"
}
url() { echo "http://$(scutil --get LocalHostName).local:$PORT/$(token)"; }
running() { launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; }

package() {
  ./build.sh
  local t; t=$(token)
  rm -rf "$DIST/$t"; mkdir -p "$DIST/$t" "$DIST/stage/FanCurve/build"
  cp -R build/FanCurve.app build/fancurved build/VERSION "$DIST/stage/FanCurve/build/"
  cp install.sh uninstall.sh update.sh README.md "$DIST/stage/FanCurve/"
  (cd "$DIST/stage" && zip -qry "$DIST/$t/FanCurve.zip" FanCurve)
  rm -rf "$DIST/stage"
  cp build/VERSION "$DIST/$t/VERSION"
  cp update.sh "$DIST/$t/update.sh"
  shasum -a 256 "$DIST/$t/FanCurve.zip" | cut -d' ' -f1 > "$DIST/$t/FanCurve.zip.sha256"
  echo "<!-- nothing here -->" > "$DIST/index.html"   # hide the directory listing (and the token)
}

case "${1:-status}" in
  on)
    package
    running && launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    mkdir -p "$HOME/Library/LaunchAgents"
    cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>/usr/bin/python3</string><string>-m</string><string>http.server</string><string>$PORT</string>
    <string>--directory</string><string>$DIST</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>$DIST/server.log</string>
</dict></plist>
PLIST
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    echo
    echo "serving version $(cat build/VERSION)"
    echo "first install on your other Mac:  curl -fsS $(url)/update.sh | bash -s $(url)"
    echo "later updates on that Mac:        ~/Developer/FanCurve/update.sh"
    ;;
  off)
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    echo "update server stopped"
    ;;
  status)
    if running; then echo "running — $(url) (version $(cat "$DIST/$(token)/VERSION" 2>/dev/null))"; else echo "stopped"; fi
    ;;
  *) echo "usage: ./serve.sh on|off|status"; exit 1 ;;
esac
