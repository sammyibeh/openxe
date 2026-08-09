#!/bin/zsh
# Builds, assembles, ad-hoc signs, installs, and registers OpenXE.app.
# Spec §3, §9.1, §9.2.
#
#   build-app.sh                 build + sign + install to /Applications
#   build-app.sh --no-install    build + sign only, leaving dist/OpenXE.app
#
# --no-install exists so packaging (scripts/package-app.sh) can reuse this exact
# assembly without the side effect of replacing the developer's installed copy.
# There is deliberately no second copy of the assembly logic to drift from.
set -euo pipefail
cd "$(dirname "$0")/.."

INSTALL=1
VERIFY_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --no-install) INSTALL=0 ;;
    --verify-installed) VERIFY_ONLY=1 ;;
    *) echo "usage: build-app.sh [--no-install | --verify-installed]" >&2; exit 2 ;;
  esac
done

# ---- build provenance -------------------------------------------------------
# A bundle carries the commit it was built from, stamped into its Info.plist
# before signing (so the signature covers it). This exists because a stale
# /Applications/OpenXE.app once passed for a fresh one through a whole
# calibration run: it had been assembled from an older dist/, and re-arming
# Gatekeeper rewrote its CFBundleVersion and mtime, erasing the only two
# signals anyone was checking. Neither of those says anything about the CODE.
# OXEBuildCommit does, and rearm_gatekeeper does not touch it.
build_commit() {
  local sha
  git rev-parse --git-dir >/dev/null 2>&1 || { echo "unknown"; return; }
  sha=$(git rev-parse HEAD 2>/dev/null) || { echo "unknown"; return; }
  if ! git diff --quiet HEAD 2>/dev/null || [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    sha="${sha}-dirty"
  fi
  echo "$sha"
}

installed_app_path() {
  if [ -d "/Applications/OpenXE.app" ]; then
    echo "/Applications/OpenXE.app"
  elif [ -d "$HOME/Applications/OpenXE.app" ]; then
    echo "$HOME/Applications/OpenXE.app"
  fi
}

# Compare an installed bundle's stamp against the current HEAD. Non-zero on any
# outcome that does not positively prove the bundle was built from HEAD —
# including a missing stamp, which proves nothing either way.
verify_installed_freshness() {
  local app="$1" stamped expected
  expected=$(build_commit)
  stamped=$(/usr/libexec/PlistBuddy -c "Print :OXEBuildCommit" \
              "$app/Contents/Info.plist" 2>/dev/null) || stamped=""

  if [ -z "$stamped" ]; then
    echo "warning: $app carries no OXEBuildCommit stamp." >&2
    echo "         It predates this guard, so what code it contains cannot be" >&2
    echo "         established from the bundle. Rebuild with scripts/build-app.sh" >&2
    echo "         before trusting it for a calibration run." >&2
    return 1
  fi

  echo "Installed build commit: $stamped"
  echo "Current HEAD:           $expected"
  if [ "$stamped" = "$expected" ]; then
    case "$stamped" in
      *-dirty) echo "note: built from a DIRTY tree — not reproducible from any commit." >&2 ;;
      *) echo "Installed bundle matches HEAD." ;;
    esac
    return 0
  fi

  echo "error: $app was NOT built from the current HEAD." >&2
  echo "       installed: $stamped" >&2
  echo "       HEAD:      $expected" >&2
  echo "       Run scripts/build-app.sh to rebuild and reinstall." >&2
  return 1
}

if [ "$VERIFY_ONLY" -eq 1 ]; then
  APP_PATH=$(installed_app_path)
  [ -n "$APP_PATH" ] || { echo "error: OpenXE.app is not installed" >&2; exit 1; }
  verify_installed_freshness "$APP_PATH" || exit 1
  exit 0
fi

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

# Stamp provenance into the COPY, never into Resources/Info.plist — the repo
# stays clean and a build never dirties the tree it is measuring. Written
# before codesign so the signature covers it: editing the stamp after the fact
# breaks `codesign --verify --strict`, so it cannot be forged quietly.
BUILD_COMMIT=$(build_commit)
BUILD_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)
/usr/libexec/PlistBuddy -c "Add :OXEBuildCommit string $BUILD_COMMIT" \
  "$APP/Contents/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Add :OXEBuildTime string $BUILD_TIME" \
  "$APP/Contents/Info.plist" >/dev/null
echo "Build commit: ${BUILD_COMMIT}"
case "$BUILD_COMMIT" in
  *-dirty|unknown)
    echo "warning: building from a ${BUILD_COMMIT##*-} tree — the installed bundle" >&2
    echo "         will not correspond to any commit." >&2 ;;
esac

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

if [ "$INSTALL" -eq 0 ]; then
  echo "Built and signed (not installed): $APP"
  exit 0
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

# Verify what actually LANDED, not what we intended to copy. `ditto` onto a
# path an earlier bundle occupied is the step that historically produced a
# mismatch between dist/ and /Applications.
verify_installed_freshness "$DEST/OpenXE.app" \
  || { echo "error: the installed bundle failed its freshness check" >&2; exit 1; }

echo "Built, signed, and installed: $DEST/OpenXE.app"
echo "If another app currently owns .exe files: Finder > Get Info on any .exe >"
echo "Open With > OpenXE > Change All."
