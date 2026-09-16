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
# Retry: on-access scanners (e.g. Sophos) can briefly lock the freshly copied .app,
# making hdiutil fail with "Resource busy".
for attempt in 1 2 3 4 5; do
  if hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null 2>/tmp/ibe-hdiutil.err; then break; fi
  echo "   hdiutil busy (attempt $attempt), retrying…"; sleep 5
  [[ $attempt == 5 ]] && { echo "✗ hdiutil create failed: $(tail -1 /tmp/ibe-hdiutil.err)"; exit 1; }
done
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  codesign --force --sign "$CODESIGN_IDENTITY" "$DMG"; echo "==> signed dmg"
fi
echo "Built: $DMG"
