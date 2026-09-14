#!/bin/zsh
# Build IphoneBackupExplorer.app and sign it.
#   Scripts/build-app.sh [debug|release]
# For a `release` build, set CODESIGN_IDENTITY to a Developer ID to get a hardened-runtime,
# timestamped, distributable signature (required before notarizing). Otherwise it ad-hoc signs.
# Env: IBE_VERSION (stamped into CFBundleShortVersionString), IBE_BUILD (CFBundleVersion),
#      CODESIGN_IDENTITY.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
CONFIG_IN="${1:-release}"
case "$CONFIG_IN" in
  debug) CONFIG=Debug ;;
  release) CONFIG=Release ;;
  *) echo "usage: $0 [debug|release]"; exit 1 ;;
esac
SCHEME="IphoneBackupExplorer"
APP_NAME="IphoneBackupExplorer.app"
ENTITLEMENTS="$ROOT/Resources/IphoneBackupExplorer.entitlements"
BUNDLE_ID="co.uk.ketelle.IphoneBackupExplorer"
DD="$ROOT/build/dd"

command -v xcodegen >/dev/null && xcodegen generate >/dev/null

echo "==> [build] $CONFIG universal (arm64 + x86_64)"
xcodebuild -project IphoneBackupExplorer.xcodeproj -scheme "$SCHEME" -configuration "$CONFIG" \
  -derivedDataPath "$DD" \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=NO \
  ${IBE_VERSION:+MARKETING_VERSION="$IBE_VERSION"} \
  build >/dev/null

BUILT="$DD/Build/Products/$CONFIG/$APP_NAME"
[[ -d "$BUILT" ]] || { echo "✗ build product missing: $BUILT"; exit 1; }

# Stamp version into Info.plist if provided.
if [[ -n "${IBE_VERSION:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $IBE_VERSION" "$BUILT/Contents/Info.plist" 2>/dev/null || true
fi
if [[ -n "${IBE_BUILD:-}" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $IBE_BUILD" "$BUILT/Contents/Info.plist" 2>/dev/null || true
fi

mkdir -p "$ROOT/build"
APP="$ROOT/build/$APP_NAME"
rm -rf "$APP"; cp -R "$BUILT" "$APP"

# Resolve identity: explicit override, else the first Developer ID Application, else ad-hoc.
IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -p codesigning -v 2>/dev/null | awk -F\" '/Developer ID Application/{print $2; exit}')"
fi
[[ -z "$IDENTITY" ]] && IDENTITY="-"

RUNTIME_OPTS=()
if [[ "$IDENTITY" != "-" ]]; then RUNTIME_OPTS=(--options runtime --timestamp); fi
SIGN=(codesign --force ${RUNTIME_OPTS[@]} --sign "$IDENTITY")

echo "==> [sign] identity: $IDENTITY"
# Sign any nested code first (frameworks/dylibs), then the app bundle.
find "$APP/Contents" \( -name "*.dylib" -o -name "*.framework" \) -print0 2>/dev/null | while IFS= read -r -d '' f; do
  "${SIGN[@]}" "$f"
done
"${SIGN[@]}" --entitlements "$ENTITLEMENTS" --identifier "$BUNDLE_ID" "$APP"

codesign --verify --strict "$APP" || { echo "✗ codesign --verify FAILED"; exit 1; }
echo "==> signature OK ($(codesign -dvv "$APP" 2>&1 | grep -E 'Identifier=|Authority=' | head -2 | tr '\n' ' '))"
echo "Built: $APP"
