#!/bin/bash
# Pulls the latest FanCurve from your update server and installs it.
#   ./update.sh <url>   first time: remember the URL printed by `./serve.sh on`, then update
#   ./update.sh         update from the remembered URL
set -euo pipefail
CONF="$HOME/.fancurve-update-url"
[[ $# -ge 1 ]] && echo "${1%/}" > "$CONF"
[[ -s "$CONF" ]] || { echo "usage: $0 <update url from ./serve.sh on>"; exit 1; }
URL=$(cat "$CONF")

REMOTE=$(curl -fsS --max-time 5 "$URL/VERSION") || { echo "can't reach $URL — is ./serve.sh on running on the other Mac, and are you on the same network?"; exit 1; }
LOCAL=$(cat "/Library/Application Support/FanCurve/VERSION" 2>/dev/null || echo none)
if [[ "$REMOTE" == "$LOCAL" && "${FORCE:-0}" != 1 ]]; then echo "already up to date ($LOCAL)"; exit 0; fi
echo "updating $LOCAL → $REMOTE"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
curl -fsS "$URL/FanCurve.zip" -o "$TMP/FanCurve.zip"
EXPECTED=$(curl -fsS "$URL/FanCurve.zip.sha256")
ACTUAL=$(shasum -a 256 "$TMP/FanCurve.zip" | cut -d' ' -f1)
[[ "$EXPECTED" == "$ACTUAL" ]] || { echo "checksum mismatch — download corrupted, aborting"; exit 1; }

if [[ -f "$HOME/Developer/FanCurve/Package.swift" ]]; then
  echo "~/Developer/FanCurve is a source checkout (this is your dev Mac) — refusing to overwrite it"; exit 1
fi
mkdir -p "$HOME/Developer"
rm -rf "$HOME/Developer/FanCurve.new"; mkdir "$HOME/Developer/FanCurve.new"
unzip -q "$TMP/FanCurve.zip" -d "$HOME/Developer/FanCurve.new"
xattr -dr com.apple.quarantine "$HOME/Developer/FanCurve.new" 2>/dev/null || true
rm -rf "$HOME/Developer/FanCurve"
mv "$HOME/Developer/FanCurve.new/FanCurve" "$HOME/Developer/FanCurve"
rmdir "$HOME/Developer/FanCurve.new"

sudo "$HOME/Developer/FanCurve/install.sh"
