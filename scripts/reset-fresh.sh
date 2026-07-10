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
#   --quarantine <path>  Also re-apply com.apple.quarantine recursively to the
#                        given OpenXE.app copy so the next open shows the
#                        genuine first-open Gatekeeper prompt. No default path.
set -euo pipefail

log() { echo "$*"; }
err() { echo "error: $*" >&2; }

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
      sed -n '2,33p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
  log "Will re-apply com.apple.quarantine recursively to: $QUARANTINE_APP"
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

# Tolerate "domain not found".
defaults delete "$DEFAULTS_DOMAIN" >/dev/null 2>&1 || true

if [ -d "$OPENXE_LOGS" ]; then
  log "Removing $OPENXE_LOGS ..."
  rm -rf "$OPENXE_LOGS"
fi

# ---- step 4: re-arm Gatekeeper (optional) ------------------------------------
if [ -n "$QUARANTINE_APP" ]; then
  log "Re-applying quarantine to $QUARANTINE_APP ..."
  # 0081 = downloaded-file flags; next open gets the first-open Gatekeeper prompt.
  xattr -r -w com.apple.quarantine \
    "0081;$(printf '%x' "$(date +%s)");reset-fresh;" "$QUARANTINE_APP"
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
log ""
log "Fresh state confirmed — next launch runs the wizard from step 1."
