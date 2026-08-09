# OpenXE — Cold-Machine Calibration Runbook

Spec §13.4. Plan `docs/design/plans/2026-08-08-setup-resilience.md`, calibration gate
between Task 7 and Task 8.

This run exists to replace warm-machine guesses with measured numbers. It destroys the
prefix, and the prefix currently holds the user's live New World Scheduler install.
Read §1 and §2 before touching anything.

---

## 0. Status of this document

| | |
|---|---|
| Written | 2026-08-09, on branch `setup-resilience` |
| Engine in scope | `gcenx-stable-11.0_1` (the pinned `EngineCatalog.stock`) |
| Windows profile in scope | `sammyibeh` |
| Blocking caveat | This Mac cannot be made cold in the Rosetta sense — see §2 |
| Second blocking caveat | `setup.log` does not exist yet — see §4 |

---

## 1. Before you start — the data that cannot be replaced

The prefix contains a real congregation database, nine NWS backups, and a licence:
roughly 3.3 MB at

```
~/Library/Application Support/OpenXE/prefix/drive_c/users/sammyibeh/AppData/Local/NW Scheduler/
```

`CleanupPlanner.preserveNames` is designed to preserve exactly this set, but it has
never been run against a real install. **It must not be the only thing between the user
and data loss.**

### 1.1 The independent backup (already taken)

Taken 2026-08-09 with plain `cp -Rp`, deliberately *not* using OpenXE's cleanup code:

```
~/OpenXE-NWS-Rescue-2026-08-09/
  NW Scheduler/                    the seven preserve targets
  NWScheduler-registry-value.txt   the Session Manager\Environment value
  MANIFEST-sha256.txt              64 SHA-256 lines, for re-verification
```

Verified against source: 64 files, 3,211,066 bytes, per-target file/dir/byte counts all
matching, and SHA-256 manifests identical. `MyTemplates` is 91 directories with zero
files and `Attachments` is one empty directory — both are structure-only and both
copied intact, which is the case a naive file-count check would miss.

Re-verify at any time:

```sh
cd ~/OpenXE-NWS-Rescue-2026-08-09/'NW Scheduler' \
  && find -P . -type f -exec shasum -a 256 {} + | sort -k2 \
  | diff - <(sort -k2 ../MANIFEST-sha256.txt) && echo OK
```

### 1.2 Second line of defence

`~/Desktop/2026-08-08_21-47-42 Medway Gillingham NWS Desktop 82_1460.NWSchedulerBackup`
— 285,708 bytes, sha256 `8816427f…4eb2a`, confirmed present 2026-08-09. This is a
vendor-format export made by NWS itself, so it can be restored through the application's
own import if the file-level restore in §8 disappoints. Do not delete it.

### 1.3 Why the file-level restore is expected to work

Not assumed — measured (cleanup spec §4.3). `Settings1.json` and `RegistrationKey.json`
are DPAPI blobs, and Wine binds the DPAPI key to the **Windows user name**, not to the
prefix, the hives, or the machine. Restoring them into a rebuilt prefix decrypts.

**The load-bearing condition:** the rebuilt prefix must come up with the same Windows
profile name, `sammyibeh`. Gcenx's `wineboot` names the profile after the unix user, so
the pinned engine is fine. A CrossOver-derived engine names it `crossover` and the
licence blob becomes permanently undecryptable. **Do not combine this calibration run
with an engine swap.** One variable at a time.

---

## 2. What this machine can and cannot prove

**Rosetta 2 cannot be uninstalled.** There is no `softwareupdate --uninstall-rosetta`,
and the ahead-of-time translation cache at `/var/db/oah` is SIP-`restricted` — verified
on this machine 2026-08-09: it is owned by `_oahd`, flagged `restricted` under `ls -lO`,
and unreadable even when listing (`Operation not permitted`). Nothing short of a
reinstall clears it, and `reset-fresh.sh` does not pretend otherwise.

Consequence, stated plainly:

| Question | Can this run answer it? |
|---|---|
| Stage weights on a genuinely cold machine | **No.** Every measurement here is still a floor. |
| Stage weights on a warm-Rosetta, cold-OpenXE machine | Yes — better than the current numbers, which were taken mid-development. |
| `expectedPrefixEntries` | **Yes, fully.** Prefix file count has nothing to do with Rosetta. |
| Longest legitimate inter-event gap / stall threshold | Partially — the measured value is a floor. 60 s must clear it with margin. |
| `useBatchedImport` removal condition (a) | **No.** §13.4 condition (a) is specifically a no-AOT-cache run. It stays unmet. |
| First-open Gatekeeper prompt | Yes, via `--quarantine` (§3). |

So: this run **recalibrates** and **de-risks**, and it does not close spec §13.4. Record
it as a warm-Rosetta calibration, not a cold-machine one. Removing `useBatchedImport`
still needs a genuinely cold Mac.

---

## 3. What `reset-fresh.sh` does and does not reset

`make fresh` → `scripts/reset-fresh.sh`. Preview first with `make fresh ARGS=--dry-run`.

**Deletes:**

- `~/Library/Application Support/OpenXE/` entirely — engines, **the prefix and with it
  the live NWS install**, `AppBundles`, `appconfigs.json`, `nws-download`
- `~/Library/Logs/OpenXE/` — including `setup.log` and `wine.log`. **This is why §6 says
  copy the logs out before any second reset.**
- Generated launcher `.app` bundles in `/Applications/OpenXE Apps` and
  `~/Applications/OpenXE Apps`, but only those carrying the `OpenXETargetPath` marker,
  each `lsregister -u`'d first
- The `dev.openxe.OpenXE` defaults domain — so any `OpenXEStageWeights` override you set
  is wiped too

**Does not touch:** the real `~/Documents`, `~/Downloads`, `~/Desktop` (the prefix holds
only symlinks to them, and nothing in the script follows a symlink), the repo working
tree, `dist/`, `~/.cache/openxe-engine-build`, and — critically — anything outside those
paths, so `~/OpenXE-NWS-Rescue-2026-08-09/` is untouched.

**Cannot reset:**

- **Rosetta 2 and its AOT cache** (§2)
- **Gatekeeper's approval cache** on its own. `/var/db/SystemPolicyConfiguration/ExecPolicy`
  is SIP-restricted and this OS's `spctl` has no `--reset`. The `--quarantine <app>` flag
  works around it by bumping `CFBundleVersion` and re-signing ad-hoc so the bundle
  presents a cdhash this Mac has never approved. It verifies the change and fails loudly
  if the hash did not move. **Re-run it after every `make app`** — a rebuild restores
  `CFBundleVersion=1` and the old, already-approved hash.
- Anything the run needs from the network. A cold run re-downloads ~1.5 GB of engine
  plus ~50 MB of NWS. Do this on a connection you are willing to characterise, and
  record what it was.

---

## 4. The measurement blocker, and the way round it

Spec §13.4 says the run "needs no new tooling: `SetupLog` already records per-stage
elapsed times". **That is not true of the current build.** `SetupLog` exists as a type,
but `SetupCoordinator` does not exist yet (it is Task 8), and the only callers of
`beginRun` / `beginStage` / `endStage` are in `Tests/OpenXECoreTests/SetupLogTests.swift`.
No production path constructs a `SetupLog`. A run today produces **no `setup.log` at
all**, and the shipping wizard is still the four-step `welcome → environment → nws →
done` flow, not the six weighted stages.

Two honest options:

- **(A) Calibrate externally now.** Take wall-clock stage boundaries from the wizard's
  visible transitions plus a filesystem sampler (§6.2). Yields a good
  `expectedPrefixEntries` and usable stage durations; yields nothing for inter-event gap.
- **(B) Do Task 8 first, then calibrate.** Gets `setup.log` and true per-stage and
  per-event timing, at the cost of calibrating a build that is further from the one
  measured so far.

**Recommendation: (A).** `expectedPrefixEntries` is the figure with the weakest evidence
and the strongest external observability, and option A gets it without reordering the
plan. Re-run the timing half after Task 8 lands, when `setup.log` makes it nearly free.

---

## 5. The run — by hand vs scripted

### 5.1 A human must do these. They cannot be scripted.

1. **Confirm the backup** (§1.1 re-verify command) and confirm the Desktop export is
   still there. Do not proceed on trust.
2. **Quit OpenXE and any Windows program.** The reset refuses to run otherwise.
3. **Type `y` at the reset confirmation.** Do not use `--yes` — the prompt is the last
   checkpoint before the live NWS install is destroyed.
4. **Click through the first-open Gatekeeper block**: open the app, get refused, go to
   System Settings → Privacy & Security → **Open Anyway**, confirm. This is a GUI trust
   decision; there is no supported CLI equivalent, which is the whole reason
   `--quarantine` exists.
5. **Drive the wizard** and press a stopwatch (or run §6.1's marker command) at each
   visible transition. The transitions are the only stage boundaries this build exposes.
6. **Accept the Rosetta prompt if it appears** — it will not on this Mac (§2), and its
   absence is itself a datum worth recording.
7. **Watch for stalls with a human eye.** Acceptance criterion 1 is "no stage goes more
   than 10 s without substantive evidence of progress". Until Task 8 instruments this,
   a person watching the window is the instrument.
8. **Restore the NWS data (§8) and verify inside NWS** — open the app, confirm the
   congregation data and the licence. Only the application can confirm its own data.

### 5.2 Scripted

- `make fresh ARGS=--dry-run` — preview
- `make fresh ARGS="--quarantine /Applications/OpenXE.app"` — reset + re-arm Gatekeeper
- The §6.2 sampler — 1 Hz filesystem CSV
- The §8 restore copy and its verification

---

## 6. Capturing the measurements

### 6.1 Stage boundaries by hand

Start this before the first wizard click; hit Return at each visible transition. It
timestamps into the same directory as the sampler.

```sh
RUN=~/openxe-calibration-2026-08-09; mkdir -p "$RUN"
while read -r label; do
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$label" | tee -a "$RUN/marks.txt"
done
```

Type a label (`engine-download-start`, `unpack-start`, `prefix-start`, `nws-start`,
`done`) and press Return at each transition.

### 6.2 Filesystem sampler

Run in the background for the whole session. **`find -P`, hidden files excluded, so it
matches `PrefixEntryCounter.entryCount`'s `FileManager` enumerator with
`.skipsHiddenFiles` — and, more importantly, so it does not follow `dosdevices/z: -> /`.**
Verified 2026-08-09: 69 ms over a fully-populated prefix, no traversal of `z:`.

```sh
RUN=~/openxe-calibration-2026-08-09; mkdir -p "$RUN"
R="$HOME/Library/Application Support/OpenXE"
echo "epoch,prefix_entries,engine_bytes,nws_bytes,staging_dirs" > "$RUN/sample.csv"
while :; do
  pe=$( [ -d "$R/prefix" ] && find -P "$R/prefix" -not -path '*/.*' 2>/dev/null | wc -l | tr -d ' ' || echo 0 )
  eb=$( [ -d "$R/engine" ] && du -sk "$R/engine" 2>/dev/null | cut -f1 || echo 0 )
  nb=$( [ -d "$R/nws-download" ] && du -sk "$R/nws-download" 2>/dev/null | cut -f1 || echo 0 )
  sd=$( find -P "$R/engine" -maxdepth 1 -type d -name 'staging-*' 2>/dev/null | wc -l | tr -d ' ' )
  echo "$(date +%s),$((pe>0?pe-1:0)),$eb,$nb,$sd" >> "$RUN/sample.csv"
  sleep 1
done
```

`prefix_entries` subtracts 1 because `find` counts the prefix root and the `FileManager`
enumerator does not.

### 6.3 What feeds which constant

| Measurement | Source | Feeds |
|---|---|---|
| Six stage durations | §6.1 marks | `StageWeightTable.builtIn` — `Sources/OpenXECore/SetupStage.swift` |
| Prefix entries at the moment `wineboot --init` returns, **before** Mono/Gecko/fonts/NWS | §6.2 `prefix_entries` at the `prefix-start`→next-mark plateau | `PrefixProgress.expectedPrefixEntries` — `Sources/OpenXECore/PrefixManager.swift:48`, currently `2027` |
| Longest gap with no visible change | §6.2 plus human observation | stall threshold (60 s), `PrefixProgress` 4a criterion |
| Engine archive entries | unchanged unless repinned | `EngineManager.expectedArchiveEntries` = 5,333 |

**Reading `expectedPrefixEntries` correctly.** The constant is defined as "files a
completed `wineboot --init` leaves in the prefix" — *not* the end-of-setup count. In the
CSV it is the plateau at the end of the boot sub-step, before Mono/Gecko and the font
import push it higher. For scale: the current fully-populated prefix (boot + Mono/Gecko
+ fonts + NWS) counts 9,960 by the same method, so a plateau anywhere near that is the
wrong plateau.

### 6.4 What counts as a valid result

- Stage durations sum to a plausible wall clock and **stage 4 is at or above the ~29 s
  warm lower bound**. Below it means the run was not as cold as claimed.
- Recomputed weights are integers summing to **exactly 100** — enforced by
  `testStageWeightsSumTo100` and `testResolvedWeightsAlwaysSumTo100`.
- `expectedPrefixEntries` is a clear plateau, not a mid-slope sample. If it lands within
  a few per cent of 2027, keep 2027 and record that it was confirmed.
- Every longest-gap observation stays **comfortably below 60 s**; anything above 10 s is
  a finding against acceptance criterion 1 and must be written up, not rounded away.
- The run reached the end. **A failed run yields no weights** — a partial timing set is
  worse than the current numbers because it looks authoritative.

Apply candidate weights without a rebuild before folding them into the source:

```sh
defaults write dev.openxe.OpenXE OpenXEStageWeights \
  -dict preflight 1 downloadEngine 37 unpackEngine 25 \
        preparePrefix 12 downloadNWS 10 installNWS 15
```

Invalid or non-summing overrides are logged and ignored in favour of the built-ins, so a
typo degrades to the defaults rather than to a broken bar.

---

## 7. Order of operations

1. Verify backup (§1.1) and Desktop export (§1.2).
2. Copy any existing `~/Library/Logs/OpenXE/` aside — the reset deletes it.
3. `make fresh ARGS=--dry-run`, read the list, confirm it names only what §3 says.
4. Start the sampler (§6.2) and the marker loop (§6.1).
5. `make fresh ARGS="--quarantine /Applications/OpenXE.app"`, answer `y`.
6. Open OpenXE, click through Gatekeeper by hand (§5.1 step 4).
7. Drive the wizard, marking each transition.
8. On completion: stop the sampler, copy `~/Library/Logs/OpenXE/` into the run directory.
9. Restore the NWS data (§8).
10. Write the numbers up against §6.3, then proceed to plan Task 8.

---

## 8. Restoring the user's NWS data

Do this **after** setup completes and NWS has been installed and launched at least once,
so the target directory exists and the profile is built.

```sh
SRC=~/OpenXE-NWS-Rescue-2026-08-09/'NW Scheduler'
DST="$HOME/Library/Application Support/OpenXE/prefix/drive_c/users/sammyibeh/AppData/Local/NW Scheduler"
# NWS must be closed, and wineserver stopped, before overwriting its database.
"$HOME/Library/Application Support/OpenXE/engine/current/wine/bin/wineserver" -k 2>/dev/null || true
mkdir -p "$DST"
for t in MyData Backups Attachments MyTemplates DataTimestamps.json Settings1.json RegistrationKey.json; do
  rm -rf "$DST/$t"; cp -Rp "$SRC/$t" "$DST/"
done
```

Then verify the restore the same way the backup was verified — file counts, byte totals,
and the SHA-256 manifest (§1.1), pointed at `$DST`.

Restore the registry value (it is under `HKLM`, matching
`System\ControlSet001\Control\Session Manager\Environment` in `system.reg`):

```sh
R="$HOME/Library/Application Support/OpenXE"
WINEPREFIX="$R/prefix" "$R/engine/current/wine/bin/wine" reg add \
  'HKLM\System\CurrentControlSet\Control\Session Manager\Environment' \
  /v NWScheduler /t REG_SZ \
  /d 'C&E)H@McQfTjWnZr4u7x!A%D*G-JaNdRgUkXp2s5v8y/B?E(H+MbPeShVmYq3t6w' /f
```

Single quotes are required — the value contains `&`, `!`, `*`, `?`, `(`, `)` and `%`.
In an interactive `zsh` the `!` will still trigger history expansion inside double
quotes; keep it single-quoted or paste from
`~/OpenXE-NWS-Rescue-2026-08-09/NWScheduler-registry-value.txt`.

**Finally, open NWS and check with your eyes:** congregation data present, backups
listed, licence still registered. If the licence has gone, the profile name changed
(§1.3) — that is the one failure the file copy cannot fix, and the Desktop
`.NWSchedulerBackup` export plus re-registration is the recovery path.

---

## 9. Abort path — the run fails with the prefix half-built

The user's data is already safe in `~/OpenXE-NWS-Rescue-2026-08-09/`, so a failed run is
an inconvenience, never a loss. Work in this order.

1. **Stop.** Do not retry into a half-built prefix; a resumed-into-broken state is
   unmeasurable and the timings from it are worthless.
2. **Capture the evidence before it is deleted.** Copy `~/Library/Logs/OpenXE/` and the
   sampler CSV into the run directory. The next `make fresh` destroys the logs.
3. **Kill the subprocess tree**, matching on the engine path so unrelated Wine installs
   are untouched:
   ```sh
   R="$HOME/Library/Application Support/OpenXE"
   "$R/engine/current/wine/bin/wineserver" -k 2>/dev/null || true
   pgrep -fl "$R/engine/" || echo "no engine processes"
   ```
4. **Check for debris**: leftover `engine/staging-*`, a stale `.partial`, a
   `setup-journal.json` from a Task-8-or-later build. Note what you find — half-built
   state is exactly what the plan's sweeper work (Task 8, §8.4) is for, and a real
   specimen is useful evidence.
5. **Decide:**
   - *Failed mid-download* (network) — re-run from step 4 of §7. Timings from the failed
     attempt are void; do not average them in.
   - *Failed in prefix build or install* — a genuine bug. Write it up, restore the user's
     working state (§8 needs a completed install first, so re-run setup to completion on
     a known-good path before restoring), and do not report calibration numbers from the
     failed run.
   - *Cannot get to a working install at all* — restore by installing NWS through the
     normal path and importing the Desktop `.NWSchedulerBackup` through the application's
     own restore. The user gets their data back through the vendor's supported route
     regardless of the state of our code.
6. **Never** delete `~/OpenXE-NWS-Rescue-2026-08-09/` until the user has confirmed, in
   NWS, that their data is back.
