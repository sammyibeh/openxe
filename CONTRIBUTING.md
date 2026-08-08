# Contributing to OpenXE

Thanks for your interest. OpenXE is a small, deliberately lean project — a native
macOS runner over an unmodified Wine subprocess. Contributions that keep it **small,
correct, and dependency-free** are exactly what we want. This guide covers building
from source, the architecture, and how to add support for a new app.

By participating you agree to the [Code of Conduct](CODE_OF_CONDUCT.md).

---

## Guiding principles

Before adding anything, ask: **"What breaks if we don't build this?"** If the answer
is "nothing," it probably shouldn't ship. Specifically:

- **Stay tiny.** The app bundle has a **hard 5 MB budget** (`build-app.sh` fails the
  build if it's exceeded). The Wine engine lives outside the bundle.
- **Zero third-party Swift dependencies.** System frameworks (Foundation, AppKit,
  SwiftUI, CryptoKit) only. A new dependency needs an explicit, written justification.
- **Wine stays at arm's length.** It is an *unmodified external subprocess*, never
  linked or patched. This keeps the app MIT while respecting Wine's LGPL. Do not
  copy code from GPL-licensed projects (e.g. Whisky) — study architecture only.
- **Faceless scope.** Double-click an `.exe` and it runs, plus one small settings
  window. No library UI, no gaming/DirectX stack, no auto-update framework.
- **Spec, then code.** Non-trivial changes start with a short design note. The v1
  design spec lives at
  [`docs/design/specs/2026-07-06-openxe-design.md`](docs/design/specs/2026-07-06-openxe-design.md)
  and is the source of truth; update it in the same PR when behavior changes.

## Development environment

- **macOS 14+** (developed through macOS 27), Apple Silicon or Intel.
- **Xcode Command Line Tools** (`xcode-select --install`) — provides Swift 6 and the
  toolchain. No Xcode project; OpenXE builds with SwiftPM from the command line.
- **Rosetta 2** on Apple Silicon (to actually run the x86_64 Wine engine). **Not
  needed on Intel** — the engine runs natively there. Support matrix and verification
  status: [`docs/platform-support.md`](docs/platform-support.md).
- For building the Wine engine from source (optional): **Homebrew** and ~10–15 GB of
  free disk (see below).

## Build and run

Everything runs through the `Makefile` (thin wrappers over the `scripts/`):

```sh
make            # help
make build      # swift build -c release  (compile only)
make test       # swift test  (unit + gated integration tests)
make app        # build + ad-hoc sign + install OpenXE.app to /Applications
make package-app # build + wrap into a drag-to-install dist/OpenXE.dmg
make clean      # remove the SwiftPM .build directory and dist/
```

`make package-app` runs [`scripts/package-app.sh`](scripts/package-app.sh), which
calls `build-app.sh --no-install` (so packaging never replaces your installed copy,
and there is only one definition of how the bundle is assembled), lays the app out
beside an `/Applications` symlink, builds a compressed `.dmg` with `hdiutil`, ad-hoc
signs the image, and then **mounts what it just produced** to verify the app inside is
universal, its signature is intact, the symlink resolves, and the image detaches
cleanly. The 5 MB budget is enforced on the **app bundle**; the image size is reported
but not gated.

The `.dmg` is not a Gatekeeper workaround — it does not help there at all. It exists
to make dragging the app into `Applications` the obvious gesture, which avoids App
Translocation. See [`docs/platform-support.md`](docs/platform-support.md) §4.2.

`make app` runs [`scripts/build-app.sh`](scripts/build-app.sh), which:

1. `swift build -c release`,
2. generates the app icons (programmatically, via `scripts/make-icon.swift` — never
   checked in),
3. assembles `dist/OpenXE.app`, copies in the bundled `FontAwesome.ttf`,
4. **ad-hoc signs** it (`codesign -s -`) — no notarization,
5. **fails the build if the bundle exceeds 5 MB**,
6. installs to `/Applications` (or `~/Applications`) and registers with
   LaunchServices.

> Some behavior (window focus, Dock identity, the Accessibility prompt) must be
> verified through the **built `.app`**, not `swift run` — a terminal-launched
> process would attribute macOS permission prompts to the terminal, not OpenXE.

After `make app`, double-click any `.exe`. See the manual
[smoke checklist](docs/smoke-checklist.md) before calling a build done.

## The Wine engine

Two ways to get an engine; both end at the same `engine/current` contract.

### Downloaded (default, what end users get)

`EngineManager` downloads a prebuilt engine, verifies its SHA-256, and installs it
into `~/Library/Application Support/OpenXE/engine/<id>/`. The download source (URL +
checksum + wine loader binary name) is a plain `EngineDescriptor` value, so pointing
at a different prebuilt engine — including a **GitHub Release asset on this repo** —
is a data change, not a code change. See
[`Sources/OpenXECore/EngineManager.swift`](Sources/OpenXECore/EngineManager.swift)
and `EngineCatalog`.

### Built from source (LGPL compliance path)

[`scripts/build-engine.sh`](scripts/build-engine.sh) builds a **Wine-Crossover**
engine from CodeWeavers' **LGPL source** for Apple Silicon and stages it into the
OpenXE engine layout. This is the reproducible-from-source path that satisfies LGPL:
the engine is unmodified upstream source that *you* own the build of.

```sh
scripts/build-engine.sh --deps     # install/verify Homebrew build deps only
scripts/build-engine.sh --verify   # fetch + checksum + confirm Rosetta thunks, then stop
scripts/build-engine.sh            # full build (needs ~10-15 GB free working space)
```

It **refuses to start below a disk threshold** rather than fail halfway. Once built,
package it for distribution:

```sh
make package-engine                # tar the staged engine + compute its SHA-256
```

`make package-engine` runs [`scripts/package-engine.sh`](scripts/package-engine.sh),
which produces a distributable `.tar.xz` and prints a ready-to-paste
`EngineDescriptor` (URL + checksum) for hosting the engine as a Release asset. See
[`docs/distribution.md`](docs/distribution.md) for the intended hosting flow.

## Module map

```
Sources/
  OpenXECore/            # the engine logic — pure, testable, no AppKit
    EngineManager.swift    # download / verify / install / select the Wine engine
    PrefixManager.swift    # the one persistent Wine prefix; Mono/Gecko; folder links
    FontProvisioning.swift # expose macOS fonts + substitution table to Wine
    Runner.swift           # spawn wine, warm wineserver, per-exe Dock identity
    AppConfig.swift        # per-app Windows version + DLL overrides (shared prefix)
    PEParser.swift         # PE-header parsing: reject incompatible binaries pre-launch
    PEResources.swift      # extract an exe's icon (RT_GROUP_ICON → .icns)
    LauncherManager.swift  # generate per-exe launcher .apps for Spotlight/Launchpad
    Subprocess.swift       # thin Process wrapper (env, pipes, timeout)
    Paths.swift            # the filesystem contract + Wine environment construction
  OpenXE/                # the AppKit/SwiftUI shell (thin, UI only)
    main.swift, AppDelegate.swift, ProgressWindow.swift, SettingsWindow.swift,
    AppConfigWindow.swift, WindowActivation.swift
Tests/OpenXECoreTests/   # unit tests + one gated end-to-end test
scripts/                 # build-app.sh, package-app.sh, build-engine.sh,
                         # package-engine.sh, reset-fresh.sh, make-icon.swift
docs/                    # design spec, smoke checklist, roadmap, distribution notes
```

Logic lives in `OpenXECore` and is unit-tested without a UI. The `OpenXE` target is a
thin AppKit shell.

## Testing

```sh
make test        # swift test
```

- **Unit tests** cover PE parsing, environment construction, per-app config
  round-tripping, engine descriptor handling, and PE icon-resource extraction.
- **One integration test** runs a tiny known `.exe` end-to-end; it is **gated** on a
  real installed engine so CI without an engine still passes.
- **Manual smoke checklist:** [`docs/smoke-checklist.md`](docs/smoke-checklist.md).
  Run it before merging anything that touches launch behavior.

New code ships with tests alongside it. Keep the integration test green.

## Adding support for a new app

Most apps need no code — they either run or they don't. When one needs help:

1. **Try it first.** Double-click the `.exe`. If it's rejected pre-launch, the PE
   parser will say why (32-bit vs 64-bit, .NET, ARM-only). File that verbatim.
2. **Per-app settings before code.** Many compatibility issues are a **Windows
   version** or a **DLL override** away — set them in *Settings → Per-App Settings…*
   (persisted per-`.exe` in the shared prefix via Wine's `AppDefaults`). Prefer this
   over patching the app.
3. **Fonts.** If text is missing or the app crashes in text layout, the fix is
   usually a **substitution** in `FontProvisioning.swift` (map the missing Windows
   family to a macOS face), not bundling a font. Only bundle a font macOS genuinely
   lacks, and only if it's redistributable.
4. **Engine.** If the app needs an engine capability the default lacks (e.g.
   `--with-gnutls` for networked TLS, or a GPU stack), that's an **engine build**
   change in `build-engine.sh` — document the incident in the design spec's Risks
   section, as prior investigations do.
5. **Record what you found** — a short note in the spec's Risks/§8 style (what you
   tried, what worked, what the evidence was) is worth more than a code change with
   no context.

## Pull requests and issues

- **Issues:** use the templates. For bugs, always include **which app**, **which
  macOS version**, and the **relevant `wine.log` tail** (`~/Library/Logs/OpenXE/`).
- **PRs:** small and focused. Explain *what breaks if we don't build this*. Update
  the design spec and, if launch behavior changed, the smoke checklist. Make sure
  `make test` passes and the 5 MB bundle budget still holds.
- **Commit history:** clear, self-contained commits with descriptive messages. The
  existing history is a good model (what changed, why, and the evidence).
- **Licensing:** contributions are under **MIT**. Don't add code copied from
  GPL-licensed projects, and don't link or modify Wine.

## Coding norms

- Swift 6, `swift-tools-version:6.0`; concurrency-correct (`Sendable` where it
  matters — see the existing `EngineManager`/`Subprocess`).
- Prefer the standard library and system frameworks. No new dependencies.
- Comment the *why*, not the *what* — the existing files explain the non-obvious
  Wine/macOS interactions at the call site, which is where that knowledge is useful.
- Keep pure logic in `OpenXECore`; keep `OpenXE` a thin shell.
