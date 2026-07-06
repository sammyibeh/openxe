#!/bin/zsh
# Builds, assembles, ad-hoc signs, installs, and registers OpenXE.app.
# Spec §3, §9.1, §9.2.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

# Icons are generated, never checked in (spec §9.1).
if [ ! -f Resources/OpenXE.icns ] || [ ! -f Resources/LauncherFallback.icns ]; then
  swift scripts/make-icon.swift Resources
fi

APP="dist/OpenXE.app"
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/OpenXE "$APP/Contents/MacOS/OpenXE"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/OpenXE.icns "$APP/Contents/Resources/OpenXE.icns"
cp Resources/LauncherFallback.icns "$APP/Contents/Resources/LauncherFallback.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature only — personal use, no notarization (spec hard constraint).
codesign --force -s - "$APP"

SIZE_KB=$(du -sk "$APP" | cut -f1)
echo "OpenXE.app size: ${SIZE_KB} KB"
if [ "$SIZE_KB" -ge 5120 ]; then
  echo "error: OpenXE.app exceeds the 5 MB budget" >&2
  exit 1
fi

# Install as a first-class app (spec §9.2): /Applications when writable,
# else ~/Applications. Register the installed copy with LaunchServices.
DEST="/Applications"
if [ ! -w "$DEST" ]; then
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
fi
rm -rf "$DEST/OpenXE.app"
ditto "$APP" "$DEST/OpenXE.app"

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
"$LSREGISTER" -f "$DEST/OpenXE.app"
echo "Built, signed, and installed: $DEST/OpenXE.app"
echo "If another app currently owns .exe files: Finder > Get Info on any .exe >"
echo "Open With > OpenXE > Change All."
