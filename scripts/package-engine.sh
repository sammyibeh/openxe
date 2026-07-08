#!/bin/zsh
# package-engine.sh — package a built Wine engine into a distributable tarball,
# compute its SHA-256, and print a ready-to-paste EngineDescriptor for hosting the
# engine as a GitHub Release asset. See docs/distribution.md.
#
# This does NOT upload anything. It produces the artifact + checksum + descriptor;
# publishing the Release asset and pasting the descriptor into EngineCatalog is a
# manual follow-up (kept manual on purpose — the asset is ~1.7 GB).
#
# WHY a separate tarball + checksum: EngineManager.install downloads a URL and
# verifies it against EngineDescriptor.sha256 before extracting. So the descriptor's
# sha256 must be the checksum of THIS packaged tarball (not of the CrossOver *source*
# tarball that build-engine.sh pins). This script computes exactly that.
#
# Usage:
#   scripts/package-engine.sh [ENGINE_DIR]
#
#   ENGINE_DIR is a directory containing wine/bin/<loader>. If omitted, the script
#   looks (in order) at:
#     1. dist/engine/*            (what build-engine.sh stages)
#     2. ~/Library/Application Support/OpenXE/engine/current  (the active install)
#
# Env:
#   OPENXE_RELEASE_URL_BASE   Base URL where the asset will live. Default is the
#                             GitHub Releases download URL for this repo. The tarball
#                             filename is appended to it.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"

RELEASE_URL_BASE="${OPENXE_RELEASE_URL_BASE:-https://github.com/sammyiyke/openxe/releases/download/engine}"

# ---- locate the engine dir -------------------------------------------------
find_engine_dir() {
  if [ "$#" -ge 1 ] && [ -n "${1:-}" ]; then
    echo "$1"; return 0
  fi
  # 1) a staged build from build-engine.sh
  local staged
  for staged in "$REPO"/dist/engine/*(/N); do
    if [ -d "$staged/wine/bin" ]; then echo "$staged"; return 0; fi
  done
  # 2) the active installed engine (resolve the current symlink)
  local installed="$HOME/Library/Application Support/OpenXE/engine/current"
  if [ -d "$installed/wine/bin" ]; then
    # resolve symlink to the real versioned dir so we read its descriptor/id
    local real; real="$(cd "$installed" && pwd -P)"
    echo "$real"; return 0
  fi
  return 1
}

ENGINE_DIR="$(find_engine_dir "${1:-}")" || {
  echo "error: no engine found. Build one first (scripts/build-engine.sh) or pass a" >&2
  echo "       directory containing wine/bin/<loader> as the first argument." >&2
  exit 1
}
ENGINE_DIR="${ENGINE_DIR:A}"   # absolute, symlinks resolved

if [ ! -d "$ENGINE_DIR/wine/bin" ]; then
  echo "error: '$ENGINE_DIR' does not contain wine/bin/ — not an engine dir." >&2
  exit 1
fi
echo "Engine dir: $ENGINE_DIR"

# ---- derive id + loader name ----------------------------------------------
# Prefer the on-disk descriptor.json; fall back to the dir name + loader detection.
ID=""; WINE_BIN=""; VERSION=""; DISPLAY=""
DESC="$ENGINE_DIR/descriptor.json"
read_json() { grep -o "\"$1\"[^,}]*" "$DESC" 2>/dev/null | head -1 | sed -E 's/.*:[[:space:]]*"?([^"]*)"?.*/\1/'; }
if [ -f "$DESC" ]; then
  ID="$(read_json id)"; WINE_BIN="$(read_json wineBinaryName)"
  VERSION="$(read_json version)"; DISPLAY="$(read_json displayName)"
fi
[ -n "$ID" ]      || ID="${ENGINE_DIR:t}"
[ -n "$VERSION" ] || VERSION="$ID"
[ -n "$DISPLAY" ] || DISPLAY="$ID"
if [ -z "$WINE_BIN" ]; then
  if   [ -x "$ENGINE_DIR/wine/bin/wine64" ]; then WINE_BIN="wine64"
  elif [ -x "$ENGINE_DIR/wine/bin/wine" ];   then WINE_BIN="wine"
  else echo "error: no wine/wine64 loader under $ENGINE_DIR/wine/bin" >&2; exit 1; fi
fi
echo "Engine id: $ID   loader: $WINE_BIN   version: $VERSION"

# ---- package ---------------------------------------------------------------
# Tar the wine/ tree with a top-level 'wine/' directory so EngineManager's
# findWineRoot locates bin/<loader> after extraction. xz keeps the asset small.
OUT_DIR="$REPO/dist"
mkdir -p "$OUT_DIR"
TARBALL="$OUT_DIR/openxe-engine-${ID}.tar.xz"
echo "Packaging -> $TARBALL (this can take a few minutes for a ~1.7 GB engine)..."
rm -f "$TARBALL"
# -C so the archive root is 'wine/...'; deterministic-ish ordering not required.
tar -cJf "$TARBALL" -C "$ENGINE_DIR" wine

# ---- checksum --------------------------------------------------------------
SHA="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
SIZE_BYTES="$(stat -f%z "$TARBALL")"
SIZE_HUMAN="$(du -h "$TARBALL" | awk '{print $1}')"
ASSET_URL="${RELEASE_URL_BASE}/openxe-engine-${ID}.tar.xz"

echo ""
echo "==================== PACKAGED ENGINE ===================="
echo "Tarball : $TARBALL"
echo "Size    : $SIZE_HUMAN ($SIZE_BYTES bytes)"
echo "SHA-256 : $SHA"
echo "Asset   : $ASSET_URL   (upload the tarball here as a Release asset)"
echo "========================================================"
echo ""
echo "1) Create a GitHub Release on this repo and upload the tarball above as an asset."
echo "2) Add this descriptor to EngineCatalog (Sources/OpenXECore/EngineManager.swift)"
echo "   and, if it should be the first-run engine, set it as .default:"
echo ""
cat <<SWIFT
    public static let prebuilt = EngineDescriptor(
        id: "${ID}",
        displayName: "${DISPLAY}",
        version: "${VERSION}",
        url: URL(string: "${ASSET_URL}")!,
        sha256: "${SHA}",
        wineBinaryName: "${WINE_BIN}")
SWIFT
echo ""
echo "JSON form (for reference / installLocalArchive tooling):"
cat > "$OUT_DIR/openxe-engine-${ID}.descriptor.json" <<JSON
{
  "id" : "${ID}",
  "displayName" : "${DISPLAY}",
  "version" : "${VERSION}",
  "url" : "${ASSET_URL}",
  "sha256" : "${SHA}",
  "wineBinaryName" : "${WINE_BIN}"
}
JSON
cat "$OUT_DIR/openxe-engine-${ID}.descriptor.json"
echo ""
echo "Wrote descriptor to: $OUT_DIR/openxe-engine-${ID}.descriptor.json"
echo "See docs/distribution.md for the full hosting + LGPL-compliance flow."
