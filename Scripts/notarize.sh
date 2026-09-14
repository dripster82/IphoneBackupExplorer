#!/bin/zsh
# Notarize + staple build/IphoneBackupExplorer.app.
# Prereq: a Developer-ID-signed release build and a stored notarytool profile.
#   Scripts/notarize.sh [keychain-profile]   (default: notary-arwm)
set -euo pipefail
PROFILE="${1:-notary-arwm}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/IphoneBackupExplorer.app"
ZIP="$(mktemp -d)/IphoneBackupExplorer.zip"
[[ -d "$APP" ]] || { echo "No app at $APP — build a release first."; exit 1; }
echo "==> zipping for submission"; ditto -c -k --keepParent "$APP" "$ZIP"
echo "==> submitting to Apple notary (profile: $PROFILE)"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
echo "==> stapling"; xcrun stapler staple "$APP"; xcrun stapler validate "$APP"
spctl -a -vvv -t exec "$APP" 2>&1 | head -3
echo "==> notarized + stapled: $APP"
