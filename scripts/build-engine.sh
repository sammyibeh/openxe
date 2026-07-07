#!/bin/zsh
# build-engine.sh — build a Wine-Crossover engine from CodeWeavers' LGPL
# source, for Apple Silicon (macOS), and stage it into OpenXE's versioned
# engine layout. Spec §8 (the from-source trustworthy engine).
#
# WHY: the stock Gcenx wine-stable build is hack-free and lacks CrossOver's
# wow64cpu/Rosetta signal-handling thunks, so exception-heavy 32-bit code
# (e.g. the NWS Desktop installer) dies with
#   err:virtual:virtual_setup_exception nested exception on signal stack.
# Building CrossOver's own source gives us those thunks with clean provenance:
# unmodified LGPL source that we own the build of. The app stays MIT; the
# engine is an unmodified external subprocess.
#
# STATUS: authored and dependency-bootstrapping is wired; the full compile is
# NOT yet run to completion in this environment — it is blocked on free disk
# (a from-source Wine build needs ~12-15 GB of working space; see the DISK
# CHECK below, which refuses to start rather than fail halfway). Run on a
# machine with adequate free space.
#
# Usage:
#   scripts/build-engine.sh            # full: deps + fetch + verify + build + stage
#   scripts/build-engine.sh --deps     # install/verify Homebrew build deps only
#   scripts/build-engine.sh --verify   # fetch + checksum + confirm wow64cpu thunks, then stop
#
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$PWD"

# ---- pinned source (LGPL) --------------------------------------------------
# CrossOver 26.2.0 is Wine 11.0-based — matching our stock engine's Wine base,
# so an existing prefix stays compatible across a stock<->CW engine switch of
# the same major (a rebuild is still forced for safety; see EngineManager).
CX_VERSION="26.2.0"
CX_TARBALL="crossover-sources-${CX_VERSION}.tar.gz"
CX_URL="https://media.codeweavers.com/pub/crossover/source/${CX_TARBALL}"
# Source facts verified 2026-07-07 (direct HTTP HEAD): 26.2.0 is the newest
# CrossOver source, ~149,047,436 bytes, dated 2026-06-09. CodeWeavers publishes
# NO checksum for these tarballs (.sha256/.sha1/.md5 siblings all 404) — same
# situation as the Gcenx engine. We pin our OWN SHA-256, computed once from the
# download, so "source silently changed" becomes a hard failure. Empty = the
# script computes and prints it, then refuses to build until it is pinned here.
# NOTE: CrossOver 27 (Jun 2026) removes 32-bit bottles — 26.2.0 is the correct
# base for the 32-bit-SEH-under-Rosetta fix, and 27 source is not published yet.
CX_SHA256=""

WORK="${OPENXE_ENGINE_BUILD_DIR:-$HOME/.cache/openxe-engine-build}"
STAGE="$REPO/dist/engine/wine-crossover-${CX_VERSION}"
ENGINE_ID="wine-crossover-self-built-${CX_VERSION}"

# ---- disk guard ------------------------------------------------------------
# A from-source Wine build (150 MB tarball, extracted CrossOver tree bundling
# MoltenVK+DXVK+gstreamer glue, plus a WoW64 object tree) needs ~6-10 GB per
# Morgan's estimate; budget 10 GB to be safe.
REQUIRED_GB=10
avail_gb() { df -g "$1" 2>/dev/null | awk 'NR==2{print $4}'; }
guard_disk() {
  local have; have=$(avail_gb "$HOME")
  echo "Free disk on \$HOME volume: ${have} GB (need >= ${REQUIRED_GB} GB)"
  if [ "${have:-0}" -lt "$REQUIRED_GB" ]; then
    echo "error: not enough free disk to build Wine from source." >&2
    echo "       Free up space or set OPENXE_ENGINE_BUILD_DIR to a larger volume." >&2
    exit 2
  fi
}

# ---- dependency bootstrap --------------------------------------------------
# Documented, re-runnable. Homebrew is the source of truth; nothing silently
# required. Productivity-only — no DXMT/D3DMetal/gaming deps.
# Verified against Morgan's recipe (WineHQ macOS docs + Gcenx + GabLeRoux CI).
BREW_DEPS=(
  bison mingw-w64 pkgconf              # PE-side cross toolchain + parser + pkgconfig
  freetype gnutls                      # core Wine deps
  molten-vk sdl2                       # Vulkan/MoltenVK + input (no D3DMetal/gaming)
  gstreamer gst-plugins-base           # media inside Windows apps
)
# Fallback: if brew mingw-w64 chokes on the 32-bit wow64cpu.dll, switch
# --with-mingw to an llvm-mingw toolchain (what Gcenx/MacPorts use in prod).
bootstrap_deps() {
  command -v brew >/dev/null || { echo "error: Homebrew required (https://brew.sh)"; exit 1; }
  xcode-select -p >/dev/null || { echo "error: Xcode Command Line Tools required"; exit 1; }
  echo "Installing/verifying build deps: ${BREW_DEPS[*]}"
  brew install "${BREW_DEPS[@]}"
  # bison/flex are keg-only; Wine needs the brew ones ahead of the macOS stubs.
  echo "NOTE: prepend keg-only bison/flex to PATH for the build:"
  echo "  export PATH=\"\$(brew --prefix bison)/bin:\$(brew --prefix flex)/bin:\$PATH\""
}

# ---- fetch + verify + confirm the thunks -----------------------------------
fetch_and_verify() {
  mkdir -p "$WORK"
  local tarball="$WORK/$CX_TARBALL"
  if [ ! -f "$tarball" ]; then
    echo "Downloading $CX_URL"
    curl -fSL -o "$tarball" "$CX_URL"
  fi
  if [ -z "$CX_SHA256" ]; then
    echo "error: CX_SHA256 is empty — pin the checksum before building." >&2
    echo "       Computed now: $(shasum -a 256 "$tarball" | awk '{print $1}')" >&2
    exit 1
  fi
  echo "$CX_SHA256  $tarball" | shasum -a 256 -c - || { echo "checksum mismatch" >&2; exit 1; }

  local src="$WORK/crossover-sources-${CX_VERSION}"
  rm -rf "$src"; mkdir -p "$src"
  tar -xf "$tarball" -C "$src"

  # CRITICAL GATE: the whole plan hinges on the Rosetta/wow64cpu thunks being
  # present. Morgan grep-verified them in 26.2.0's lineage; confirm in OUR
  # extracted tree before spending time compiling. CrossOver nests Wine under
  # sources/wine/.
  echo "Confirming wow64cpu / Rosetta thunks are present in the source..."
  local wine_src; wine_src=$(find "$src" -type f -path "*dlls/wow64cpu/cpu.c" | head -1)
  wine_src="$(dirname "$(dirname "$(dirname "$wine_src")")")"  # -> .../wine
  local ok=1
  if grep -q "rosetta2_workaround" "$wine_src/dlls/wow64cpu/cpu.c" 2>/dev/null; then
    echo "  OK: wow64cpu.dll carries use_rosetta2_workaround (lretq/ljmp SIGUSR1 fix)."
  else ok=0; fi
  if grep -qE "is_rosetta2|CW Hack 24256" "$wine_src/dlls/ntdll/unix/signal_x86_64.c" 2>/dev/null; then
    echo "  OK: signal_x86_64.c carries the is_rosetta2 SEH/mxcsr fixups."
  else ok=0; fi
  if [ "$ok" -ne 1 ]; then
    echo "error: the Rosetta wow64cpu thunks are NOT present in CrossOver ${CX_VERSION}." >&2
    echo "       The entire plan depends on them — STOP and report, do not build." >&2
    exit 3
  fi
  echo "$wine_src" > "$WORK/.wine_src_path"
}

# ---- configure + build (new-WoW64, NOT the obsolete --enable-win32on64) ----
build_wine() {
  local wine_src; wine_src=$(cat "$WORK/.wine_src_path")
  local build="$WORK/build"
  rm -rf "$build"; mkdir -p "$build"

  # Gotchas verified by Morgan against a real M2 build:
  #  - brew bison MUST precede macOS's ancient bison 2.3
  #  - MoltenVK dylib soname is not autodetected on macOS -> set it explicitly
  #  - build the host as x86_64 (Wine host must be x86 to run x86 Windows under
  #    Rosetta); the loader must NOT be arm64 or every exe is "zsh: killed"
  #  - hash -r flushes zsh's cached tool paths before configure
  export PATH="$(brew --prefix bison)/bin:$PATH"
  export ac_cv_lib_soname_MoltenVK="$(brew --prefix molten-vk)/lib/libMoltenVK.dylib"
  export CPPFLAGS="-I$(brew --prefix)/include"
  export LDFLAGS="-L$(brew --prefix)/lib"
  hash -r

  # 64-bit host WITH 32-bit WoW64 (Wine 11 new-WoW64). --enable-archs=i386,x86_64
  # is what builds the PE-side wow64cpu.dll carrying the Rosetta thunks. The
  # deprecated --enable-win32on64 two-pass path is NOT used. Productivity-only:
  # no DXMT/D3DMetal.
  ( cd "$build" && "$wine_src/configure" -C \
      --prefix="$STAGE/wine" \
      --build=x86_64-apple-darwin \
      --enable-archs=i386,x86_64 \
      --with-mingw \
      --disable-tests \
      --with-coreaudio --with-vulkan --with-freetype --with-gstreamer \
      --with-sdl --with-gnutls \
      --without-x --without-pulse --without-alsa --without-oss \
      --without-usb --without-wayland )
  ( cd "$build" && make -j"$(sysctl -n hw.ncpu)" )
  ( cd "$build" && make install )
}

# ---- stage into OpenXE engine layout + emit descriptor ---------------------
stage_engine() {
  # EngineManager expects <engineDir>/wine/{bin,lib,share}. `make install`
  # with --prefix="$STAGE/wine" already produced that. Emit the descriptor so
  # the engine is self-describing and selectable as "Wine-Crossover (self-built)".
  local sha; sha="$(shasum -a 256 "$WORK/$CX_TARBALL" | awk '{print $1}')"
  cat > "$STAGE/descriptor.json" <<JSON
{
  "id" : "${ENGINE_ID}",
  "displayName" : "Wine-Crossover ${CX_VERSION} (self-built)",
  "version" : "crossover-${CX_VERSION}",
  "url" : "${CX_URL}",
  "sha256" : "${sha}",
  "wineBinaryName" : "wine64"
}
JSON
  printf 'crossover-%s\n' "$CX_VERSION" > "$STAGE/version"
  chmod -R u+w "$STAGE"; xattr -dr com.apple.quarantine "$STAGE" 2>/dev/null || true
  echo "Staged engine at: $STAGE"
  echo "Install into OpenXE with EngineManager.installLocalArchive or copy the"
  echo "dir into ~/Library/Application Support/OpenXE/engine/${ENGINE_ID}/ and"
  echo "select it in Settings."
}

case "${1:-all}" in
  --deps)   bootstrap_deps ;;
  --verify) fetch_and_verify ;;
  all)      guard_disk; bootstrap_deps; fetch_and_verify; build_wine; stage_engine ;;
  *) echo "usage: build-engine.sh [--deps|--verify]"; exit 1 ;;
esac
