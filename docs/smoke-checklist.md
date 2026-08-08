# OpenXE — Manual Smoke Checklist

Spec §7. Run before calling a build done. Record date and engine version.

## Setup
- [ ] `scripts/build-app.sh` completes: builds, signs ad-hoc, stays under 5 MB, registers with LaunchServices
- [ ] Fresh state (`make fresh`, i.e. `scripts/reset-fresh.sh` — preview with `make fresh ARGS=--dry-run`): first `.exe` launch shows the one-time setup progress window and completes

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

## Failure paths
- [ ] A non-PE file renamed to `.exe` is refused with a plain-language explanation
- [ ] An ARM64 Windows binary is refused with the ARM explanation

## Log
| Date | Engine | Result | Notes |
|------|--------|--------|-------|
