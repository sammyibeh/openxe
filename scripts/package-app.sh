#!/bin/zsh
# Packages OpenXE.app into a distributable dist/OpenXE.dmg, then verifies the
# image by actually mounting it.
#
# Why a .dmg and not a .zip:
#
#   It does NOT help with Gatekeeper. Quarantine propagates through either
#   format and an unnotarized app is blocked identically — verified on macOS
#   27.0, see docs/platform-support.md §4.
#
#   The reason is App Translocation. A quarantined app launched from where it
#   was downloaded (typically ~/Downloads) is run by macOS from a randomised
#   read-only path instead of its real one. A .dmg with an /Applications
#   symlink makes "drag the app across" the obvious gesture, and moving an app
#   in Finder clears its quarantine flag, which ends translocation. A .zip
#   invites double-clicking the app straight out of Downloads, which does not.
#
# Assembly and signing are NOT duplicated here: this calls build-app.sh
# --no-install so there is one definition of how OpenXE.app is built.
#
# No third-party tooling — hdiutil only (lean-footprint charter).
# Ad-hoc signature only, matching the app. Notarization is out of scope.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/OpenXE.app"
DMG="dist/OpenXE.dmg"
STAGE="dist/dmg-stage"
VOLNAME="OpenXE"

# Build + sign, but do not touch the developer's installed copy. This also
# carries the untracked-source guard and the 5 MB bundle gate, which stay in
# build-app.sh and apply to the APP BUNDLE, never to the compressed image.
scripts/build-app.sh --no-install

[ -d "$APP" ] || { echo "error: $APP missing after build" >&2; exit 1; }

# Drag-to-install layout: the app beside a symlink to /Applications.
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/OpenXE.app"
ln -s /Applications "$STAGE/Applications"

# HFS+ rather than APFS: universally mountable, and the conventional choice for
# a distribution image. UDZO is the compressed, read-only format.
hdiutil create -quiet -volname "$VOLNAME" -srcfolder "$STAGE" \
  -ov -format UDZO -fs HFS+ "$DMG"
rm -rf "$STAGE"

# Ad-hoc signature on the image, matching the app's posture (spec hard
# constraint: no Developer ID, no notarization).
codesign --force -s - "$DMG"
codesign --verify --strict "$DMG"

# ---- Verification: mount the image we just produced and inspect it ----------
MOUNT="$(mktemp -d /tmp/openxe-dmg-verify.XXXXXX)"
cleanup() {
  hdiutil detach "$MOUNT" -quiet -force >/dev/null 2>&1 || true
  rmdir "$MOUNT" >/dev/null 2>&1 || true
}
trap cleanup EXIT

hdiutil attach "$DMG" -quiet -nobrowse -readonly -mountpoint "$MOUNT"

MOUNTED_APP="$MOUNT/OpenXE.app"
[ -d "$MOUNTED_APP" ] || { echo "error: OpenXE.app missing inside the image" >&2; exit 1; }

# The app inside the image must still be universal — a thin binary would refuse
# to launch on the other kind of Mac.
ARCHS=$(lipo -archs "$MOUNTED_APP/Contents/MacOS/OpenXE")
echo "Image app architectures: ${ARCHS}"
case "$ARCHS" in *arm64*) ;; *) echo "error: no arm64 slice in the image" >&2; exit 1 ;; esac
case "$ARCHS" in *x86_64*) ;; *) echo "error: no x86_64 slice in the image" >&2; exit 1 ;; esac

# The signature must survive the round trip through the image.
codesign --verify --strict "$MOUNTED_APP" \
  || { echo "error: app signature broken inside the image" >&2; exit 1; }

# The drag target must actually resolve to /Applications.
[ -L "$MOUNT/Applications" ] \
  || { echo "error: /Applications symlink missing from the image" >&2; exit 1; }
LINK_TARGET=$(readlink "$MOUNT/Applications")
[ "$LINK_TARGET" = "/Applications" ] \
  || { echo "error: Applications symlink points at '$LINK_TARGET'" >&2; exit 1; }
[ -d "$MOUNT/Applications" ] \
  || { echo "error: Applications symlink does not resolve to a directory" >&2; exit 1; }
echo "Applications symlink resolves: $LINK_TARGET"

hdiutil detach "$MOUNT" -quiet
trap - EXIT
rmdir "$MOUNT" >/dev/null 2>&1 || true
echo "Image detached cleanly"

# Report both numbers. The 5 MB budget is a promise about the APP BUNDLE; the
# image is reported for information only and is never gated.
APP_KB=$(du -sk "$APP" | cut -f1)
DMG_KB=$(du -sk "$DMG" | cut -f1)
echo
echo "App bundle:      ${APP_KB} KB  (budget 5120 KB, enforced in build-app.sh)"
echo "Compressed .dmg: ${DMG_KB} KB  (not gated)"
echo "Packaged: $DMG"
