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
# Pinned 2026-07-07 from the live download (149,047,436 bytes, last-modified
# 2026-06-09); CodeWeavers publishes no checksum, so this is our own pin.
CX_SHA256="3846ae094dd49c073467bb2b5e6e17d5bacaebcfab4b6dd2af3f132c64cad6cf"

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
# Lean profile for productivity apps (verified sufficient for the NWS Desktop
# .NET/SkiaSharp target): PE toolchain + fonts + TLS + CoreAudio. Vulkan/
# gstreamer/sdl are dropped to cut dep install, disk, and build time — winemac
# OpenGL covers SkiaSharp rendering; add them back if a target needs media.
BREW_DEPS=(
  bison mingw-w64 pkgconf              # PE-side cross toolchain + parser + pkgconfig
  molten-vk vulkan-loader              # CrossOver win32u/vulkan.c needs SONAME_LIBVULKAN
                                       # even in a productivity build (TU is unconditional)
)
# NOTE: gnutls is intentionally NOT installed (TLS inside Windows apps is
# degraded but unused by the NWS target; arm64 Homebrew gnutls can't link into
# the x86_64 build and x86_64 Homebrew needs sudo). freetype, by contrast, IS
# enabled and REQUIRED — no Homebrew freetype needed: the CrossOver source tree
# bundles its own freetype, which this build compiles as x86_64 and installs to
# <engine>/wine/lib/libfreetype.6.dylib (verified present in the shipped engine).
# WHY REQUIRED (incident 2026-07-07; §8): a --without-freetype engine makes the
# NWS Desktop WPF/.NET app FailFast-crash at startup (TypefaceMap ->
# NullFontFamily), before any window. Building --with-freetype removes that
# crash and the main scheduler window renders. (A separate, downstream WPF
# typography bug remains — see §8 — but that is NOT the startup FailFast.)
# RUNTIME REQUIREMENT: win32u dlopens the bare soname "libfreetype.6.dylib", so
# the launching environment MUST put <engine>/wine/lib on the dyld search path
# (the Runner sets DYLD_FALLBACK_LIBRARY_PATH — spec §4.3); otherwise the bundled
# dylib is not found at load time even though it ships inside the engine.
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

  # Gotchas verified on THIS machine (M2, macOS 27 beta, CLT clang 17):
  #  - brew bison MUST precede macOS's ancient bison 2.3.
  #  - The wineloader must be x86_64 so Rosetta 2 can execute the x86 Windows
  #    code inside it (an arm64 loader cannot run x86 PE code). Force the
  #    compiler to x86_64 with CC="clang -arch x86_64" — `arch -x86_64` and
  #    `-m64` alone do NOT switch Apple clang off arm64 (it keeps defining
  #    __arm64__, and the SDK then pulls BOTH i386 and arm _OSByteOrder.h,
  #    breaking the host makedep build).
  #  - CRUCIAL: also pass --build/--host=x86_64-apple-darwin. Without it,
  #    configure detects the native arm64 host and injects -D__aarch64__ into
  #    the host-tool CFLAGS; combined with the x86_64 compiler, winnt.h then
  #    compiles BOTH the AMD64 and ARM64 CONTEXT typedefs -> redefinition error
  #    in tools/widl/metadata.c.
  #  - CrossOver's dlls/win32u/vulkan.c references SONAME_LIBVULKAN
  #    UNCONDITIONALLY, so even a productivity build needs it defined. The
  #    x86_64 build can't link-test the arm64 Homebrew libvulkan, so set the
  #    soname explicitly via ac_cv_lib_soname_vulkan (Wine's documented
  #    override) rather than relying on autodetection.
  #  - hash -r flushes zsh's cached tool paths before configure.
  export PATH="$(brew --prefix bison)/bin:$PATH"
  hash -r

  # 64-bit host WITH 32-bit WoW64 (Wine 11 new-WoW64). --enable-archs=i386,x86_64
  # builds the PE-side wow64cpu.dll carrying the Rosetta thunks. The deprecated
  # --enable-win32on64 two-pass path is NOT used. Productivity-only: no
  # DXMT/D3DMetal. --with-freetype (REQUIRED, §8) / --without-gnutls: see the
  # BREW_DEPS note.
  ( cd "$build" && "$wine_src/configure" -C \
      CC="clang -arch x86_64" CXX="clang++ -arch x86_64" \
      ac_cv_lib_soname_vulkan="libvulkan.1.dylib" \
      ac_cv_lib_soname_MoltenVK="libMoltenVK.dylib" \
      --prefix="$STAGE/wine" \
      --build=x86_64-apple-darwin --host=x86_64-apple-darwin \
      --enable-archs=i386,x86_64 \
      --with-mingw \
      --disable-tests \
      --with-coreaudio --with-vulkan \
      --with-freetype --without-gnutls \
      --without-x --without-gstreamer --without-sdl \
      --without-pulse --without-alsa --without-oss \
      --without-usb --without-wayland --without-dbus )
  # Confirm SONAME_LIBVULKAN landed before the long compile.
  grep -q 'define SONAME_LIBVULKAN' "$build/include/config.h" \
    || { echo "error: SONAME_LIBVULKAN not defined; win32u/vulkan.c will fail" >&2; exit 4; }
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
