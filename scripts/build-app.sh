#!/bin/zsh
# Builds, assembles, ad-hoc signs, installs, and registers OpenXE.app.
# Spec §3, §9.1, §9.2.
set -euo pipefail
cd "$(dirname "$0")/.."

# A source file that exists locally but was never committed builds fine here and
# breaks on every other clone. SPM compiles whatever is in Sources/, so nothing
# else catches it. Warn loudly; do not block a work-in-progress build.
if git rev-parse --git-dir >/dev/null 2>&1; then
  UNTRACKED=$(git ls-files --others --exclude-standard -- 'Sources/**/*.swift')
  if [ -n "$UNTRACKED" ]; then
    echo "warning: uncommitted source files — this build would FAIL on a fresh clone:" >&2
    echo "$UNTRACKED" | sed 's/^/  /' >&2
  fi
fi

# Universal (arm64 + x86_64). A host-arch-only build would refuse to launch on
# the other kind of Mac, and Intel Macs run the x86_64 Wine engine NATIVELY —
# no Rosetta involved — so they are a first-class target, not a fallback.
# `--arch` routes the build through the Xcode build system, which writes to
# .build/apple/Products/Release rather than .build/release.
swift build -c release --arch arm64 --arch x86_64
UNIVERSAL_BIN=".build/apple/Products/Release/OpenXE"
ARCHS=$(lipo -archs "$UNIVERSAL_BIN")
echo "OpenXE architectures: ${ARCHS}"
case "$ARCHS" in
  *arm64*) ;;
  *) echo "error: built binary has no arm64 slice (got: ${ARCHS})" >&2; exit 1 ;;
esac
case "$ARCHS" in
  *x86_64*) ;;
  *) echo "error: built binary has no x86_64 slice (got: ${ARCHS})" >&2; exit 1 ;;
esac

# Icons are generated, never checked in (spec §9.1).
if [ ! -f Resources/OpenXE.icns ] || [ ! -f Resources/LauncherFallback.icns ]; then
  swift scripts/make-icon.swift Resources
fi

APP="dist/OpenXE.app"
rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$UNIVERSAL_BIN" "$APP/Contents/MacOS/OpenXE"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/OpenXE.icns "$APP/Contents/Resources/OpenXE.icns"
cp Resources/LauncherFallback.icns "$APP/Contents/Resources/LauncherFallback.icns"
# WPF compatibility font: wine-mono fails to load app-embedded FontAwesome
# resources and crashes in text layout; a system-installed copy resolves it.
# OFL-1.1 licensed, redistributable (spec §4.2). ~165 KB.
cp Resources/FontAwesome.ttf "$APP/Contents/Resources/FontAwesome.ttf"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature only — personal use, no notarization (spec hard constraint).
# One codesign pass covers a universal binary: the signature is embedded per
# slice. Verify each slice explicitly so a half-signed bundle cannot ship.
codesign --force -s - "$APP"
codesign --verify --strict "$APP"
for a in arm64 x86_64; do
  codesign -dv --arch "$a" "$APP" >/dev/null 2>&1 \
    || { echo "error: ${a} slice is not signed" >&2; exit 1; }
done

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
