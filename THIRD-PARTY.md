# Third-Party Software and Licenses

OpenXE itself is licensed under the **MIT License** (see [`LICENSE`](LICENSE)). This
document records the third-party software OpenXE relies on or bundles, their
licenses, and — for the LGPL Wine engine — how to obtain the corresponding source.

The short version of OpenXE's licensing posture: **the app is MIT; Wine is kept at
arm's length as an unmodified external subprocess and is never linked, patched, or
statically combined with OpenXE.** That separation is what lets an MIT app run an
LGPL engine cleanly.

---

## 1. Wine / Wine-Crossover engine — LGPL 2.1+

**What it is.** OpenXE runs Windows programs through [Wine](https://www.winehq.org/),
which OpenXE downloads and manages but never modifies. Wine is licensed under the
**GNU Lesser General Public License, version 2.1 or later (LGPL-2.1-or-later)**.

**How OpenXE uses it (the arm's-length boundary).** OpenXE invokes the Wine loader
(`wine` / `wine64`) and `wineserver` as **separate external processes** via
`posix_spawn`/`Process`. OpenXE does **not** link against any Wine library, does
**not** modify Wine source, and does **not** distribute Wine inside the OpenXE app
bundle. The engine is downloaded at first run into
`~/Library/Application Support/OpenXE/engine/` and lives entirely outside the app.
Under these conditions OpenXE and Wine are separate works that merely communicate at
runtime; the LGPL obligations attach to the Wine engine, which is distributed
unmodified.

**Provenance of the engines.**

- **Default (downloaded) engine — Gcenx Wine builds.** The stock engine is a
  prebuilt macOS Wine from the
  [Gcenx/macOS_Wine_builds](https://github.com/Gcenx/macOS_Wine_builds) project,
  itself built from upstream WineHQ LGPL source. OpenXE pins a specific release and
  its SHA-256.

- **Wine-Crossover engine — built from CodeWeavers' LGPL source.**
  [`scripts/build-engine.sh`](scripts/build-engine.sh) builds an engine from
  **CodeWeavers CrossOver source** (`crossover-sources-<version>.tar.gz`, published by
  CodeWeavers). The **Wine portions of CrossOver are LGPL**; OpenXE builds them
  **unmodified** and owns only the build, not any patch. The script pins the source
  URL and SHA-256, and confirms provenance before building. This is the
  reproducible-from-source path.

**How to obtain the corresponding source (LGPL compliance).**

- Upstream WineHQ source: <https://gitlab.winehq.org/wine/wine> and
  <https://dl.winehq.org/wine/source/>.
- Gcenx build recipes: <https://github.com/Gcenx/macOS_Wine_builds>.
- CrossOver source tarballs (LGPL Wine portions):
  <https://www.codeweavers.com/crossover/source> (the exact pinned URL and version
  are recorded in [`scripts/build-engine.sh`](scripts/build-engine.sh)).
- The build recipe OpenXE uses to produce its engine from that source is
  [`scripts/build-engine.sh`](scripts/build-engine.sh) in this repository.

Because OpenXE ships **no** Wine binaries in its own release and downloads an
unmodified engine, LGPL compliance is satisfied by (a) not modifying Wine, (b)
keeping it an external subprocess, and (c) pointing to the corresponding upstream
source above. If a future OpenXE release *hosts* a prebuilt engine (e.g. as a GitHub
Release asset), that release will link to the exact corresponding source and build
recipe alongside the binary.

## 2. Wine Mono and Wine Gecko

Installed into the Wine prefix to support .NET and embedded-browser apps. These are
distributed by the Wine project under their respective licenses (Wine Mono: MIT and
others; Wine Gecko: MPL and others, tracking Mozilla). They are installed into the
prefix at setup time, unmodified, and are not part of the OpenXE app bundle.

## 3. FontAwesome (bundled font) — SIL Open Font License 1.1

OpenXE bundles **FontAwesome** (`Resources/FontAwesome.ttf`, ~165 KB) — the one icon
font macOS does not ship — because some WPF apps reference it and wine-mono crashes in
text layout when it resolves to nothing. FontAwesome's font files are licensed under
the **SIL Open Font License, Version 1.1 (OFL-1.1)**, which permits bundling and
redistribution. See <https://fontawesome.com/license/free> and
<https://scripts.sil.org/OFL>. All other fonts OpenXE uses come from the host macOS
system via Wine's Mac font driver and are **not** bundled or redistributed.

## 4. Apple system frameworks

OpenXE uses only Apple's system frameworks (Foundation, AppKit, SwiftUI, CryptoKit,
CoreGraphics/ImageIO for icon generation). These are part of macOS and are used under
Apple's SDK terms; they are not redistributed by OpenXE.

## 5. What OpenXE does NOT include

- No third-party Swift packages. OpenXE has **zero** external Swift dependencies.
- No code copied or adapted from GPL-licensed projects (e.g. Whisky) — architecture
  was studied, code was written independently.
- No modified Wine, and no Wine binaries inside the OpenXE app bundle.

---

*If you believe any attribution here is incomplete or incorrect, please open an issue
— we want this right.*
