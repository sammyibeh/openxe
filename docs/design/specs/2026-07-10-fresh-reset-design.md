# Fresh-Install Reset — Design

**Date:** 2026-07-10
**Status:** Approved design
**Owner:** Kai

## Goal

A developer tool that returns this Mac to a true first-run state for OpenXE, so the
complete fresh-device experience (wizard from step 1: disclaimer → engine download →
NWS download/install → launch) can be reproduced at will. Motivated by testing what a
friend on a clean Mac would experience.

## Non-goals

- Not a user-facing feature. No app-code changes, no Settings surface, no spec §
  changes to the app itself.
- Not a fast-iteration mode. Every reset is a full wipe; the wizard re-downloads the
  engine each time. That slowness is the point (authenticity).
- Does not simulate everything about a new machine (fonts, macOS version, other apps).
  Gatekeeper re-arming is the one supported fidelity extra.

## Deliverables

1. `scripts/reset-fresh.sh`
2. `make fresh` target in the Makefile (listed in `make help`)
3. `docs/smoke-checklist.md`: replace the manual "delete
   `~/Library/Application Support/OpenXE`" fresh-state instruction with the script

## Behavior of `scripts/reset-fresh.sh`

Steps, in order:

1. **Safety gate.** Abort with a clear message if OpenXE.app is running or if any
   `wine`/`wineserver` process belonging to an installed OpenXE engine is alive
   (match on the engine path under `~/Library/Application Support/OpenXE/engine/`,
   not on bare process names — do not kill or block on unrelated Wine installs).
   Then print a plain-English summary of exactly what will be deleted and prompt
   for confirmation. `--yes` skips the prompt.
2. **Shut down.** If an active engine exists, run its `wineserver -k` against the
   OpenXE prefix so no Wine process holds files open. Tolerate absence (partial
   state) silently.
3. **Wipe state.** Delete, tolerating already-missing paths:
   - `~/Library/Application Support/OpenXE/` — engines, prefix (including the NWS
     install inside it), AppBundles, appconfigs.json, nws-download
   - Generated launchers: every `.app` in `/Applications/OpenXE Apps/` and
     `~/Applications/OpenXE Apps/`, each unregistered from LaunchServices
     (`lsregister -u`) before its directory is removed
   - The `dev.openxe.OpenXE` defaults domain (`defaults delete`; tolerate
     "domain not found")
   - `~/Library/Logs/OpenXE/`
4. **Re-arm Gatekeeper (optional).** `--quarantine <path-to-OpenXE.app>` makes the
   next open of that app copy show the genuine first-open Gatekeeper prompt. No
   default path — the flag is explicit or the step is skipped.

   Re-applying `com.apple.quarantine` is necessary but **not sufficient**, and
   this was the original defect: macOS caches the user's approval in
   `/var/db/SystemPolicyConfiguration/ExecPolicy`, keyed on the bundle's
   code-directory hash. Verified 2026-08-09: that file is SIP-`restricted`
   (unwritable even as root), and this OS's `spctl` exposes only `--assess`,
   `--status` and `--global-disable` — no add/remove/reset. An already-approved
   bundle therefore keeps launching straight through no matter how often its
   quarantine xattr is rewritten, and the reset silently produced a machine that
   was not in a first-run state.

   The step therefore does two things, and verifies both:
   - **A cdhash this Mac has never approved.** `CFBundleVersion` is bumped to a
     UTC timestamp and the bundle is re-signed ad-hoc exactly as `build-app.sh`
     signs it (`codesign --force -s -`, then `--verify --strict` and a per-slice
     check). `CFBundleVersion` appears only in `Resources/Info.plist` and no
     OpenXE source reads it, so the build under test is otherwise unchanged. The
     hash is read before and after and must differ.
   - **The quarantine xattr, confirmed present on the bundle root** — the one
     LaunchServices reads — rather than trusting the recursive write's status.

   Then `lsregister -f` re-registers the rewritten bundle. If any of this fails,
   the script says exactly what it could not reset and exits non-zero: a reset
   that silently fails to reset would corrupt the cold-Mac calibration this
   script exists to enable.

   **This must be re-run after every `make app`.** A rebuild restores
   `CFBundleVersion=1` and with it the original, already-approved cdhash.
5. **Verify and report.** Confirm each wiped path no longer exists; print a final
   "fresh state confirmed — next launch runs the wizard from step 1" line, or list
   anything that survived and exit non-zero. A failed Gatekeeper re-arm is
   reported and exits non-zero even when every path was wiped cleanly.

### Flags

| Flag | Effect |
|---|---|
| `--yes` | Skip the confirmation prompt |
| `--dry-run` | Print everything that would be deleted, delete nothing, exit 0 |
| `--quarantine <path>` | Also re-arm Gatekeeper on the given OpenXE.app copy: fresh cdhash + quarantine, both verified |

`--dry-run` exists so the script itself can be tested without destroying state.

## Safety invariants

- Never touches the real `~/Documents`, `~/Downloads`, `~/Desktop`. The prefix
  contains symlinks to them; deletion must remove links only (plain `rm -rf` on the
  prefix parent already guarantees this — the script must not add anything that
  follows symlinks, e.g. no `find -L`).
- Never touches the repo working tree, `dist/`, or `~/.cache/openxe-engine-build`.
- Launcher deletion only removes `.app` bundles carrying the `OpenXETargetPath`
  marker (per `LauncherManager`), then the containing "OpenXE Apps" folder only if
  empty of anything else.
- Refuses to run as root.

## Style

Match the existing scripts (`build-engine.sh`, `package-engine.sh`): bash,
`set -euo pipefail`, same log/err helper conventions, executable bit set.

## Acceptance criteria

1. `--dry-run` on a fully-set-up machine lists all state accurately and deletes
   nothing (verified by re-checking paths after).
2. Real run: all listed state gone; verify step passes; `~/Documents`,
   `~/Downloads`, `~/Desktop` contents untouched.
3. Next app launch opens the wizard at step 1 (disclaimer), engine download step
   actually downloads (no cached engine), NWS step downloads and installs.
4. Wizard final step: the launch action starts NWS and the setup window closes.
5. Re-running the script on an already-fresh machine exits cleanly (idempotent).
6. `make fresh` invokes the script; `make help` lists it.

The implementer verifies 1 and 6 plus shellcheck-clean — everything testable without
a destructive run. Criteria 2–5 require the real wipe and are verified during the
user's fresh-device walkthrough; the reset is performed only on the user's go-ahead,
because a real run destroys the current engine/prefix/NWS state, including the
in-testing self-built engine install.
