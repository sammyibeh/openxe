# OpenXE — Manual Smoke Checklist

Spec §7. Run before calling a build done. Record date and engine version.

## Setup
- [ ] `scripts/build-app.sh` completes: builds, signs ad-hoc, stays under 5 MB, registers with LaunchServices
- [ ] Fresh state (`make fresh`, i.e. `scripts/reset-fresh.sh` — preview with `make fresh ARGS=--dry-run`): first `.exe` launch shows the one-time setup progress window and completes

## Progress display (HUMAN-ONLY — nothing automated can sign this off)
> The automated suite covers the whole chain up to the control's state: bytes
> arrive (`ProgressiveDownloadTests`), the download sites forward them
> (`DownloadChainTests`), events map to a bar position (`SetupDisplayTests`),
> and the position reaches `NSProgressIndicator` (`ProgressIndicatorTests`).
> What no test can assert is whether those pixels actually move on screen:
> off-screen readback of `NSProgressIndicator` reports no fill even for a
> control known to be at 75 %, so any automated pixel check would be a fake
> that passes regardless. A human watching a cold run is the only instrument.
> A bar that sits still for a whole stage has shipped twice; check every stage.
- [ ] Stage 2 (engine download): bar advances and the label counts up in %
- [ ] Stage 3 (engine unpack): bar advances and the label counts files
- [ ] Stage 4 (prefix boot): bar advances, never jumps backwards, label changes per sub-step
- [ ] Stage 5 (NWS download): bar advances and the label counts up in %
- [ ] Stage 6 (NWS install): bar is *animated* (indeterminate), not frozen, and shows no fake %
- [ ] No stage leaves the bar and the label disagreeing (one moving, one stuck)

## Packaging (`make package-app`)
- [ ] `make package-app` completes; app bundle under 5120 KB, both sizes reported
- [ ] Double-clicking `dist/OpenXE.dmg` opens a window showing OpenXE beside an `Applications` shortcut
- [ ] Dragging OpenXE onto that shortcut copies it to `/Applications`
- [ ] The image ejects, and OpenXE opens from `/Applications` afterwards

## First-launch security path (§4 of docs/platform-support.md)
> Needs a Mac that has **never approved this exact build** — a rebuild changes the
> cdhash, but `reset-fresh.sh --quarantine` alone does **not** re-arm an already
> approved one. Do not sign this off from a machine that has run the build before.
- [ ] Downloaded `.dmg`, dragged to Applications, first open is **blocked** by macOS
- [ ] System Settings → Privacy & Security shows OpenXE with an **Open Anyway** button
- [ ] Open Anyway + password launches the app, and subsequent opens need no approval
- [ ] Apple Silicon without Rosetta: the Rosetta explanation appears **after** the Gatekeeper step, not before

## Association
- [ ] Double-clicking a `.exe` in Finder launches it via OpenXE (if another handler owns `.exe`: Get Info → Open With → OpenXE → Change All, once)
- [ ] OpenXE shows no Dock icon while idle

## Applications
- [ ] One installer-based app: installer runs, app installs into C:, installed app launches
- [ ] One .NET app: runs (verifies Wine Mono end to end)
- [ ] One portable app: runs directly from any folder
- [ ] Repeat launch of any app is near-instant (warm wineserver)

## Persistence
- [ ] Settings/documents saved inside a Windows app survive quitting and relaunching (durable prefix)
- [ ] Windows app "Documents" shows the Mac's real ~/Documents

## Settings window (open OpenXE.app directly)
- [ ] Engine version displayed
- [ ] Open C: Drive opens `drive_c` in Finder
- [ ] Shut Down Windows Environment stops `wineserver`
- [ ] Reset Environment warns, then deletes and rebuilds on next launch

## Icon and install (§9.1–9.2)
- [ ] OpenXE.app shows the generated "›XE" icon in Finder and the app switcher
- [ ] OpenXE.app is installed in /Applications (or ~/Applications) after `build-app.sh`

## Launchers (§9.3)
- [ ] After first launch of an .exe, a launcher appears in "OpenXE Apps" with the exe's own icon (or the gray fallback)
- [ ] Spotlight finds the launcher by name; opening it relaunches the Windows program
- [ ] Launching the same .exe again does not duplicate the launcher
- [ ] Settings → Remove Generated Launchers deletes them all

## Remove OpenXE (spec 2026-08-09)
> Destructive and irreversible — run this **last**, and only when the machine's
> state is expendable. Not the same as Reset Environment.
- [ ] Settings → Remove OpenXE from this Mac… lists the engine, environment, logs, settings and each generated launcher, with a space figure
- [ ] "Also delete my New World Scheduler information" is **unchecked** when the window opens
- [ ] Leaving it unchecked: a "New World Scheduler Data (saved by OpenXE …)" folder appears in ~/Documents holding MyData, Backups, Settings1.json, RegistrationKey.json, DataTimestamps.json, Attachments, MyTemplates, the `.reg` file and README.txt
- [ ] Attachments and MyTemplates are present in that folder even though they are empty, and MyTemplates still has its category subfolders inside it
- [ ] README.txt names all seven, explains each in plain language, and says an empty folder is normal
- [ ] `~/Documents`, `~/Downloads` and `~/Desktop` are otherwise untouched — the prefix's symlinks were removed, not followed
- [ ] `pgrep wineserver` shows nothing for the OpenXE prefix afterwards
- [ ] `~/Library/Application Support/OpenXE`, `~/Library/Logs/OpenXE`, the preferences plist and the "OpenXE Apps" launchers are gone; non-OpenXE `.app`s in that folder survive
- [ ] The window ends by saying OpenXE itself must be quit and dragged to the Trash, and offers Quit
- [ ] Reinstall + re-setup, copy the whole saved folder's contents back: congregation data loads, and the licence is still registered (same Mac account)

## Failure paths
- [ ] A non-PE file renamed to `.exe` is refused with a plain-language explanation
- [ ] An ARM64 Windows binary is refused with the ARM explanation

## Log
| Date | Engine | Result | Notes |
|------|--------|--------|-------|
