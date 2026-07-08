# OpenXE

**Run Windows `.exe` productivity software on macOS by double-clicking it.**

OpenXE is a lean (~0.5 MB) macOS app that registers itself as the system handler
for `.exe` files. Double-click a Windows program in Finder and it runs — through
an unmodified [Wine](https://www.winehq.org/) engine that OpenXE downloads and
manages for you. There is no library window, no launcher grid, no menu-bar item.
It is faceless by design: it does one thing, weighs almost nothing, and stays out
of your way.

> **Status:** working for its first real target. New World Scheduler (NWS) 8.1 and
> 8.2 launch and run under software rendering, with per-app settings and font
> handling in place. GPU/maps acceleration is planned but not yet built — see
> [Current status](#current-status) and [`docs/roadmap.md`](docs/roadmap.md).

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
prefix* — and strips it to the essential: **double-click an `.exe`, it runs.**
No library to curate, no bottles to configure by hand, no gaming stack. It is the
simplest possible way to run NWS (and apps like it) on a Mac, and it is free and
open source.

## Current status

**Works today**

- Double-click an `.exe` in Finder → it launches via OpenXE (LaunchServices
  handler for `com.microsoft.windows-executable`).
- First-run engine setup with a visible progress window; checksum-verified,
  resumable download; no manual Wine compilation required.
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

The app bundle stays under a **5 MB budget**; the ~1.7 GB Wine engine lives outside
the bundle and does not count against it.

### The Rosetta 2 hedge (honest risk)

The current engine is **x86_64-only** and needs **Rosetta 2** on Apple Silicon.
Apple has signaled Rosetta 2 retirement in **macOS 28 (fall 2027)**. That is a real
risk to any x86_64 Wine runner. OpenXE's mitigation is architectural, not wishful:
the engine directory is **versioned and swappable**, so an arm64-native Wine build
(from upstream Wine's ARM work or a future community build) drops in behind the same
`engine/current` symlink without touching the rest of the app. We do not pretend to
have solved this — we designed so that solving it later is a drop-in, not a rewrite.

## Quickstart

**Just want to run it?** See [`INSTALL.md`](INSTALL.md) — download the app, clear the
Gatekeeper quarantine, and double-click an `.exe`. First run downloads the engine
(~1.7 GB, one time).

**Building from source:**

```sh
git clone <this-repo> openxe && cd openxe
make app        # swift build (release) + ad-hoc sign + install to /Applications
```

Then double-click any `.exe` in Finder. If another app currently owns `.exe` files,
Get Info on any `.exe` → *Open With* → OpenXE → *Change All*.

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
