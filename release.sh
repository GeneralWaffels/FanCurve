#!/bin/bash
# Builds FanCurve and publishes it as a GitHub Release, which the app's updater installs
# (Settings → General → Software Update → GitHub Releases).
#   ./release.sh            release the current commit
#   ./release.sh "notes"    with custom release notes
set -euo pipefail
cd "$(dirname "$0")"
command -v gh >/dev/null || { echo "install the GitHub CLI first: brew install gh"; exit 1; }
if [[ -n "$(git status --porcelain)" ]]; then
  echo "you have uncommitted changes — commit them first so the release matches the code"; exit 1
fi

./build.sh
VERSION=$(cat build/VERSION)
OUT=dist/release; rm -rf "$OUT" dist/stage; mkdir -p "$OUT" dist/stage/FanCurve/build
cp -R build/FanCurve.app build/fancurved build/VERSION dist/stage/FanCurve/build/
cp install.sh uninstall.sh update.sh README.md dist/stage/FanCurve/
(cd dist/stage && zip -qry "../../$OUT/FanCurve.zip" FanCurve)
rm -rf dist/stage
shasum -a 256 "$OUT/FanCurve.zip" | cut -d' ' -f1 > "$OUT/FanCurve.zip.sha256"

git push -q
NOTES=${1:-$(git log -1 --pretty=%B)}
gh release create "v$VERSION" "$OUT/FanCurve.zip" "$OUT/FanCurve.zip.sha256" \
  --title "FanCurve $VERSION" --notes "$NOTES" --target "$(git rev-parse HEAD)"
echo "released v$VERSION — Macs running FanCurve will offer it within a few hours (or press Check Now)"
