# OpenXE

**Run New World Scheduler on macOS — a purpose-built, open-source appliance.**

> **Unofficial.** OpenXE is an independent, open-source project. It is **not
> affiliated with, endorsed by, or connected to New World Scheduler or
> [nwscheduler.com](https://nwscheduler.com/)**. New World Scheduler is downloaded
> at runtime directly from its official release and remains subject to its own
> license and [terms](https://nwscheduler.com/terms-and-conditions/); OpenXE never
> bundles, mirrors, or redistributes it.

OpenXE is a lean (~0.5 MB) macOS app built for one job: getting **New World
Scheduler (NWS)** — a Windows-only program — running on a Mac. On first launch a
guided wizard prepares a managed, unmodified [Wine](https://www.winehq.org/)
environment and downloads NWS from its official source; after that, NWS opens like
a native app. OpenXE is **not a general Wine front-end**: no library window, no
launcher grid, no gaming stack. It does register as the macOS handler for `.exe`
files, so other Windows productivity programs can run through it too — but NWS is
the target it is built, tuned, and tested for.

> **Status:** working end-to-end. The first-run wizard downloads the engine and
> installs New World Scheduler 8.1/8.2, which runs under software rendering, with
> per-app settings and font handling in place. GPU/maps acceleration is planned
> but not yet built — see [Current status](#current-status) and
> [`docs/roadmap.md`](docs/roadmap.md).

---

## Why OpenXE exists

Some Windows productivity apps have **no native macOS version and never will**.
The motivating case is **New World Scheduler (NWS)** — a scheduling tool with no
Mac build. The options for running it on a Mac are:

- **A full VM** (Parallels/VMware + a Windows license) — heavy, slow to start,
  a whole second OS to maintain.
- **CrossOver** — good, but commercial, and more app than most people need for a
  single program.
- **Whisky / other Wine front-ends** — game-focused, with library UIs and DirectX
  stacks that are irrelevant to a scheduling app.

OpenXE takes the CrossOver idea — *a thin, native runner over a managed Wine
prefix* — and strips it to one appliance: **a few guided clicks and NWS runs.**
No library to curate, no bottles to configure by hand, no gaming stack. It is the
simplest possible way to run NWS on a Mac, and it is free and open source. The
engine itself follows the same idea: OpenXE builds its own Wine-Crossover engine
from CodeWeavers' published LGPL sources (see
[Engine from source](#engine-from-source)), rather than depending on a commercial
product.

## Current status

**Works today**

- **Guided first-run setup wizard** — welcome/disclaimer → one-time Windows
  environment setup (engine download, checksum-verified and resumable) → NWS
  download & install → an explicit launch-or-finish choice. Plain language
  throughout; the user never needs to know what "Wine" or a "prefix" is.
- **NWS fetcher** — downloads the NWS installer at runtime from the vendor's
  official GitHub release (with the vendor's own endpoint as fallback),
  size-verified against the release API, version-pinnable, run once and then
  removed. NWS is never bundled, mirrored, or redistributed.
- Double-click an `.exe` in Finder → it launches via OpenXE (LaunchServices
  handler for `com.microsoft.windows-executable`).
- One persistent Wine prefix (durable registry + `C:` drive), Wine Mono + Gecko,
  Retina/HiDPI mode, Mac `Documents`/`Downloads`/`Desktop` linked into Windows.
- **New World Scheduler 8.1 and 8.2** launch and run their main scheduler UI under
  software rendering, verified end-to-end (survives driven clicks + keystrokes with
  zero crash signatures).
- **Per-app settings** in the shared prefix — Windows version and DLL overrides per
  `.exe` (CrossOver-style, without multiplying prefixes).
- **Font handling** — macOS system fonts are exposed to Wine, with a broad
  substitution table (Segoe UI, Office ClearType fonts, Win8+ icon fonts) so a
  missing font degrades gracefully instead of crashing WPF text layout. The one
  font macOS lacks (FontAwesome) is bundled.
- **Native Dock identity** — a launched Windows program shows its **own** icon and
  name in the Dock and app switcher, not a generic "wine" tile. Per-`.exe`
  launcher apps appear in Spotlight/Launchpad.
- **Multi-engine, swappable engine** — install engines side-by-side and select the
  active one; the prefix rebuilds safely on a switch.

**Work in progress / not yet built**

- **GPU / maps acceleration.** NWS's secondary map/3D view needs a Vulkan/Metal
  path (MoltenVK + DXVK or DXMT). OpenXE ships no GPU backend today, so WPF is
  forced to its software render tier. The main UI is fully usable; the map view is
  the open item. Tracked in [`docs/roadmap.md`](docs/roadmap.md).
- **Networked Windows-side TLS** (activation/update/sync over schannel) — the
  default engine is built `--without-gnutls`; local licensing works, networked
  crypto features need a `--with-gnutls` engine rebuild.

## Architecture

OpenXE is a **faceless native app** wrapping a **swappable Wine subprocess**. Four
components, one persistent prefix:

```
  Finder double-click on foo.exe
            │  (LaunchServices → OpenXE is the .exe handler)
            ▼
  ┌───────────────────────────────────────────────┐
  │  OpenXE.app  (~0.5 MB, MIT, LSUIElement)        │
  │                                                 │
  │  EngineManager ── downloads / verifies / swaps  │──► engine/current ─┐
  │  PrefixManager ── one durable Wine prefix       │──► prefix/         │
  │  Runner        ── spawns wine, warm wineserver  │                    │
  │  Shell (UI)    ── first-run progress + settings │                    ▼
  └───────────────────────────────────────────────┘         Wine (LGPL, unmodified
                                                              external subprocess)
```

- **EngineManager** — first-run download of a prebuilt Wine engine into
  `~/Library/Application Support/OpenXE/engine/`. Checksum-verified, resumable,
  versioned, and swappable. A future arm64-native Wine build drops in behind the
  same `engine/current` contract (see the Rosetta note below).
- **PrefixManager** — one persistent Wine prefix: the durable memory (registry,
  `C:` drive). Installs Wine Mono + Gecko, links your Mac folders into the Windows
  profile, enables Retina mode, provisions fonts.
- **Runner** — spawns `wine` with the correct environment, keeps `wineserver` warm
  for near-instant repeat launches, and gives each program its own Dock identity.
- **Shell** — first-run progress window, a small settings window, per-app settings,
  and error alerts with log access. Nothing more.
- **Per-app config** — Windows version + DLL overrides per `.exe`, persisted in the
  shared prefix using Wine's native `AppDefaults` mechanism (no separate bottles).

The app bundle stays under a **5 MB budget**; the Wine engine lives outside the
bundle and does not count against it.

### Engine from source

OpenXE owns its engine story instead of depending on a commercial build:

- `make engine` ([`scripts/build-engine.sh`](scripts/build-engine.sh)) builds a
  **Wine-Crossover engine from CodeWeavers' published LGPL sources** — x86_64,
  new-WoW64, productivity-focused (no gaming stack), with the CX-bundled freetype
  compiled x86_64 so font rendering works on Apple Silicon build machines. Needs
  ~10–15 GB of working space.
- `make package-engine` ([`scripts/package-engine.sh`](scripts/package-engine.sh))
  tars a built engine, computes its SHA-256, and prints a ready-to-paste
  `EngineDescriptor` for hosting it as a release asset.

Until the self-built engine asset is hosted, first-run installs the pinned,
checksum-verified stock build in `EngineCatalog` — the wizard flow is identical
either way. Details: [`docs/distribution.md`](docs/distribution.md).

### The Rosetta 2 hedge (honest risk)

The current engine is **x86_64-only** and needs **Rosetta 2** on Apple Silicon.
Apple has signaled Rosetta 2 retirement in **macOS 28 (fall 2027)**. That is a real
risk to any x86_64 Wine runner. OpenXE's mitigation is architectural, not wishful:
the engine directory is **versioned and swappable**, so an arm64-native Wine build
(from upstream Wine's ARM work or a future community build) drops in behind the same
`engine/current` symlink without touching the rest of the app. We do not pretend to
have solved this — we designed so that solving it later is a drop-in, not a rewrite.

## Quickstart

**Just want to run it?** See [`INSTALL.md`](INSTALL.md) — download the app, clear
the Gatekeeper quarantine, and open it. The setup wizard takes it from there:
one-time engine download (~1.7 GB), then NWS download and install, then launch.

**Building from source:**

```sh
git clone <this-repo> openxe && cd openxe
make app        # swift build (release) + ad-hoc sign + install to /Applications
```

Then open OpenXE.app and follow the wizard. Any other `.exe` also runs by
double-clicking it in Finder; if another app currently owns `.exe` files,
Get Info on any `.exe` → *Open With* → OpenXE → *Change All*.

**Developer tooling** (`make help` for the full list):

```sh
make test            # unit + gated integration tests
make engine          # build the Wine-Crossover engine from LGPL source
make package-engine  # tarball + SHA-256 + EngineDescriptor for a built engine
make fresh           # wipe all OpenXE state back to a true first-run
```

`make fresh` (scripts/reset-fresh.sh) reproduces the fresh-device experience at
will: it removes the engine, prefix (including the NWS install), generated
launchers, the defaults domain, and logs — never your real `Documents`/`Downloads`/
`Desktop`. Flags go through `ARGS` (quote to pass several):
`make fresh ARGS="--dry-run"` previews, `--yes` skips the prompt, and
`--quarantine /path/to/OpenXE.app` re-arms Gatekeeper on that copy so the next
open shows the genuine first-open prompt.

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the full developer setup, the module
map, how the engine is built from source, and how to add support for a new app.

## Licensing at a glance

- **OpenXE** (this app): **MIT** — see [`LICENSE`](LICENSE).
- **Wine** engine: **LGPL**, used strictly as an unmodified external subprocess,
  never linked or modified. Corresponding-source and provenance details are in
  [`THIRD-PARTY.md`](THIRD-PARTY.md).
- **FontAwesome** (bundled icon font): **OFL 1.1**. See [`THIRD-PARTY.md`](THIRD-PARTY.md).

## Contributing

Contributors are welcome — see [`CONTRIBUTING.md`](CONTRIBUTING.md) and our
[`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md). Good first areas: testing more Windows
apps and filing what works / what doesn't, improving the font substitution table,
and the GPU/maps stack in [`docs/roadmap.md`](docs/roadmap.md).
</invoke>
