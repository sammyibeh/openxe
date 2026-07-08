# OpenXE — Design Specification

**Date:** 2026-07-06 · **Author:** Kai Sørensen · **Status:** Approved design, formalized. Governs v1 implementation.

## 1. Overview

OpenXE is a lean, personal-use macOS app that runs Windows `.exe` productivity software via Wine. It is faceless: macOS registers it as the handler for `.exe` files, so double-clicking an `.exe` in Finder runs the program. Opening the app directly shows one small settings window. There is no library UI, no menu bar item, and no Dock presence while idle.

- **Deliverable:** `OpenXE.app`, built from Swift with SwiftPM + a shell assembly script (no Xcode project).
- **Budget:** app bundle ≤ 5 MB (the Wine engine lives outside the bundle and does not count).
- **License:** MIT. Wine remains an unmodified subprocess (LGPL at arm's length).
- **Target machine:** Apple Silicon or Intel; macOS 14+. On Apple Silicon the x86_64 Wine engine requires Rosetta 2.

## 2. Goals / Non-Goals

**Goals**

1. Double-click an `.exe` in Finder → it runs. First run performs one-time setup with visible progress.
2. Persistent Windows environment: registry, `C:` drive, and user profile survive across launches (single durable Wine prefix).
3. `.NET` and embedded-browser apps work fully (Wine Mono + Gecko present in the prefix).
4. Repeat launches are near-instant (warm `wineserver`); a session's first launch cold-boots in seconds.
5. Failures explain themselves: incompatible binaries are diagnosed before launch; crashes surface the Wine log.
6. Engine is versioned and swappable: a future arm64-native Wine build drops in without touching other components.

**Non-Goals** — see §10 (out of scope for v1). Notably: no gaming/DirectX stack, no multiple prefixes, no library UI, no notarization, no auto-update. §9 records a user-directed scope addition (app icon, /Applications install, per-exe launchers).

## 3. Architecture

One app, four components, each independently testable. Dependencies point downward only.

```
Shell (AppKit UI: first-run progress, settings, alerts)
  └─ Orchestrator (open-file event → setup-if-needed → launch)
       ├─ EngineManager   ~/Library/Application Support/OpenXE/engine/
       ├─ PrefixManager   ~/Library/Application Support/OpenXE/prefix/
       └─ Runner          wine / wineserver subprocesses; PEParser gate
```

- **Code layout:** `Sources/OpenXECore` (library: EngineManager, PrefixManager, Runner, PEParser — no AppKit) and `Sources/OpenXE` (executable: Shell + app lifecycle). Tests target `OpenXECore`.
- **Packaging:** `scripts/build-app.sh` runs `swift build -c release`, assembles `OpenXE.app` (binary + `Info.plist` + generated icons, §9.1), ad-hoc signs (`codesign -s -`), installs to /Applications (§9.2), and registers the installed copy with LaunchServices (`lsregister -f`).
- **Info.plist essentials:** `LSUIElement = true`; `CFBundleDocumentTypes` claims extension `exe` (content type `com.microsoft.windows-executable`, imported UTI declaration included) with `LSHandlerRank = Owner`; bundle ID `dev.openxe.OpenXE`; min system 14.0. OpenXE does not force itself as default handler; the build script registers the claim, and if another handler owns `.exe` the user assigns OpenXE via Finder's Get Info → Open With → Change All.
- **Filesystem contract:**
  - `…/OpenXE/engine/<version>/wine/{bin,lib,share}` — one directory per engine version
  - `…/OpenXE/engine/current` — symlink to the active version (the swap point)
  - `…/OpenXE/prefix/` — the single Wine prefix (`WINEPREFIX`)
  - `~/Library/Logs/OpenXE/wine.log` — session-appended Wine output

## 4. Components

### 4.1 EngineManager

**Responsibility:** acquire, verify, install *multiple* engines, and select the active one. Nothing else touches `engine/`.

**Multi-engine model (spec extension, 2026-07-07).** OpenXE supports more than one installed engine so a CrossOver-derived engine can run apps that stock Wine cannot (see §8), while stock remains the default.

- **Engine descriptor** — an engine is described by `EngineDescriptor { id, displayName, version, url, sha256, wineBinaryName }`. The download source (URL + checksum) and the **wine loader binary name** are parameters, not hardcoded: the stock Gcenx build's loader is `wine` (new-WoW64), a CrossOver build's is `wine64`. This is why Runner/PrefixManager resolve the loader through `EngineManager.activeWineBinary`, never a fixed `bin/wine`.
- **On-disk layout** — `engine/<id>/wine/{bin,lib,share}`, `engine/<id>/descriptor.json` (self-describing), `engine/current` → `<id>` (the active pointer). `installedEngineIDs()` enumerates every fully-installed engine.
- **Install alongside, then select** — `install(_:progress:)` (or `installLocalArchive(_:archive:)` for a pre-built/from-source engine) unpacks into `engine/<id>/` and records the descriptor **without** disturbing the active engine (the first engine installed is auto-activated as a convenience). `setActive(_:)` repoints `engine/current` and returns whether the engine actually changed.
- **Engine change ⇒ prefix rebuild** — a Wine prefix is bound to its engine (Wine does not support prefix downgrades). Switching engines therefore invalidates the prefix: the readiness marker records the building engine's id, `PrefixManager.isReady` is true only when it matches the active engine, and `ensurePrefix()` wipes a mismatched prefix before rebuilding. The settings picker performs the switch and resets the environment so the next launch rebuilds cleanly.
- **Global, not per-app (decision + justification).** The active engine is a single global setting, not a per-app override. Rationale: the charter mandates **one** persistent prefix (the durable memory), and a prefix is 1:1 with an engine; a per-app engine would force a per-app prefix, breaking the single-prefix model and multiplying the ~1 GB footprint per app. The user's must-run app (NWS Desktop) is served by flipping the whole environment to the CrossOver engine with one prefix — leaner and matches the charter. Per-app engines/bottles remain out of scope (§10).
- **Engine-agnostic layout discovery** — extraction finds the wine root by locating `bin/<wineBinaryName>` at any depth (`findWineRoot`), handling both Gcenx (`*.app/Contents/Resources/wine`) and CrossOver-style (top-level dir) archives; `tar -xf` auto-detects xz/gz.

**Default engine — pinned Gcenx build (verified against the live GitHub release on 2026-07-06):**

- Repo: `https://github.com/Gcenx/macOS_Wine_builds`
- Release tag: `11.0_1` (Wine 11.0 stable)
- Asset: `wine-stable-11.0_1-osx64.tar.xz`, 185,303,032 bytes
- URL: `https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.0_1/wine-stable-11.0_1-osx64.tar.xz`
- Tarball layout (verified): top level is `Wine Stable.app/`; the Unix tree is at `Contents/Resources/wine/`.
- The release bundles shared Wine Mono 10.4.1 and Wine Gecko 2.47.4 inside the package (stated in the release notes) — Wine auto-installs them into new prefixes; no separate download.
- **Assumption (upstream publishes no checksum):** the SHA-256 for this asset is computed by us once at pin time and hardcoded next to the pinned URL. Pin-time value (computed 2026-07-06 from the downloaded asset, size verified byte-exact): `b50dc50ec7f41d58b115a6b685d4d1315ba3c797bd3aa0f49213f2703cb82388`. It anchors integrity of what *we* validated, not an upstream attestation. If the maintainer ever replaces the asset in place, the checksum mismatch will (correctly) refuse the download.

**Behavior:**

1. `isInstalled` — `engine/current/wine/bin/wine` exists and the version marker matches.
2. `install(progress:)` — download via `URLSession` with HTTP Range resume against a persisted partial file (survives crashes, not just graceful cancels; GitHub supports range requests); verify SHA-256 (CryptoKit); on mismatch delete and retry once, then fail. Extract with `/usr/bin/tar -xJf` into a temp directory; keep only the `Contents/Resources/wine` subtree as `engine/<version>/wine/`; strip quarantine attributes so Gatekeeper does not block the unsigned Wine binaries — the strip is **engine-agnostic** (`stripQuarantine(at:)` runs on any unpacked engine directory, not just the pinned build) and must `chmod -R u+w` first because some engine tarballs (CrossOver-derived builds, verified live) unpack read-only, where `xattr -d` fails silently; atomically move into place and point `current` at it.
3. `version` — read from the version marker for display in settings.

**Swappability contract:** other components resolve every Wine path through `EngineManager.activeWineBinary` / `activeWineserverBinary` (i.e., via `engine/current` + the active descriptor's loader name). A future arm64 engine — or the self-built Wine-Crossover engine (§8) — is a new `engine/<id>/wine/` directory plus a repointed symlink and a rebuilt prefix; no other component changes.

**Dependencies:** Foundation, CryptoKit, `/usr/bin/tar`, `/usr/bin/xattr`, `/bin/chmod`.

### 4.2 PrefixManager

**Responsibility:** create and maintain the single persistent prefix — the durable memory. Nothing else writes to `prefix/` metadata.

**Behavior (`ensurePrefix()` — idempotent, keyed on a ready-marker file):**

1. Initialize: run `wineboot --init` (via the engine's `wine`) with `WINEPREFIX` set. The bundled shared Mono/Gecko auto-install during boot.
2. Verify Mono and Gecko. The bundled builds install them as *shared* — used in place from the engine's `share/wine/{mono,gecko}` and registered into the prefix, never copied to `drive_c/windows/mono` (verified empirically on the real prefix). Checks: the prefix registry (`system.reg`) must contain the Wine Mono registration, and `drive_c/windows/system32/gecko/` must exist non-empty; if either fails, fail setup with an explicit error — do not mark the prefix ready. (".NET and embedded-browser apps work fully" is a hard requirement; a silently degraded prefix is worse than a failed setup.)
3. Retina rendering: `wine reg add "HKCU\Software\Wine\Mac Driver" /v RetinaMode /t REG_SZ /d y /f` and `wine reg add "HKCU\Control Panel\Desktop" /v LogPixels /t REG_DWORD /d 192 /f`.
3a. **Font provisioning — generalized (best-effort — never blocks readiness; generalized 2026-07-08 from the 2026-07-07 NWS fix).** A missing font must NEVER crash an app; it must degrade to a close available face. What began as an NWS-specific fix is now a reusable base applied to every prefix as pre-setup (the first app to run in any prefix, and every future rebuilt prefix, inherits it). Implemented in `FontProvisioning` (Core, data-driven + unit-tested) and applied by `PrefixManager.provisionFonts`.
   - **Base fonts — provided by macOS, deliberately NOT bundled or winetricks-fetched (lean decision).** The Wine Mac driver auto-registers macOS's own copies of the Microsoft *corefonts* into every prefix — Arial, Times New Roman, Courier New, Verdana, Georgia, Trebuchet MS, Comic Sans MS, Impact, Tahoma, Webdings, Wingdings — from `/System/Library/Fonts/Supplemental`. **Verified 2026-07-08:** the real prefix has 394 registered font entries pointing at `Z:\System\Library\Fonts\Supplemental\*.ttf`, every corefont among them. Bundling corefonts (or `winetricks corefonts`) would duplicate ~10 MB already present and add a dependency the host does not have (no winetricks installed). So OpenXE installs exactly **one** font file macOS lacks: the bundled `FontAwesome.ttf` (OFL-1.1, `Resources/FontAwesome.ttf`, ~165 KB), an icon font wine-mono cannot load from an app's embedded resources; a system-installed copy resolves it by family-name fallback.
   - **Fallback substitution layer — the generalization.** Every common Windows family that macOS does *not* provide is mapped to a close macOS-registered face, in BOTH the GDI `FontSubstitutes` table (which wine-mono reads for WPF) and wine's `Software\Wine\Fonts\Replacements`: WPF/shell `Segoe UI` + its weight/symbol variants → Verdana/Arial; the Office ClearType families `Calibri`/`Cambria`/`Cambria Math`/`Candara`/`Consolas`/`Constantia`/`Corbel` → Arial/Georgia/Verdana/Courier New; Win8+ icon fonts `Segoe MDL2 Assets`/`Segoe Fluent Icons`/`Marlett` → Webdings; plus a handful of other legacy faces. Targets are always resolvable because they are macOS Supplemental fonts. This is what keeps a missing default font from NULL-dereferencing wine-mono's WPF text layout (`MS.Internal.TextFormatting.LineServicesCallbacks.InlineFormat` / `FontFaceLayoutInfo`). **Verified 2026-07-07** (NWS survives 70 s of driven interaction — 40 clicks + 120 keystrokes — with zero typography exceptions); **generalized substitutions verified 2026-07-08** by writing and reg-querying the Office-font keys (`Calibri→Arial`, `Cambria→Georgia`, `Consolas→Courier New`, `Segoe MDL2 Assets→Webdings`) live in the real prefix.
3b. **Software-rendering default (best-effort; 2026-07-08, see §8 graphics finding).** OpenXE ships no GPU stack (no MoltenVK/DXVK), so WPF's hardware render tier drives the Mac GL/Vulkan path and logs `GL_INVALID_FRAMEBUFFER_OPERATION` / failed `vulkan_init`. Prefix setup writes `HKCU\Software\Microsoft\Avalon.Graphics\DisableHWAcceleration=1` (DWORD) to force WPF onto its software render tier, keeping GPU-leaning apps on a path that actually works here (a map/3D view degrades; the main UI renders). **Verified 2026-07-08:** the key is written and reg-queryable, and NWS 8.1 still launches and stays alive with it set (zero crash/typography/graphics signatures — no regression). A per-app override (§4.6) can re-enable hardware acceleration.
4. Folder linking (**best-effort — MUST NEVER abort `ensurePrefix`**): replace `drive_c/users/<profile>/{Documents,Downloads,Desktop}` (freshly created, empty) with symlinks to the Mac's real `~/Documents`, `~/Downloads`, `~/Desktop`. The Windows profile directory name is engine-dependent — **CrossOver's `wineboot` creates `users/crossover`, Gcenx uses the unix user name** — so link into whatever real profiles `wineboot` actually created (all of `users/` except `Public`/dotfiles), not a hardcoded `NSUserName()`. **Data-loss regression fixed 2026-07-08:** the previous code assumed `users/NSUserName()`; under the CrossOver engine that directory does not exist, so `createSymbolicLink` threw and `ensurePrefix` aborted *before* step 5. The marker was never written, `isReady` stayed false, and the **next** launch wiped and rebuilt the prefix — destroying every installed Windows app on each open. Each link is now `try?` (a link failure is cosmetic; the marker is what matters).
5. Write the ready marker (contains creating engine version).

**Reset:** settings action shuts down `wineserver`, deletes `prefix/` after a confirmation alert that states data loss plainly, and clears the ready marker. Next launch rebuilds.

**Dependencies:** EngineManager (wine binary path), Foundation.

### 4.3 Runner

**Responsibility:** launch Windows programs; own the subprocess environment and the `wineserver` lifecycle.

**Environment construction (pure function, unit-tested):** given engine root + prefix path, produce exactly

- `WINEPREFIX` = prefix path
- `PATH` = `<engine>/wine/bin` prepended to a minimal system `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`)
- `WINEDEBUG` = `fixme-all` (errors still logged; fixme noise suppressed)
- `DYLD_FALLBACK_LIBRARY_PATH` = `<engine>/wine/lib:/usr/lib:/usr/local/lib` — **load-bearing.** The CrossOver engine (§8) bundles `libfreetype.6.dylib` in `<engine>/wine/lib`, and `win32u` `dlopen`s it by bare soname; without `<engine>/wine/lib` on the dyld search path the bundled freetype is not found at load time, and WPF/.NET apps FailFast at startup (`TypefaceMap → NullFontFamily`). Fallback (not `DYLD_LIBRARY_PATH`) so it never shadows a system library. Verified 2026-07-07: the prior env with no dyld path failed freetype 6/6; adding this path fixed single-process apps 0/6.

**Behavior:**

1. **Gate:** parse the PE header first (§4.5). Refuse-with-explanation happens here, before any process spawns.
2. **Warm server:** ensure a persistent `wineserver -p` is running for the prefix (start it if absent). It outlives individual programs, making repeat launches near-instant. Settings' "Shut Down Windows Environment" runs `wineserver -k`.
3. **Launch:** spawn wine on `<exe>` via `Process`, working directory = the exe's directory, stdout+stderr appended to `~/Library/Logs/OpenXE/wine.log` under a timestamped session header. Wine is never modified, wrapped, or linked — subprocess only. To give the program a real Dock identity (§9.5) the executable is the engine's unix wine loader *symlinked inside a per-exe `.app`* rather than `bin/wine`, with `WINELOADER` set to that symlink so child processes inherit the identity; if the wrapper cannot be built it falls back to `<engine>/wine/bin/wine` — the icon is never a launch blocker.
4. **Crash detection:** if the wine process exits nonzero within 15 seconds of spawn, raise the crash alert (§6) with the log tail. After 15 seconds the program is considered launched; OpenXE does not babysit it.

**Dependencies:** EngineManager, PrefixManager (paths only), PEParser, Foundation.

### 4.4 Shell (UI)

**Responsibility:** the only component that touches AppKit. Three surfaces, nothing more:

1. **First-run progress window** — "Setting up your Windows environment — one time, ~200 MB download." Determinate bar for download, indeterminate for extraction and prefix boot. Shown only when setup work is actually pending.
2. **Settings window** (shown when the app is opened with no document): engine version display, *Open C: Drive in Finder*, *Shut Down Windows Environment*, *Reset Environment* (confirmed destructive action), plus *Remove Generated Launchers* (§9.3).
3. **Error alerts** — every user-facing failure is an `NSAlert` with a plain-language explanation and, where a Wine log exists, a *Show Log* button (opens the log in Finder/Console).

App lifecycle: `LSUIElement` accessory app; activates only to show a window or alert; terminates once the Runner's 15-second launch watch completes without a crash (the wine subprocess and wineserver are independent processes and keep running — `wineserver -p` persists by design). Open-file Apple Events (`application(_:open:)`) queue the exe, run setup if needed, then hand to Runner.

**Dependencies:** AppKit + all three core components (orchestration only; no business logic in the Shell).

### 4.5 PEParser (inside OpenXECore, used by Runner)

Reads the first bytes of the file: DOS `MZ` magic → `e_lfanew` at offset 0x3C → `PE\0\0` signature → COFF machine field → optional-header magic (PE32/PE32+) → CLR data-directory presence (.NET). Classifies: `win32` (i386), `win64` (x86_64), `dotNET`, `armWindows` (ARM/ARM64 machine types), `dos16`, `notPE`. Runner launches `win32`/`win64`/`dotNET`; everything else gets a specific plain-language refusal (e.g., "This is a Windows-on-ARM program; OpenXE's engine runs x86 Windows programs only").

### 4.6 Per-app configuration — "bottle-lean" (2026-07-08)

**Responsibility:** deliver CrossOver-style per-app settings — a per-app Windows version and per-app DLL overrides — WITHOUT the cost of separate prefixes.

**Architecture decision (the tradeoff).** True CrossOver bottles are separate prefixes; some Wine settings are genuinely prefix-global. OpenXE's charter mandates **one** persistent prefix (the durable memory), and a prefix is 1:1 with an engine (§4.1). Two options were weighed:

- **(a) Per-app config applied to the shared prefix at launch** — chosen.
- **(b) Lightweight per-app prefixes** — rejected for v1: multiplies the ~1 GB footprint per app, forces a Mono/Gecko install per bottle, and reopens the engine-per-prefix binding — disproportionate to the ask.

Option (a) is not a compromise for the two settings the user actually wants, because **Wine already supports both per-application, inside a single prefix**:

- **Windows version** — written to Wine's native `HKCU\Software\Wine\AppDefaults\<exe>\Version` key (the exact mechanism winecfg's *Applications* tab uses). Wine reads it per-process keyed by the running exe's file name. **Verified 2026-07-08:** with `AppDefaults\cmd.exe\Version=winxp`, `cmd /c ver` reports *Microsoft Windows 5.1.2600*; flipped to `win10` it reports *Microsoft Windows 10.0.19045* — same prefix, per-app version, honored by Wine.
- **DLL overrides** — carried in the per-launch `WINEDLLOVERRIDES` env var (native/builtin/order/disabled per DLL). Nothing persists in the prefix; the override applies only to that launch.

What is genuinely prefix-global (and therefore **not** made per-app): the active **engine** (1:1 with the single prefix — kept global per §4.1's decision) and the `DisableHWAcceleration` default (§4.2 3b, a prefix-wide registry value). Surfacing a per-app *engine* would mislead — it would silently require a per-app prefix — so it is deliberately omitted. This is the honest lean line: per-app **Windows version + DLL overrides** delivered; per-app engine/bottle still out of scope (§10).

**Data model (`AppConfig`, Core, `Codable`, unit-tested).** `{ exePath (identity key), windowsVersion: default|winxp|win7|win10|win11, dllOverrides: [{dll, mode: native|builtin|nativeBuiltin|builtinNative|disabled}], environment: [String:String] }`. Persisted by `AppConfigStore` as one JSON dictionary (`…/OpenXE/appconfigs.json`) keyed by exe path; an all-default config is pruned (no clutter). `WINEDLLOVERRIDES` string and its parser round-trip (`dll=n,b;dll2=b;dll3=`), both unit-tested.

**Apply at launch (`Runner.launch`).** Before spawning: `applyWindowsVersion` writes (or, for Default, clears) the `AppDefaults\<exe>\Version` key; `WineEnvironment.buildLaunch` overlays `WINEDLLOVERRIDES` and any per-app env onto the base env — with `WINEPREFIX`/`PATH`/`DYLD_FALLBACK_LIBRARY_PATH` locked so a per-app env can never break engine resolution. A nil/all-default config yields exactly the base env (regression-guarded by test).

**UI (`AppConfigWindow`, Shell).** Reached from Settings → *Per-App Settings…*. Minimal and native: pick a known app (union of generated-launcher targets and existing configs), set Windows version (popup) and DLL overrides (text field, e.g. `d3d11=n,b; dxgi=b`), Save. No business logic in the Shell — it edits `AppConfig` and calls `AppConfigStore`.

**Dependencies:** Foundation (Core), AppKit (UI). No new third-party dependency.

## 5. Data Flow — double-click an `.exe`

1. Finder → LaunchServices → OpenXE receives open-file event.
2. Rosetta check (Apple Silicon only): if `arch -x86_64 /usr/bin/true` fails, prompt to install (§6) and stop.
3. EngineManager: installed? If not → progress window → download, verify, unpack.
4. PrefixManager: ready? If not → boot prefix, verify Mono/Gecko, apply registry + symlinks.
5. Runner: PE-parse the exe → refuse-with-reason or spawn under warm wineserver.
6. Shell: on early nonzero exit, crash alert with log tail; otherwise OpenXE quits, program runs on.

Steps 3–4 run at most once per environment lifetime; the steady-state path is 1 → 2 → 5 → 6.

## 6. Error Handling

| Failure | Behavior |
|---|---|
| Engine download interrupted | HTTP-Range resume from the persisted partial file on the next attempt; progress window reflects partial completion |
| Checksum mismatch | Delete artifact, one automatic re-download, then a loud failure alert; the next launch attempt starts setup again |
| Rosetta 2 absent (Apple Silicon) | Alert explaining the requirement with an *Install Rosetta* button that runs `softwareupdate --install-rosetta --agree-to-license` and reports the result |
| Incompatible binary | PEParser verdict shown pre-launch in plain language (ARM Windows, 16-bit DOS, not a Windows program) — never a silent failure |
| Program crashes at launch (nonzero exit < 15 s) | Alert with the last 40 lines of `wine.log` summarized and a *Show Log* button |
| Mono/Gecko verification fails | Setup fails loudly with a *Show Log* button; prefix is not marked ready |

## 7. Testing Strategy

- **Unit (fast, no network):**
  - PEParser against synthesized in-memory fixtures: valid PE32, PE32+, .NET CLR, ARM64 machine type, MZ-only DOS stub, non-MZ garbage, truncated file.
  - Runner environment construction: exact `WINEPREFIX`/`PATH`/`WINEDEBUG` output for given inputs.
- **Integration (one test, gated behind `OPENXE_E2E=1`):** end-to-end through OpenXECore — install the real engine (download + checksum + unpack), build the prefix, then run a tiny known `.exe` and assert on its output. The known exe is the engine's own `cmd.exe` (a genuine PE binary shipped inside Wine): `wine cmd /c echo openxe-e2e-ok`, asserting the marker appears on stdout. No fabricated fixtures, no network beyond the pinned URL.
- **Manual smoke checklist** (kept in `docs/smoke-checklist.md`, run before calling a build done): one installer-based app installs and launches; one .NET app runs; one portable app runs; settings actions work; `.exe` double-click association works from Finder.

## 8. Risks

1. **Rosetta 2 sunset — the big one.** Apple has signaled Rosetta 2 retirement in macOS 28 (fall 2027); this machine is already on macOS 27. The pinned engine is x86_64-only and will stop working on Apple Silicon when Rosetta goes. Mitigation is architectural, not speculative: the engine directory is versioned and swappable (§4.1), so an arm64-native Wine build (Wine upstream's arm64ec/ARM work, or a future Gcenx arm64 build) drops in behind the same `engine/current` contract. v1 does not attempt to source an arm64 engine — none is pinned or verified today.
2. **Upstream release availability.** The pinned asset is a personal GitHub release with no published checksum and no mirror. Acceptable for personal use; our own pinned SHA-256 (§4.1) converts "asset silently changed" into a hard, visible failure.
3. **GStreamer not installed.** Upstream lists `GStreamer.framework` as a requirement; it exists for media playback inside Windows apps. OpenXE v1 does not install it — core productivity functionality works without it, but audio/video features inside Windows apps may be degraded. Explicit accepted limitation; revisit only if a smoke-test app needs it.
4. **Wine app compatibility is inherently probabilistic.** Some productivity apps will not run under any Wine. The mitigation is honest failure: PE gating and log-bearing crash alerts, never silent death.
5. **macOS 27 is a beta-era OS (build 26A5368g).** Wine/Rosetta behavior on it is less battle-tested than on release macOS. The integration test on this exact machine is the canary.
6. **32-bit WoW64 SEH is broken in hack-free Wine 11 builds under Rosetta — root cause confirmed (incident, 2026-07-06/07).** The pinned `wine-stable-11.0_1` is Gcenx's rebuild with the CodeWeavers hacks removed. **Confirmed root cause (source-verified):** stock Wine lacks CrossOver's Rosetta-2 signal-handling thunks — specifically `use_rosetta2_workaround` in `dlls/wow64cpu/cpu.c` (which uses `lretq` instead of `ljmp` on the 32→64 syscall thunk to dodge a SIGUSR1 race) and the `is_rosetta2` SEH/mxcsr fixups in `dlls/ntdll/unix/signal_x86_64.c` (CW Hack 24256). Without them, exception-heavy 32-bit code under Rosetta faults with `err:virtual:virtual_setup_exception nested exception on signal stack` inside wow64cpu.dll. Reproduced 5/5 on stock 11.0 and on Gcenx devel 11.10 (`Exception frame is not in stack limits => unable to dispatch exception` — same class); WineHQ bugs 59511/58197 open, unfixed through 11.10. Basic 32-bit programs are fine (notepad, stock Inno Setup 6.1/7.0 installers verified); the failure is path-dependent — verified failing: the NWS Desktop installer (Inno Setup 6.1.0; its payload app `NWS Desktop.exe` is hard-locked 32-bit — CorFlags 32BITREQUIRED, native i386 libSkiaSharp). A CrossOver-derived engine (WhiskyWine 0.2.3.3, wine-7.7) runs the failing installer past the crash into GUI init (0 crash signatures vs deterministic crash on stock).

   **Resolution: build a Wine-Crossover engine from CodeWeavers' LGPL source (`scripts/build-engine.sh`).** Source `crossover-sources-26.2.0.tar.gz` (Wine 11.0-based → prefix-compatible with stock; the thunks are grep-verified present in this tree). This is the trustworthy engine — unmodified LGPL source we own the build of, no unofficial mirror. It installs as a selectable engine ("Wine-Crossover (self-built)") via the multi-engine model (§4.1); the user switches to it globally for NWS, and the prefix rebuilds on the switch. The app stays MIT; the engine stays an unmodified subprocess. Engine downgrades require a prefix rebuild (Wine does not support downgrades) — handled automatically.

   **Open blocker (2026-07-07):** the from-source compile needs ~6–10 GB free working space; this machine has ~5.7 GB free (228 GB volume at 98% full). `build-engine.sh` is authored, dependency-bootstrap wired, and the wow64cpu-thunk grep-gate in place, but it **refuses to start** below the disk threshold rather than fail halfway. The compile is pending free disk. Mechanism is proven end-to-end on the WhiskyWine test article (install → activate → per-engine `wine64` loader resolves → Runner runs it → prefix-rebuild-on-switch).

7. **FreeType is REQUIRED in the engine — startup font FailFast (incident + fix, 2026-07-07).** A `--without-freetype` CrossOver engine makes the NWS Desktop WPF/.NET app FailFast-crash at startup with `TypefaceMap → NullFontFamily`, before any window is created. **Fix:** the engine is built `--with-freetype`; CrossOver's source bundles its own freetype, compiled x86_64 and installed to `<engine>/wine/lib/libfreetype.6.dylib` (no Homebrew freetype needed — the earlier "can't build freetype on Apple Silicon" note assumed Homebrew's arm64 dylib and was wrong). `build-engine.sh` now pins `--with-freetype`. **Runtime half of the fix:** `win32u` `dlopen`s the bare soname, so the Runner must expose `<engine>/wine/lib` via `DYLD_FALLBACK_LIBRARY_PATH` (§4.3) — the engine build flag alone is not sufficient; the launcher env is the other half. **Verified 2026-07-07:** with both halves, NWS clears the FailFast and its main scheduler window renders on screen (CGWindowList: a foreground 1280×718 layer-0 window owned by the wine PID; Screen Recording was not granted so pixel capture was unavailable, window metadata is the evidence).

   **Remaining NWS blocker — RESOLVED 2026-07-07 (font fix, see §4.2 step 3a).** After the main window renders, NWS deterministically terminated on a *different* fault than the FailFast — a NULL/range fault in WPF-under-wine-mono's text layout during `TextBlock.Measure` (`MS.Internal.TextFormatting.LineServicesCallbacks.InlineFormat` this pass; `MS.Internal.FontCache.FontFaceLayoutInfo.ComputeTypographyAvailabilities` an earlier pass — same wine-mono `PresentationFramework` text-layout bug class, reproduced 3/3). **Root cause:** it is *not* the OpenType parser choking on a malformed font (installing genuine Microsoft corefonts in place of the macOS-registered ones did **not** help — disproven this pass); it is wine-mono NULL-dereferencing when a requested font resolves to nothing — WPF's default *Segoe UI* (no substitute) and the app's *embedded* FontAwesome (which wine-mono fails to load). **Fix:** register Segoe-UI/icon-font substitutions and install a system `FontAwesome.ttf` (§4.2 step 3a). The earlier "cannot find the FreeType font library" log line was a **red herring** — an artifact of launching wine through `/usr/bin/nohup`, a SIP-protected binary that strips `DYLD_*`; launched directly (as the Runner does) freetype loads 0 errors. **Verified:** NWS survives 70 s of driven interaction (40 clicks + 120 keystrokes) with zero typography exceptions.

   **GPU map / Vulkan is a separate future scope.** NWS's secondary GPU/map view logs non-fatal `vulkan_init_once` (no `libvulkan.1.dylib`) and `GL_INVALID_FRAMEBUFFER_OPERATION` warnings. These are **not** the cause of either crash above and are explicitly out of scope for the font work; revisit only if the map view becomes a target.

8. **Newer NWS leans harder on hardware rendering — lean fix applied, GPU stack escalation documented (2026-07-08).** A newer NWS build (its older font FailFast is gone — the §4.2/§7 fix holds) fails on graphics: `err:vulkan:vulkan_init_once Failed to load libvulkan.1.dylib`, `err:vulkan:init_vulkan Failed to load Wine graphics driver supporting Vulkan`, and many `err:d3d:wined3d_check_gl_call GL_INVALID_FRAMEBUFFER_OPERATION (0x506) from glClear`.
   - **Confirmed environment facts.** The engine ships `winevulkan.so`/`.dll` but there is **no `libvulkan.1.dylib` (MoltenVK)** anywhere in it — so `vulkan-1` cannot init; and the host loader is **x86_64** (`wineserver` is `Mach-O 64-bit x86_64`, running under Rosetta), so arm64 Homebrew Vulkan/MoltenVK dylibs cannot load into it (confirmed prior). The `glClear`/`GL_INVALID_FRAMEBUFFER_OPERATION` line is wined3d's D3D→OpenGL path hitting the Mac GL driver.
   - **Lean fix (applied, §4.2 3b).** Force WPF software rendering (`Avalon.Graphics\DisableHWAcceleration=1`) prefix-wide, with a per-app re-enable available (§4.6). This removes WPF's own hardware-tier GL usage. **Verified 2026-07-08** it does not regress NWS 8.1 (still launches, zero graphics/crash signatures). The newer NWS binary was **not available in this session**, so whether software rendering alone brings its main scheduler UI up could not be confirmed end-to-end — that verification needs the binary.
   - **Escalation criterion (precise).** `DisableHWAcceleration` only governs WPF's *own* render tier. If the newer NWS's `glClear` errors originate from a **separate D3D/GPU surface** it creates itself (a SkiaSharp GPU backend, or a Direct3D map/scene control) rather than from WPF, software rendering will **not** stop them and that view stays broken. If the newer NWS refuses to show its **main** UI without a working GPU, the real fix is a larger-scope GPU stack: bundle an **x86_64** MoltenVK (`libvulkan.1.dylib` / `libMoltenVK.dylib`, NOT arm64 — the loader is x86_64-under-Rosetta) plus a D3D→Vulkan/Metal translation layer (**DXVK**, or **DXMT/D3DMetal**). That is a deliberate, separate scope decision (footprint, licensing, build), not undertaken here.
   - **bcrypt "no encryption support" — separate potential blocker, flagged.** The many `bcrypt` errors are because the engine is built `--without-gnutls` (intentional, `scripts/build-engine.sh`): no gnutls → no symmetric-cipher/`BCryptEncrypt` and no Windows **schannel** TLS backend. Verified: no `libgnutls*` in the engine, `bcrypt.so` links none. For NWS this is **likely noise** — NWS 8.1 runs and its licensing is a local `.mapsuitelicense` file, and .NET apps typically do TLS via managed `SslStream`, not schannel. But **if** the newer NWS performs licensing/activation or update checks over Windows-side TLS (schannel/bcrypt), that will fail independently of the GPU issue. Resolution if it bites: build the engine `--with-gnutls` (adds an x86_64 gnutls dependency to the from-source build) — a separate engine-build scope item.

## 9. Scope Addition — user-directed, 2026-07-06 (supersedes §10 where they conflict)

Three features added after the base design was approved, in priority order.

### 9.1 App icon
`OpenXE.app` gets a proper `.icns`, generated programmatically — no external assets. `scripts/make-icon.swift` (a build-time script; its AppKit/CoreGraphics use never becomes an app dependency) renders the iconset PNGs and `iconutil` packs `Resources/OpenXE.icns`; `CFBundleIconFile` is wired in Info.plist. The script also renders `Resources/LauncherFallback.icns`, a muted gray variant used by §9.3 when icon extraction fails. `build-app.sh` regenerates both when absent and bundles them.

### 9.2 Install to /Applications
`build-app.sh` installs the signed bundle into `/Applications` (falling back to `~/Applications` when not writable), replacing any previous install, and registers with LaunchServices from the installed location. The `dist/` copy remains a build artifact only.

### 9.4 Window focus (app-scoped Accessibility)
When a program launches, OpenXE brings its window forward. Raising another process's windows needs the macOS **Accessibility** permission, and it is requested by **OpenXE.app itself** — never a parent terminal. `WindowActivation` (Shell) checks `AXIsProcessTrusted()`; on first use, if untrusted, it prompts via `AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt: true])` so the system dialog attributes to OpenXE. It **degrades gracefully**: if the permission is not (yet) granted, focus is skipped and the program still runs — Accessibility never gates launching. `Runner.launch` returns the wine pid so `WindowActivation.activate(pid:)` can raise it via `NSRunningApplication`. Must be verified through the built `.app`, not `swift run` (the latter would attribute the prompt to the terminal). Fuller native per-app identity (Dock/Cmd-Tab as the app, focus-don't-duplicate relaunch, Windows-menu → macOS menu bar) is a follow-up on this foundation.

### 9.3 Per-exe launcher apps
When an `.exe` launches successfully through OpenXE and no launcher for it exists, OpenXE generates a lightweight launcher app so the Windows program appears in Spotlight/Launchpad like a native app.

- **Location:** `/Applications/OpenXE Apps/` (fallback `~/Applications/OpenXE Apps/` when not writable).
- **Bundle contents:** `Info.plist` + a `/bin/sh` stub executable (`exec open -b dev.openxe.OpenXE "<exe path>"`) + `AppIcon.icns`. The `.exe` is referenced by its original path, never copied. The Info.plist carries `OpenXETargetPath` (the exe's absolute path) — this key marks a bundle as OpenXE-generated and is the identity check for "already exists and points to the same path" (pointing elsewhere means regenerate).
- **Naming:** the exe's VS_VERSIONINFO `ProductName` when present, else the filename stem; sanitized for the filesystem. Name collisions between different exes resolve by suffixing ` 2`, ` 3`, ….
- **Icon:** new core parser `PEResources` maps RVAs through the section table and walks the resource directory (`RT_GROUP_ICON` → `RT_ICON`), takes the first icon group, picks its best entry (largest pixel size, then highest bit depth; width byte 0 = 256 px), and rebuilds a valid `.ico` in memory. Both PNG-compressed and BMP/DIB entries are carried through. ImageIO decodes the `.ico`, the needed sizes are rendered out, `iconutil` packs the `.icns`. Any failure at any stage falls back to the bundled `LauncherFallback.icns` — icon extraction is never a launch blocker.
- **Signing/registration:** each launcher is ad-hoc signed (`codesign -s -`) and registered with LaunchServices on creation.
- **Removal:** settings gains *Remove Generated Launchers*, which deletes only bundles carrying `OpenXETargetPath`, in both the primary and fallback locations.
- **Testing:** unit tests over synthesized PE resource fixtures (PNG entry, DIB entry, best-entry selection, `ProductName`, no-resources); the e2e test additionally generates a launcher (into a temporary directory) from a real Wine-shipped exe and asserts bundle structure, target path, icon presence, and a valid ad-hoc signature.

### 9.5 Dock identity — per-exe icon-wrapper `.app` (2026-07-07)
Running a Windows program presented a generic Wine icon and process name in the Dock, because wine runs as a bare executable (`lsappinfo`: `bundle path = NULL`) so macOS has no bundle icon to show. The Runner now launches each program through a per-exe icon-wrapper bundle so the Dock shows the program's **own icon and name**.

- **Mechanism.** The CrossOver Mac driver (`winemac.so`) sets the application icon via `[[NSBundle mainBundle] …]` + `setApplicationIconImage:`, reading `exeIcon.icns` from the running process's main bundle. Giving the wine loader a main bundle therefore gives the app a Dock icon. macOS also uses the bundle's `CFBundleIconFile`/`CFBundleName` for the Dock tile directly.
- **Bundle (built + cached by the Runner under `…/OpenXE/AppBundles/<pathDigest>.app`):** `Contents/MacOS/<AppName>` is a **symlink to `engine/current/wine/lib/wine/x86_64-unix/wine`** (the unix loader) — so it follows engine swaps for free and a stale wrapper (pointing at a prior engine, or carrying a prior name) is rebuilt; `Contents/Resources/exeIcon.icns` is the icon extracted from the exe (reusing §9.3's `PEResources`/`IconBuilder`; omitted on failure — never a blocker); `Contents/Info.plist` carries `CFBundleName`/`CFBundleDisplayName` (the exe's `ProductName`, else its file-name stem), `CFBundleIdentifier`, `CFBundleExecutable = <AppName>`, `CFBundleIconFile = exeIcon`. No copy of the loader, no sibling `.so` copies, no code-signing needed — the symlinked loader resolves its siblings through the engine path, and macOS still associates the bundle.
- **The loader file is named after the program, not `wine`** (2026-07-08). The Dock/menu-bar identity of a wine-exec'd process falls back to the executable's file name (`argv[0]` / `NSProcessInfo.processName`) on any surface that can't read the bundle — naming the `CFBundleExecutable` `wine` is exactly what leaves "wine" reachable. `Runner.sanitizedExecutableName` derives a file-name-safe form (keeps spaces; `/` and `:` and control chars → space; collapsed, trimmed, length-capped, never empty, never accidentally `wine`). Verified empirically that the modern CrossOver loader does **not** require `argv[0] == "wine"` — it launches correctly under the app name.
- **Launch:** `Runner.launch` execs `…/<digest>.app/Contents/MacOS/<AppName> <exe>` with `WINELOADER` pointing at that symlink so the spawned `NWS Desktop.exe` child inherits the bundle identity.
- **Verified 2026-07-08** end-to-end through the shipping `Runner` (Screen Recording not granted, so identity read via `lsappinfo` + `CGWindowListCopyWindowInfo`'s `kCGWindowOwnerName` — the strings the Dock/WindowServer actually render). The wrapped `NWS Desktop.exe` process is `type="Foreground"` with `lsappinfo` name `"NW Scheduler"`, `bundleID=dev.openxe.app.<digest>`, and `kCGWindowOwnerName="NW Scheduler"` on its app window — i.e. the Dock tile shows the program name. The only process still named `"wine"` is the shared `explorer.exe /desktop` helper, which is `type="BackgroundOnly"` and gets **no** Dock tile.

## 10. Out of Scope (v1 — binding)

- DirectX/gaming stack (DXVK, MoltenVK tuning, game controllers) — see §8 for the newer-NWS GPU escalation criterion
- Multiple prefixes / bottles as separate WINEPREFIXes, and per-app **engine** selection (per-app Windows version + DLL overrides ARE delivered in-prefix via §4.6; separate-prefix bottles and per-app engines remain out of scope)
- Library UI, menu bar item, Dock presence while idle
- `.msi` special-casing (installers run only if the vendor ships an `.exe`)
- Notarization, distribution, auto-update (ad-hoc signing only; the swappable engine is the only update surface)
- GStreamer.framework installation
- Any third-party Swift dependency (system frameworks only)
