#!/bin/zsh
# Build a drag-to-install .dmg (app + /Applications symlink); signs it if CODESIGN_IDENTITY is set.
#   Scripts/make-dmg.sh [app-path] [dmg-path]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/build/IphoneBackupExplorer.app}"
DMG="${2:-$ROOT/build/IphoneBackupExplorer.dmg}"
VOLNAME="${DMG_VOLNAME:-iPhone Backup Explorer}"
[[ -d "$APP" ]] || { echo "No app at $APP"; exit 1; }
STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
echo "==> creating $DMG"
# Build the image in a temp location (avoids on-access scanners locking files under the repo),
# then move it into place. Retry: scanners (e.g. Sophos) can briefly hold "Resource busy".
TMPDMG="$(mktemp -u).dmg"
for attempt in $(seq 1 8); do
  if hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -ov -format UDZO "$TMPDMG" >/dev/null 2>/tmp/ibe-hdiutil.err; then break; fi
  echo "   hdiutil busy (attempt $attempt), retrying…"; sleep 8
  [[ $attempt == 8 ]] && { echo "✗ hdiutil create failed: $(tail -1 /tmp/ibe-hdiutil.err)"; exit 1; }
done
mv "$TMPDMG" "$DMG"
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  codesign --force --sign "$CODESIGN_IDENTITY" "$DMG"; echo "==> signed dmg"
fi
echo "Built: $DMG"
