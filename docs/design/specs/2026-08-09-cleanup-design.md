# Remove OpenXE — Design Specification

**Date:** 2026-08-09 · **Author:** Kai Sørensen · **Status:** Approved design, implemented.
**Scope:** an in-app command that removes OpenXE's entire footprint from this Mac, and
separately — defaulting to *keeping* — the user's New World Scheduler information.

---

## 1. Problem

There is no way to undo OpenXE. `Reset Environment…` and `scripts/reset-fresh.sh` both
exist, but neither is uninstall: reset rebuilds the environment on the next launch, and
the script is a developer tool. A user who wants OpenXE gone has to know where
`~/Library/Application Support` is.

Worse, every path to "gone" currently destroys the user's congregation data silently.
That data lives *inside* the prefix, so any deletion of the prefix takes it too, with no
warning and no copy.

## 2. Goals / Non-Goals

**Goals**

1. One command that removes everything OpenXE put on this Mac.
2. The user's NWS information is preserved by default, in a place they will find.
3. Nothing is deleted before the user has seen what will go and how much is reclaimed.
4. The feature cannot, under any failure mode, delete files outside OpenXE's own tree.
5. Impossible to confuse with `Reset Environment…`.

**Non-Goals**

- Deleting OpenXE.app itself. A running app cannot delete its own bundle; the app says
  so plainly instead of pretending. No relaunch-helper, no self-deleting shim.
- Uninstalling Rosetta. It is Apple's component, shared with other software.
- Restoring preserved data back into a new install. Out of scope; the saved folder is
  laid out so a later reinstall could copy it back by hand.
- A CLI. In-app only.

## 3. What OpenXE actually leaves on disk

Enumerated against a live installation on 2026-08-09, cross-checked against every
write path in `Sources/`.

| Path | Contents | Written by |
|---|---|---|
| `~/Library/Application Support/OpenXE/` | `engine/`, `prefix/`, `AppBundles/`, `appconfigs.json`, `setup-journal.json`, `nws-download/`, `.warm-server-build`, `download-*.partial`, `staging-*` | `OpenXEPaths.root` — every component |
| `~/Library/Logs/OpenXE/` | `wine.log`, `setup.log`, rotated `.1` generations | `Runner`, `SetupLog`, `NWSInstaller` |
| `~/Library/Preferences/dev.openxe.OpenXE.plist` | `OpenXEDidPromptAccessibility`, Rosetta offer flag, `SetupStage` timeout override | `UserDefaults.standard` |
| `~/Library/Caches/dev.openxe.OpenXE/` | URLSession cache | system, on our behalf |
| `~/Library/HTTPStorages/dev.openxe.OpenXE/` | URLSession cookie/credential store | system, on our behalf |
| `~/Library/Saved Application State/dev.openxe.OpenXE.savedState/` | window state | system, on our behalf |
| `/Applications/OpenXE Apps/`, `~/Applications/OpenXE Apps/` | generated launcher `.app`s | `LauncherManager` |
| `/tmp/.wine-<uid>/server-<dev>-<ino>/` | wineserver socket dir | Wine |

Everything in the first row is under `paths.root`, so one `removeItem` covers it. The
launcher directories are *not* ours wholesale — only bundles carrying the
`OpenXETargetPath` marker are, per `LauncherManager`.

LaunchServices: the `.exe` handler registration is a property of the app bundle, not a
separate file. `lsregister -u <bundle>` drops it; dragging the bundle to the Trash drops
it too. We do both — the unregister first, so the handler is gone even if the user
leaves the bundle in place.

## 4. Preservation

### 4.1 What is preserved

All live NWS data is in one directory:
`prefix/drive_c/users/<profile>/AppData/Local/NW Scheduler/` — 116 MB, of which about
3.3 MB matters.

Preserved — seven targets, settled by a read-only listing of the live directory:

| Target | Why |
|---|---|
| `MyData/` | the database |
| `Backups/` | NWS's own `.NWSchedulerBackup` files |
| `Settings1.json` | settings; DPAPI ciphertext, see §4.3 |
| `RegistrationKey.json` | licence; DPAPI ciphertext, see §4.3 |
| `DataTimestamps.json` | pairs with `MyData` and is meaningless apart from it |
| `Attachments/` | user-supplied files bound to records |
| `MyTemplates/` | user-authored print templates |

Discarded: `MeetingData/` (re-downloadable), `MinorUpdates/` (96 MB of installer
residue), `Logs/`, `MapCache/`, `Temp/`, `Updates/` — all regenerated on demand.

`Attachments/` and `MyTemplates/` are empty on this Mac today: the first until the user
attaches a file, the second as a tree of empty category folders. That structure is the
user's work, so an item is recorded as preserved on *presence*, never on file count. The
one case where "present but nothing copied" is correct is a symlink standing where a
target should be — it is not data we can rescue and must not be followed out of the
prefix, so it is excluded explicitly rather than inferred.

Also captured: the `NWScheduler` value under
`HKLM\System\CurrentControlSet\Control\Session Manager\Environment` in `system.reg`. The
NWS installer writes it; OpenXE does not. It is a 64-character string, and nothing else
on the machine records it. Read by parsing `system.reg` as text — by this point
wineserver is dead and `reg query` is not available.

### 4.2 Where it lands

`~/Documents/New World Scheduler Data (saved by OpenXE <date>)/`

Justification: it must survive the cleanup, so not Application Support; it must be
somewhere a non-technical user will look, so not `~/Library` and not a dotfile. The
Documents folder is the one location that satisfies both, and the name says what it is
without jargon. Not nested, not hidden, not zipped. A name collision gets a numeric
suffix rather than overwriting.

The registry value is written there twice: as `Windows Registry Setting.reg` (importable)
and inside `README.txt` in plain text, so it survives even if the `.reg` is meaningless
to whoever finds it.

### 4.3 Does the preserved data still work? — verified

`Settings1.json` and `RegistrationKey.json` are base64-wrapped DPAPI blobs produced by
Wine's `crypt32` (`CryptProtectData`). Whether they survive a prefix rebuild was not
assumed; it was measured on 2026-08-09 with a purpose-built mingw-w64 probe calling
`CryptUnprotectData` directly, against engine `gcenx-stable-11.0_1`.

| # | Experiment | Result |
|---|---|---|
| A | Seal and open in the same fresh prefix | decrypts |
| A3 | Open an entropy-sealed blob without the entropy | fails, err 13 |
| B | Seal in prefix 1, open in a **separate freshly-booted prefix 2** | **decrypts** |
| E | Open prefix 1's blob inside prefix 3 — a prefix booted under a *different* Windows profile, run as the original user | **decrypts** |
| G | Open a blob sealed as user `crossover` while running as user `sammyibeh`, same prefix | **fails, err 13** |

**Conclusion:** Wine's DPAPI key is bound to the **Windows user name**, not to the
prefix, the registry hives, or the machine. Restoring these two files into a rebuilt
prefix therefore works, and preserving them is not theatre.

**The one caveat, and it is load-bearing:** if the Windows profile name ever changes,
the blobs become undecryptable. Gcenx's `wineboot` names the profile after the unix
user (`sammyibeh`); CrossOver's names it `crossover`. Experiment G is exactly that
scenario. A future engine swap to a CrossOver-derived build would silently invalidate a
preserved `RegistrationKey.json`, and the licence would need re-registering. This is a
property of Wine, not something OpenXE can fix — but the README written into the saved
folder says it, so the finder of that folder is not surprised.

The NWS blobs additionally use application-supplied entropy (the probe reproduces err 13
against them, exactly as control A3 does). That is irrelevant to portability: NWS
supplies the same entropy after reinstall, and B/E show the key itself is portable.

## 5. Safety

The feature's whole value is that it deletes a lot. The invariants:

1. **Never traverse a symlink.** `users/<profile>/{Desktop,Documents,Downloads}` are
   symlinks to the real home folders, and `dosdevices/z:` maps to `/`. Sizing and
   copying use a hand-written walk that reads `isSymbolicLinkKey` and refuses to
   descend; nothing uses `FileManager.enumerator`'s default behaviour, so no invariant
   rests on undocumented traversal semantics. Deletion never recurses at all — it calls
   `removeItem` on whole top-level targets, which unlinks a symlink rather than
   following it.
2. **Every deletion is allowlist-checked.** `CleanupSafety.isDeletable` accepts a path
   only if it lies under one of the enumerated roots of §3, and rejects `/`, the home
   directory, `~/Documents`, `~/Downloads`, `~/Desktop`, and any path reached through a
   `..` component. A target that fails the check is skipped and reported, not deleted.
3. **No defaulted dependencies.** `CleanupPlanner` and `CleanupRunner` take every path
   by injection. There is no initialiser that resolves to the live machine, which is the
   defence `SystemInstallerBoundaryTests` had to be written for after a defaulted
   argument re-pointed a whole suite at the real installer.
4. **The runner refuses to run under test** unless its roots are inside the test's own
   temporary directory. `CleanupBoundaryTests` asserts this directly.

## 6. Flow

1. User opens Settings and chooses **Remove OpenXE from this Mac…**.
2. OpenXE builds a plan: every target of §3 that exists, with its size on disk, plus the
   NWS data directory sized separately.
3. A window lists what will be removed, the total reclaimed, and a single checkbox —
   *"Also delete my New World Scheduler information"* — **off by default**, with the
   saved-folder destination named beside it.
4. On confirm: wineserver is terminated (prefix-scoped `reapAllServers`, then
   `wineserver -k`), so nothing holds files open.
5. If the checkbox is off, the seven preserve targets and the registry value are copied
   out **before any deletion**. A failure here aborts the whole cleanup with nothing
   deleted.
6. Targets are deleted, each allowlist-checked.
7. The app unregisters itself from LaunchServices.
8. The result panel states what was removed, how much was reclaimed, where the saved
   data is (with a **Show in Finder** button), and that **OpenXE itself must be dragged
   to the Trash** — a running app cannot delete its own bundle.

## 7. Distinctness from Reset

| | Reset Environment… | Remove OpenXE from this Mac… |
|---|---|---|
| Keeps OpenXE usable | yes, rebuilds on next launch | no |
| Engine | kept | deleted |
| NWS data | deleted, silently | preserved by default |
| Button word | "Reset" | "Remove" |

The reset alert gains one sentence pointing at the new command, so a user who opens the
wrong one is redirected rather than surprised.

## 8. Budget

One core file (~380 lines), one window (~230 lines), strings in `SetupCopy`. No new
dependencies. Estimated binary impact well under 100 KB against the 5 MB budget.
