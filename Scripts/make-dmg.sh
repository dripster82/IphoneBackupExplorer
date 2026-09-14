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
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  codesign --force --sign "$CODESIGN_IDENTITY" "$DMG"; echo "==> signed dmg"
fi
echo "Built: $DMG"
