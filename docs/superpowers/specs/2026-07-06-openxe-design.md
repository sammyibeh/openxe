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

**Responsibility:** acquire, verify, install, and report the Wine engine. Nothing else touches `engine/`.

**Pinned engine (verified against the live GitHub release on 2026-07-06):**

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

**Swappability contract:** other components resolve every Wine path through `EngineManager.binURL` / `libURL` (i.e., via `engine/current`). A future arm64 engine is a new `engine/<version>/wine/` directory plus a repointed symlink — no other component changes.

**Dependencies:** Foundation, CryptoKit, `/usr/bin/tar`, `/usr/bin/xattr`.

### 4.2 PrefixManager

**Responsibility:** create and maintain the single persistent prefix — the durable memory. Nothing else writes to `prefix/` metadata.

**Behavior (`ensurePrefix()` — idempotent, keyed on a ready-marker file):**

1. Initialize: run `wineboot --init` (via the engine's `wine`) with `WINEPREFIX` set. The bundled shared Mono/Gecko auto-install during boot.
2. Verify Mono and Gecko. The bundled builds install them as *shared* — used in place from the engine's `share/wine/{mono,gecko}` and registered into the prefix, never copied to `drive_c/windows/mono` (verified empirically on the real prefix). Checks: the prefix registry (`system.reg`) must contain the Wine Mono registration, and `drive_c/windows/system32/gecko/` must exist non-empty; if either fails, fail setup with an explicit error — do not mark the prefix ready. (".NET and embedded-browser apps work fully" is a hard requirement; a silently degraded prefix is worse than a failed setup.)
3. Retina rendering: `wine reg add "HKCU\Software\Wine\Mac Driver" /v RetinaMode /t REG_SZ /d y /f` and `wine reg add "HKCU\Control Panel\Desktop" /v LogPixels /t REG_DWORD /d 192 /f`.
4. Folder linking: replace `drive_c/users/<user>/{Documents,Downloads,Desktop}` (freshly created, empty) with symlinks to the Mac's real `~/Documents`, `~/Downloads`, `~/Desktop`.
5. Write the ready marker (contains creating engine version).

**Reset:** settings action shuts down `wineserver`, deletes `prefix/` after a confirmation alert that states data loss plainly, and clears the ready marker. Next launch rebuilds.

**Dependencies:** EngineManager (wine binary path), Foundation.

### 4.3 Runner

**Responsibility:** launch Windows programs; own the subprocess environment and the `wineserver` lifecycle.

**Environment construction (pure function, unit-tested):** given engine root + prefix path, produce exactly

- `WINEPREFIX` = prefix path
- `PATH` = `<engine>/wine/bin` prepended to a minimal system `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`)
- `WINEDEBUG` = `fixme-all` (errors still logged; fixme noise suppressed)

**Behavior:**

1. **Gate:** parse the PE header first (§4.5). Refuse-with-explanation happens here, before any process spawns.
2. **Warm server:** ensure a persistent `wineserver -p` is running for the prefix (start it if absent). It outlives individual programs, making repeat launches near-instant. Settings' "Shut Down Windows Environment" runs `wineserver -k`.
3. **Launch:** spawn `<engine>/wine/bin/wine <exe>` via `Process`, working directory = the exe's directory, stdout+stderr appended to `~/Library/Logs/OpenXE/wine.log` under a timestamped session header. Wine is never modified, wrapped, or linked — subprocess only.
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
6. **32-bit WoW64 SEH is broken in hack-free Wine 11 builds under Rosetta (incident, 2026-07-06).** The pinned `wine-stable-11.0_1` is Gcenx's rebuild with the CodeWeavers hacks removed — including the wow64cpu Rosetta 2 thunks (CW patch 20760, stripped April 2026; regression reports in Gcenx/macOS_Wine_builds#160). Exception-heavy 32-bit code paths can die with `err:virtual:virtual_setup_exception nested exception on signal stack`, faulting inside wow64cpu.dll; upstream WineHQ bugs 59511 and 58197 are open and unfixed through Wine 11.10 (verified by test). Basic 32-bit programs work (notepad, stock Inno Setup 6.1/7.0 installers all verified fine); the failure is path-dependent (verified failing: NWS Desktop installer, whose payload app is also hard-locked 32-bit — CorFlags 32BITREQUIRED plus native i386 DLLs). A CrossOver-hacked engine (WhiskyWine 0.2.3.3, wine-7.7-based, unofficial mirror) verifiably runs the failing installer to its UI. No trustworthy, current CW-hacked engine build is published anywhere today, so v1 keeps the stock pin and documents this ceiling; the versioned `engine/current` swap accepts a hacked engine the moment a defensible source exists. Note: engine downgrades require a prefix rebuild (Wine does not support prefix downgrades).

## 9. Scope Addition — user-directed, 2026-07-06 (supersedes §10 where they conflict)

Three features added after the base design was approved, in priority order.

### 9.1 App icon
`OpenXE.app` gets a proper `.icns`, generated programmatically — no external assets. `scripts/make-icon.swift` (a build-time script; its AppKit/CoreGraphics use never becomes an app dependency) renders the iconset PNGs and `iconutil` packs `Resources/OpenXE.icns`; `CFBundleIconFile` is wired in Info.plist. The script also renders `Resources/LauncherFallback.icns`, a muted gray variant used by §9.3 when icon extraction fails. `build-app.sh` regenerates both when absent and bundles them.

### 9.2 Install to /Applications
`build-app.sh` installs the signed bundle into `/Applications` (falling back to `~/Applications` when not writable), replacing any previous install, and registers with LaunchServices from the installed location. The `dist/` copy remains a build artifact only.

### 9.3 Per-exe launcher apps
When an `.exe` launches successfully through OpenXE and no launcher for it exists, OpenXE generates a lightweight launcher app so the Windows program appears in Spotlight/Launchpad like a native app.

- **Location:** `/Applications/OpenXE Apps/` (fallback `~/Applications/OpenXE Apps/` when not writable).
- **Bundle contents:** `Info.plist` + a `/bin/sh` stub executable (`exec open -b dev.openxe.OpenXE "<exe path>"`) + `AppIcon.icns`. The `.exe` is referenced by its original path, never copied. The Info.plist carries `OpenXETargetPath` (the exe's absolute path) — this key marks a bundle as OpenXE-generated and is the identity check for "already exists and points to the same path" (pointing elsewhere means regenerate).
- **Naming:** the exe's VS_VERSIONINFO `ProductName` when present, else the filename stem; sanitized for the filesystem. Name collisions between different exes resolve by suffixing ` 2`, ` 3`, ….
- **Icon:** new core parser `PEResources` maps RVAs through the section table and walks the resource directory (`RT_GROUP_ICON` → `RT_ICON`), takes the first icon group, picks its best entry (largest pixel size, then highest bit depth; width byte 0 = 256 px), and rebuilds a valid `.ico` in memory. Both PNG-compressed and BMP/DIB entries are carried through. ImageIO decodes the `.ico`, the needed sizes are rendered out, `iconutil` packs the `.icns`. Any failure at any stage falls back to the bundled `LauncherFallback.icns` — icon extraction is never a launch blocker.
- **Signing/registration:** each launcher is ad-hoc signed (`codesign -s -`) and registered with LaunchServices on creation.
- **Removal:** settings gains *Remove Generated Launchers*, which deletes only bundles carrying `OpenXETargetPath`, in both the primary and fallback locations.
- **Testing:** unit tests over synthesized PE resource fixtures (PNG entry, DIB entry, best-entry selection, `ProductName`, no-resources); the e2e test additionally generates a launcher (into a temporary directory) from a real Wine-shipped exe and asserts bundle structure, target path, icon presence, and a valid ad-hoc signature.

## 10. Out of Scope (v1 — binding)

- DirectX/gaming stack (DXVK, MoltenVK tuning, game controllers)
- Multiple prefixes / bottles
- Library UI, menu bar item, Dock presence while idle
- `.msi` special-casing (installers run only if the vendor ships an `.exe`)
- Notarization, distribution, auto-update (ad-hoc signing only; the swappable engine is the only update surface)
- GStreamer.framework installation
- Any third-party Swift dependency (system frameworks only)
