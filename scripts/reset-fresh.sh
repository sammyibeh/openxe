#!/usr/bin/env bash
# reset-fresh.sh — return this Mac to a true OpenXE first-run state, so the
# complete fresh-device experience (wizard from step 1: disclaimer → engine
# download → NWS download/install → launch) can be reproduced at will.
# Design: docs/design/specs/2026-07-10-fresh-reset-design.md (binding).
#
# What it deletes (tolerating already-missing paths):
#   ~/Library/Application Support/OpenXE/   engines, prefix (incl. the NWS
#                                           install), AppBundles,
#                                           appconfigs.json, nws-download
#   OpenXE-generated launcher .app bundles  in "/Applications/OpenXE Apps" and
#                                           "~/Applications/OpenXE Apps" —
#                                           only bundles carrying the
#                                           OpenXETargetPath marker, each
#                                           lsregister -u'd first
#   defaults domain dev.openxe.OpenXE
#   ~/Library/Logs/OpenXE/
#
# What it NEVER touches: the real ~/Documents, ~/Downloads, ~/Desktop (the
# prefix only holds symlinks to them, and rm -rf does not follow symlinks;
# nothing here may follow symlinks — e.g. no `find -L`), the repo working
# tree, dist/, and ~/.cache/openxe-engine-build.
#
# Usage:
#   scripts/reset-fresh.sh [--yes] [--dry-run] [--quarantine <path-to-OpenXE.app>]
#
#   --yes                Skip the confirmation prompt
#   --dry-run            Print everything that would be deleted, delete
#                        nothing, exit 0
#   --quarantine <path>  Also re-arm Gatekeeper on the given OpenXE.app copy so
#                        the next open shows the genuine first-open prompt.
#                        Re-applying com.apple.quarantine is NOT enough on its
#                        own — see rearm_gatekeeper below — so this also gives
#                        the bundle a code-directory hash this Mac has never
#                        approved, by bumping CFBundleVersion and re-signing
#                        ad-hoc. Both steps are verified; it fails loudly rather
#                        than reporting a reset it did not perform. Re-run it
#                        AFTER every `make app`, because a rebuild restores the
#                        original (already-approved) cdhash. No default path.
set -euo pipefail

log() { echo "$*"; }
err() { echo "error: $*" >&2; }

cdhash_of() {
  codesign -dvvv "$1" 2>&1 | sed -n 's/^CDHash=//p' | head -1 || true
}

# Re-arming Gatekeeper takes more than re-applying the quarantine xattr, which
# is all this script used to do — and it silently did not work.
#
# macOS caches the user's approval of a bundle in
# /var/db/SystemPolicyConfiguration/ExecPolicy, keyed on the bundle's
# code-directory hash. Verified on this machine 2026-08-09: that file is
# SIP-`restricted` (unwritable even as root, `ls -lO`), and this OS's spctl
# offers only --assess / --status / --global-disable — no --add, --remove or
# --reset. So once a cdhash has been approved, the bundle keeps launching
# straight through however many times its quarantine xattr is rewritten. A
# reset that silently fails to reset would corrupt exactly the cold-Mac
# calibration this script exists to enable.
#
# The one lever that works without root is the cdhash itself: give the bundle a
# code directory this Mac has never seen and the cache simply misses. Bumping
# CFBundleVersion does that. It is the safest possible change: it appears only
# in Resources/Info.plist and no OpenXE source reads it, so the build under test
# is otherwise byte-identical.
#
# Every step is verified. If the cdhash does not actually change, or the
# quarantine xattr does not land on the bundle root, this fails loudly and says
# what it could not reset.
rearm_gatekeeper() {
  local app="$1" before after stamp a
  before=$(cdhash_of "$app")
  if [ -z "$before" ]; then
    err "cannot read the code-directory hash of $app — is it signed?"
    return 1
  fi
  log "Re-arming Gatekeeper on $app"
  log "  cdhash before:  $before"

  stamp=$(date -u +%Y%m%d%H%M%S)
  if ! /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $stamp" \
        "$app/Contents/Info.plist" >/dev/null 2>&1; then
    err "could not set CFBundleVersion in $app/Contents/Info.plist"
    return 1
  fi
  # Ad-hoc, exactly as scripts/build-app.sh signs it. Verify strictly and
  # per-slice so a re-arm can never hand back a half-signed universal bundle.
  if ! codesign --force -s - "$app" >/dev/null 2>&1; then
    err "ad-hoc re-signing failed for $app"
    return 1
  fi
  if ! codesign --verify --strict "$app" >/dev/null 2>&1; then
    err "$app does not verify after re-signing"
    return 1
  fi
  for a in arm64 x86_64; do
    if ! codesign -dv --arch "$a" "$app" >/dev/null 2>&1; then
      err "the $a slice is not signed after re-signing $app"
      return 1
    fi
  done

  after=$(cdhash_of "$app")
  if [ -z "$after" ] || [ "$after" = "$before" ]; then
    err "cdhash did not change (still ${before})."
    err "Gatekeeper's approval cache is keyed on it and lives in the"
    err "SIP-protected /var/db/SystemPolicyConfiguration/ExecPolicy, which no"
    err "script can clear. If this Mac has already approved this build, the"
    err "next open will NOT show the first-open prompt. Test on a Mac that has"
    err "never run it, or change the bundle so its cdhash differs."
    return 1
  fi
  log "  cdhash after:   $after  (CFBundleVersion=$stamp)"

  # 0081 = downloaded-file flags; next open gets the first-open Gatekeeper prompt.
  if ! xattr -r -w com.apple.quarantine \
        "0081;$(printf '%x' "$(date +%s)");reset-fresh;" "$app"; then
    err "could not write com.apple.quarantine to $app"
    return 1
  fi
  # The bundle root's xattr is the one LaunchServices reads; confirm it stuck
  # rather than trusting the recursive write's exit status.
  if ! xattr -p com.apple.quarantine "$app" >/dev/null 2>&1; then
    err "com.apple.quarantine did not stick on the bundle root of $app"
    return 1
  fi
  log "  quarantine:     $(xattr -p com.apple.quarantine "$app")"

  # LaunchServices has the pre-bump bundle cached; re-register so the next open
  # resolves against what we just rewrote.
  "$LSREGISTER" -f "$app" >/dev/null 2>&1 || true

  log "Gatekeeper re-armed: this Mac has never approved cdhash $after."
  log "NOTE: re-run this after every \`make app\` — a rebuild restores"
  log "CFBundleVersion=1 and with it the original, already-approved cdhash."
}

OPENXE_ROOT="${HOME:?HOME is not set}/Library/Application Support/OpenXE"
OPENXE_LOGS="$HOME/Library/Logs/OpenXE"
DEFAULTS_DOMAIN="dev.openxe.OpenXE"
LAUNCHER_DIRS=("/Applications/OpenXE Apps" "$HOME/Applications/OpenXE Apps")
MARKER_KEY="OpenXETargetPath"  # per LauncherManager.targetPathKey
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"

# ---- flags -----------------------------------------------------------------
YES=0
DRY_RUN=0
QUARANTINE_APP=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --yes) YES=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --quarantine)
      if [ "$#" -lt 2 ] || [ -z "${2:-}" ]; then
        err "--quarantine requires a path to an OpenXE.app copy"; exit 2
      fi
      QUARANTINE_APP="$2"; shift ;;
    -h|--help)
      sed -n '2,39p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) err "unknown flag: $1 (see --help)"; exit 2 ;;
  esac
  shift
done

# ---- invariants ------------------------------------------------------------
if [ "$(id -u)" -eq 0 ]; then
  err "refusing to run as root — run as the user whose OpenXE state this is."
  exit 1
fi
if [ -n "$QUARANTINE_APP" ]; then
  case "$QUARANTINE_APP" in
    *.app) ;;
    *) err "--quarantine path must be an .app bundle: $QUARANTINE_APP"; exit 2 ;;
  esac
  if [ ! -d "$QUARANTINE_APP" ]; then
    err "--quarantine path does not exist: $QUARANTINE_APP"; exit 2
  fi
fi

# ---- step 1: safety gate ----------------------------------------------------
# Abort if OpenXE.app is running or if any wine/wineserver process belongs to
# an installed OpenXE engine. Engine processes are matched on the engine path
# under $OPENXE_ROOT/engine/ — NOT on bare process names, so unrelated Wine
# installs are never killed or blocked on. A dry run deletes nothing, so it
# only warns — it must stay usable for testing the script while OpenXE is up.
gate() { # $1 = message; abort for a real run, warn for a dry run
  if [ "$DRY_RUN" -eq 1 ]; then
    log "warning: $1 (continuing — dry run deletes nothing)"
  else
    err "$1"
    return 1
  fi
}
if pgrep -f "OpenXE\.app/Contents/MacOS/OpenXE" >/dev/null 2>&1; then
  gate "OpenXE.app is running — quit it first (it holds the state this script deletes)." \
    || exit 1
fi
if pgrep -f "$OPENXE_ROOT/engine/" >/dev/null 2>&1; then
  if ! gate "Wine processes from an installed OpenXE engine are still alive."; then
    err "Quit the Windows programs (or run: \"$OPENXE_ROOT/engine/current/wine/bin/wineserver\" -k) and retry."
    pgrep -fl "$OPENXE_ROOT/engine/" >&2 || true
    exit 1
  fi
fi

# Find OpenXE-generated launchers: .app bundles carrying the marker key.
# Anything else in an "OpenXE Apps" folder is left alone.
LAUNCHERS=()
for dir in "${LAUNCHER_DIRS[@]}"; do
  [ -d "$dir" ] || continue
  for bundle in "$dir"/*.app; do
    [ -d "$bundle" ] || continue
    if /usr/libexec/PlistBuddy -c "Print :$MARKER_KEY" \
        "$bundle/Contents/Info.plist" >/dev/null 2>&1; then
      LAUNCHERS+=("$bundle")
    fi
  done
done

DEFAULTS_PRESENT=0
if defaults read "$DEFAULTS_DOMAIN" >/dev/null 2>&1; then DEFAULTS_PRESENT=1; fi

# Plain-English summary of exactly what will be deleted.
verb="Will delete"
[ "$DRY_RUN" -eq 1 ] && verb="Would delete (dry run)"
log "OpenXE fresh-install reset — $verb:"
FOUND_ANY=0
if [ -d "$OPENXE_ROOT" ]; then
  FOUND_ANY=1
  log "  $OPENXE_ROOT/  (all OpenXE state)"
  for item in "$OPENXE_ROOT"/* "$OPENXE_ROOT"/.[!.]*; do
    [ -e "$item" ] || [ -L "$item" ] || continue
    log "    - ${item##*/}"
  done
fi
for bundle in ${LAUNCHERS[@]+"${LAUNCHERS[@]}"}; do
  FOUND_ANY=1
  log "  $bundle  (generated launcher; lsregister -u first)"
done
if [ "$DEFAULTS_PRESENT" -eq 1 ]; then
  FOUND_ANY=1
  log "  defaults domain $DEFAULTS_DOMAIN"
fi
if [ -d "$OPENXE_LOGS" ]; then
  FOUND_ANY=1
  log "  $OPENXE_LOGS/"
fi
if [ "$FOUND_ANY" -eq 0 ]; then
  log "  (nothing — this machine is already in a fresh state)"
fi
if [ -n "$QUARANTINE_APP" ]; then
  log "Will re-arm Gatekeeper on: $QUARANTINE_APP"
  log "  (bumps CFBundleVersion + re-signs ad-hoc for a fresh cdhash, then"
  log "   re-applies com.apple.quarantine — see rearm_gatekeeper for why the"
  log "   xattr alone does nothing once this Mac has approved the build)"
fi
log "Never touched: ~/Documents, ~/Downloads, ~/Desktop (prefix symlinks only),"
log "the repo working tree, dist/, ~/.cache/openxe-engine-build."

if [ "$DRY_RUN" -eq 1 ]; then
  log ""
  log "Dry run — nothing was deleted."
  exit 0
fi

if [ "$YES" -ne 1 ]; then
  printf "Proceed? This destroys the current engine, prefix, and installed apps. [y/N] "
  read -r answer
  case "$answer" in
    y|Y|yes|YES) ;;
    *) log "Aborted — nothing was deleted."; exit 1 ;;
  esac
fi

# ---- step 2: shut down ------------------------------------------------------
# If an active engine exists, stop its wineserver against the OpenXE prefix so
# no Wine process holds files open. Tolerate absence (partial state) silently.
WINESERVER="$OPENXE_ROOT/engine/current/wine/bin/wineserver"
if [ -x "$WINESERVER" ] && [ -d "$OPENXE_ROOT/prefix" ]; then
  log "Shutting down the Windows environment (wineserver -k)..."
  WINEPREFIX="$OPENXE_ROOT/prefix" "$WINESERVER" -k >/dev/null 2>&1 || true
  WINEPREFIX="$OPENXE_ROOT/prefix" "$WINESERVER" -w >/dev/null 2>&1 || true
fi

# ---- step 3: wipe state -----------------------------------------------------
# Launchers first: unregister from LaunchServices, then remove. Only bundles
# carrying the marker are removed; the "OpenXE Apps" folder goes only if
# nothing else is left in it (Finder's .DS_Store does not count).
for bundle in ${LAUNCHERS[@]+"${LAUNCHERS[@]}"}; do
  log "Removing launcher: $bundle"
  "$LSREGISTER" -u "$bundle" >/dev/null 2>&1 || true
  rm -rf "$bundle"
done
for dir in "${LAUNCHER_DIRS[@]}"; do
  [ -d "$dir" ] || continue
  rm -f "$dir/.DS_Store"
  rmdir "$dir" 2>/dev/null || log "Kept $dir — it still contains non-OpenXE items."
done

if [ -d "$OPENXE_ROOT" ]; then
  log "Removing $OPENXE_ROOT ..."
  rm -rf "$OPENXE_ROOT"
fi

# Tolerate "domain not found". `defaults delete` can leave (or refuse to
# touch) an empty-but-present domain: cfprefsd rewrites an empty plist instead
# of unlinking it, `defaults read` then sees {} / exit 0 while `defaults
# delete` says "not found" / exit 1 — an unwinnable state via the CLI alone.
# So delete via cfprefsd first, and only if the domain still reads as present
# (i.e. it is key-empty), remove the leftover plist file directly.
if defaults read "$DEFAULTS_DOMAIN" >/dev/null 2>&1; then
  log "Removing defaults domain $DEFAULTS_DOMAIN ..."
  defaults delete "$DEFAULTS_DOMAIN" >/dev/null 2>&1 || true
  if defaults read "$DEFAULTS_DOMAIN" >/dev/null 2>&1; then
    rm -f "$HOME/Library/Preferences/$DEFAULTS_DOMAIN.plist"
  fi
fi

if [ -d "$OPENXE_LOGS" ]; then
  log "Removing $OPENXE_LOGS ..."
  rm -rf "$OPENXE_LOGS"
fi

# ---- step 4: re-arm Gatekeeper (optional) ------------------------------------
REARM_FAILED=0
if [ -n "$QUARANTINE_APP" ]; then
  rearm_gatekeeper "$QUARANTINE_APP" || REARM_FAILED=1
fi

# ---- step 5: verify and report ------------------------------------------------
SURVIVORS=()
[ -e "$OPENXE_ROOT" ] && SURVIVORS+=("$OPENXE_ROOT")
[ -e "$OPENXE_LOGS" ] && SURVIVORS+=("$OPENXE_LOGS")
for bundle in ${LAUNCHERS[@]+"${LAUNCHERS[@]}"}; do
  [ -e "$bundle" ] && SURVIVORS+=("$bundle")
done
if defaults read "$DEFAULTS_DOMAIN" >/dev/null 2>&1; then
  SURVIVORS+=("defaults domain $DEFAULTS_DOMAIN")
fi

if [ "${#SURVIVORS[@]}" -gt 0 ]; then
  err "reset incomplete — the following survived:"
  for s in "${SURVIVORS[@]}"; do echo "  $s" >&2; done
  exit 1
fi
# The OpenXE state is gone either way; a failed Gatekeeper re-arm still means
# this is NOT a first-run state, and saying so is the whole point of the check.
if [ "$REARM_FAILED" -eq 1 ]; then
  err ""
  err "OpenXE state was wiped, but Gatekeeper was NOT re-armed (see above)."
  err "The next open will skip the first-open prompt — do not treat this as a"
  err "cold-Mac run."
  exit 1
fi
log ""
log "Fresh state confirmed — next launch runs the wizard from step 1."
