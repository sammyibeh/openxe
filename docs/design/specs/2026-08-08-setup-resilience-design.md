# Setup Resilience — Design Specification

**Date:** 2026-08-08 · **Author:** Kai Sørensen · **Status:** Approved design, pending implementation plan.
**Supersedes:** [`2026-07-06-openxe-design.md`](2026-07-06-openxe-design.md) §4.4 (first-run progress window) and §4.7 (guided wizard) where they conflict.
**Motivation:** audit of 2026-08-08 against `main` @ `da5dd9a`, after a first-run install on a third-party Mac showed a multi-minute silent stretch with no evidence of life, no failure surface, and no defined quit behaviour.

---

## 1. Problem

OpenXE's first run works when nothing goes wrong and is close to unobservable when something does. The audit found ten defects; this spec addresses all ten. The four that matter most:

- **A 2–5 minute silent stretch.** `WizardWindow.swift:280` sets one string before `PrefixManager.ensurePrefix` and never updates it again. `EngineProgress` (`EngineManager.swift:47-51`) has no case capable of describing prefix work, so the silence is structural, not an oversight.
- **No setup log.** `~/Library/Logs/OpenXE/wine.log` is written only by `Runner.openLog` (`Runner.swift:298-310`) and `NWSInstaller.openInstallLog` (`NWSInstaller.swift:318-328`). Stages 1–10 of setup write nothing. Confirmed against a live 26-session log: engine install and prefix build left zero trace.
- **Quit is undefined and destructive.** The close button is live throughout (`WizardWindow.swift:52`), there is no `windowShouldClose` and no `applicationShouldTerminate`, and `terminateIfIdle` (`AppDelegate.swift:168-173`) ignores the wizard's `working` flag. One click kills the app, orphans `tar`/`wine`, and leaks up to 666 MB in `engine/staging-*` that nothing ever sweeps.
- **Failures are near-invisible.** Every error lands in an 11 pt red label (`WizardWindow.swift:151-154`). No alert, no sound, no log button, no automatic retry on any network failure.

## 2. Goals / Non-Goals

**Goals**

1. At every moment of setup the user can tell it is alive, what it is doing, and roughly how much longer.
2. Every failure produces a plain-English cause, a retry path, and a log the user can hand to us.
3. Quitting mid-setup is safe, confirmed, and leaves no orphaned process or directory.
4. Interrupted setup resumes at stage granularity rather than starting over.
5. The one structurally unrecoverable state in the current code is eliminated.

**Non-Goals**

- Sub-checkpointing inside the prefix build. Settled: the prefix stays atomic (§6.3).
- Background continuation after the window closes. Settled: close means cancel.
- A build-log readout as the primary UI. The technical detail lives behind a disclosure triangle.
- Any third-party dependency. Any change to the Wine-as-unmodified-subprocess boundary.
- Reworking the `.exe` launch path beyond routing its setup through the same coordinator.

## 3. Measurements

Every weight, threshold, and string in this spec derives from measurements taken 2026-08-08 on the developer's Mac against the pinned engine `gcenx-stable-11.0_1`.

| Quantity | Value | Source |
|---|---|---|
| Engine archive | 185,303,032 B (**177 MB**) | `Content-Length` from the pinned URL |
| Engine extracted | **666 MB**, 5,324 entries | `du -sh`, `find \| wc -l` |
| Prefix after build, before NWS | **~459 MB** | 696 MB total minus 237 MB NWS |
| NWS installed | **237 MB** | `du -sh` on `Program Files/New World Scheduler` |
| NWS installer | ~48 MB | **Unverified** — taken from existing wizard copy (`WizardWindow.swift:327`). Varies per release; the API reports the exact size at runtime (`NWSInstaller.swift:53`). Used here only for the disk-space headroom calculation, where it is a rounding error. |
| NWS silent install duration | **≤39 s** (measured) | `wine.log` `16:03:12Z` → `16:03:51Z` |
| Peak cumulative disk need | **~1.41 GB** | 843 MB (archive + staging, concurrent) → 666 MB engine → +459 MB prefix → +48 MB installer → +237 MB NWS |
| App binary today | 879,312 B (859 KB) | `dist/OpenXE.app/Contents/MacOS/OpenXE` |
| Font registry writes | **57** | `FontProvisioning.substitutions` = 28 pairs × 2 tables + 1 FontAwesome registration |

### 3.1 Spike measurements (R3, 2026-08-08)

Taken against the real pinned engine on a throwaway prefix (Apple M2, macOS 27, engine already Rosetta-translated and page-cached — see the caveat below). Two full `wineboot --init` runs, instrumented for output-line timing and 1 Hz filesystem growth.

| Quantity | Measured | Note |
|---|---|---|
| `wineboot --init` wall time | **24.1 s** (run A), 19.7 s (run B) | Both `rc=0`; Wine Mono registered and Gecko present, so the boot did the real work |
| `wine reg add`, warm server | **559 ms** each | 10 sequential writes timed |
| 57 font-provisioning writes, projected | **~32 s** | 57 × 559 ms |
| **Stage 4 total (measured)** | **~59 s** | 24 boot + 1 drain + 0.5 verify + 1.7 (3 reg) + 32 fonts + 0.5 linking |
| Max output-line gap, `WINEDEBUG=fixme-all` | **9.71 s** | Today's setting. Marginal against the 10 s criterion |
| Max output-line gap, `WINEDEBUG=+loaddll` | **4.63 s** | 735 loaddll lines, 101 KB |
| Max gap, **output ∪ filesystem growth**, `fixme-all` | **4.47 s** | ← the adopted mechanism |
| Max gap, output ∪ filesystem growth, `+loaddll` | 4.63 s | No better than `fixme-all` + filesystem |
| Prefix growth during boot | 331 MB, 1 → 2,027 files | Growth is continuous t=2 s → t=16.5 s, then flat for the final 7.3 s |
| Cost of 1 Hz recursive walk (2,027 files) | **10.3 ms** | ~1 % of one core at 1 Hz; a `statfs` alternative costs 2.9 ms |

**Caveat on these numbers.** The machine had already Rosetta-translated and cached the engine's binaries. A genuine first run on a friend's Mac pays one-time Rosetta AOT translation that these runs did not, so **59 s is a floor, not a typical cold figure.** The weights in §4.2 use it anyway because the ETA recalibration in §7.3 exists precisely to absorb this class of error, and 59 s is a far better starting point than the 180 s guess it replaces. A cold-machine calibration run is a plan step (§13.4).

**Corrected size copy.** The canonical figures are **177 MB download / ~700 MB installed**, replacing three mutually inconsistent strings: `WizardWindow.swift:256` ("about 1.7 GB" — wrong by ~10×), `AppDelegate.swift:79` ("~200 MB download"), `ProgressWindow.swift:58` ("~1 GB"). These become one constant, `SetupCopy.engineSizeSummary`, referenced from all three sites.

---

## 4. Architecture

A new `SetupCoordinator` owns first-run end to end. It is the only object that decides what runs, in what order, and what happens on failure. The wizard and the launch-path progress window become renderers of its event stream and hold no orchestration logic.

```
Sources/OpenXE  (AppKit)
  WizardWindowController      renders SetupEvent; owns the confirm sheet
  ProgressWindowController    renders SetupEvent (launch-path subset)
  AppDelegate                 owns the coordinator; applicationShouldTerminate
  AppMenu                     NEW — minimal main menu so ⌘Q exists

Sources/OpenXECore  (no AppKit)
  SetupCoordinator            NEW — stage machine, event stream, cancel
  SetupStage                  NEW — id, name, weight, resume rule, retry policy
  SetupEvent                  NEW — replaces EngineProgress / NWSProgress outward
  SetupJournal                NEW — on-disk JSON, attempt history
  SetupLog                    NEW — ~/Library/Logs/OpenXE/setup.log
  ChildRegistry               NEW — live PIDs, so cancel actually kills
  StallDetector               NEW — liveness watchdog
  SetupSweeper                NEW — startup cleanup of orphaned artefacts
  SetupPreflight              NEW — disk space + Rosetta gate
  EngineManager               modified: commit ordering, unpack sub-progress
  PrefixManager               modified: progress callback, sub-steps
  NWSInstaller                modified: resumable download
  Subprocess                  modified: optional ChildRegistry + log tee
```

**Dependency rule unchanged:** `OpenXECore` stays AppKit-free. `SetupCoordinator` emits values; it never touches UI.

### 4.1 SetupEvent

`EngineProgress` (`EngineManager.swift:47-51`) and `NWSProgress` (`NWSInstaller.swift:331-335`) are retired as the outward contract. Components keep narrow internal progress callbacks; the coordinator maps them into one stream.

```swift
public enum SetupEvent: Sendable {
    case stageBegan(SetupStage.ID, index: Int, of: Int)
    case stageProgress(SetupStage.ID, fraction: Double?, detail: String)   // nil = indeterminate
    case stageCompleted(SetupStage.ID, elapsed: TimeInterval)
    case overall(fraction: Double, elapsed: TimeInterval, remaining: TimeInterval?)
    case attempt(SetupStage.ID, number: Int, of: Int, reason: String)      // visible retry
    case stalled(SetupStage.ID, silentFor: TimeInterval)
    case recovered(SetupStage.ID)                                          // stall cleared
    case failed(SetupFailure)
    case cancelled(SetupStage.ID)
    case finished
}
```

`detail` is the plain-English sub-line ("Registering fonts (23 of 57)"). The technical line shown under the disclosure triangle comes from the tail of `SetupLog`, not from the event.

### 4.2 SetupStage

```swift
public struct SetupStage: Sendable {
    public enum ID: String, Codable, CaseIterable {
        case preflight, downloadEngine, unpackEngine, preparePrefix, downloadNWS, installNWS
    }
    public let id: ID
    public let displayName: String      // "Preparing the Windows environment"
    public let weight: Int              // share of the overall bar, sums to 100
    public let resumable: Bool          // byte-level resume within the stage
    public let retry: RetryPolicy
    public let hardCeiling: TimeInterval // existing subprocess timeout, kept as backstop
}
```

**The six stages and their weights.** Weights are the stage's share of a reference run, derived from §3. Reference seconds: preflight 2, download 90, unpack 60, **prefix 59 (measured, §3.1)**, NWS download 25, NWS install 35 — total 271 s.

> **Revised 2026-08-08 by spike.** The prefix reference was 180 s, an estimate. Direct measurement put it at **59 s**, dropping stage 4's weight from 46 to 22 and roughly halving the assumed run length. Stages 2 and 3 remain estimates (§11 R2a).

| # | ID | Display name | Weight | Resumable | Retry | Ceiling |
|---|---|---|---|---|---|---|
| 1 | `preflight` | Checking your Mac | 1 | n/a | none | 15 s |
| 2 | `downloadEngine` | Downloading the Windows environment | 33 | **yes** (HTTP Range) | 3 × network, then 2 × integrity | 60 s idle |
| 3 | `unpackEngine` | Unpacking the Windows environment | 22 | no (restartable from the verified archive) | none (restart is free) | 900 s |
| 4 | `preparePrefix` | Preparing the Windows environment | **22** | **no — atomic** | none (manual only) | 900 s |
| 5 | `downloadNWS` | Downloading New World Scheduler | 9 | **yes** (new) | 3 × network | 600 s idle |
| 6 | `installNWS` | Installing New World Scheduler | 13 | no | none (manual only) | 1200 s |

Weights are static defaults. The ETA calculation (§7.3) rescales them from observed cost, so a slow network does not make the bar lie for the whole run.

**Stage boundary between 2 and 3 (explicit, to remove a reading ambiguity).** SHA-256 verification is the **terminal act of stage 2**, not the opening act of stage 3. Stage 2 is complete only when the archive is on disk *and* its checksum matches; that is what sets `archiveVerified` in the journal. A mismatch is therefore a stage-2 failure and re-downloads (the existing behaviour at `EngineManager.swift:211-225`, made visible per §9.2). Stage 3 consumes an already-verified archive and never re-verifies, which is why it needs no retry policy of its own — restarting it costs only the unpack.

### 4.3 ChildRegistry

The reason cancel does not work today: `Process` children are never signalled on app exit, and `Task.cancel()` cannot interrupt `Subprocess.run`'s semaphore wait (`Subprocess.swift:74-82`).

```swift
public final class ChildRegistry: Sendable {
    public func register(_ pid: pid_t, label: String)
    public func deregister(_ pid: pid_t)
    public func terminateAll()   // SIGTERM → 400 ms grace → SIGKILL
    public var liveCount: Int { get }
}
```

`Subprocess.run` gains one optional parameter, `registry: ChildRegistry? = nil`, registering after `process.run()` and deregistering in the termination handler. Existing call sites are unaffected.

**Cancellation mechanism (the subtle part).** `SetupCoordinator.cancel()` does three things in order: sets an internal `cancelled` flag; calls `ChildRegistry.terminateAll()`; then lets the in-flight stage unwind. Killing the child is what releases the blocked semaphore — the flag alone cannot. On unwind the coordinator checks the flag and converts whatever error surfaced into `.cancelled` rather than `.failed`. Cancel latency is bounded by the SIGTERM grace period (~0.4 s) plus the 0.5 s output drain at `Subprocess.swift:87`.

`terminateAll` reuses the SIGTERM-then-SIGKILL pattern already proven in `WineServerHousekeeping.terminate` (`WineServerHousekeeping.swift:107-112`).

### 4.4 SetupLog

`~/Library/Logs/OpenXE/setup.log`, session-appended, sibling to the existing `wine.log`. **Every subprocess spawned during setup gets a `logHandle`** — closing the gap at `PrefixManager.swift:64-66, 71-72, 211, 216-219` and `EngineManager.swift:300-303, 360-363`.

- Header per run: ISO-8601 timestamp, `runID`, OpenXE build ID (reuse `Runner.currentBuildID`, `Runner.swift:47-54`), macOS version, engine descriptor, free disk space.
- Per stage: begin/end markers with elapsed seconds, attempt number, and the resume decision taken.
- Subprocess output is teed verbatim, except `tar -xvf` (§5.2), which is sampled.
- Rotated at 5 MB: `setup.log` → `setup.log.1`, one generation kept. Rotation is a `moveItem`, no dependency.
- `SetupLog.tail(lines:)` feeds the disclosure triangle and the failure state, mirroring `Runner.logTail` (`Runner.swift:288-294`).

`wine.log` keeps its current role (program launches and the NWS silent install). The NWS install writes to both: `setup.log` for the setup narrative, `wine.log` for continuity with existing tooling.

---

## 5. Closing the silent gap

### 5.1 Stage 4 — sub-progress for the prefix build

`PrefixManager.ensurePrefix` (`PrefixManager.swift:49-148`) gains a progress callback. It runs seven sub-steps with intra-stage weights:

Weights below are **measured** (§3.1), not estimated.

| Sub-step | Source | Weight | Measured | UI detail line |
|---|---|---|---|---|
| 4a `wineboot --init` | `PrefixManager.swift:64-69` | 40 | 24 s | "Setting up Windows for the first time…" |
| 4b `wineserver -w` drain | `:71-72` | 2 | ~1 s | "Finishing background setup…" |
| 4c Mono/Gecko verify | `:78-84` | 1 | <0.5 s | "Checking .NET and browser support…" |
| 4d Retina / DPI / WPF registry | `:87-109` | 3 | 1.7 s | "Configuring display settings…" |
| 4e Font provisioning — **57 counted writes** | `:178-207` | 52 | ~32 s | "Registering fonts (N of 57)…" |
| 4f Folder linking | `:119-142` | 1 | <0.5 s | "Linking your Documents and Downloads…" |
| 4g Ready marker | `:144-147` | 1 | ~0 | "Finishing up…" |

**4e turns out to be the largest sub-step, not 4a** — 57 writes × 559 ms ≈ 32 s against the boot's 24 s. It is also the easiest to report: `FontProvisioning.substitutions` has a known count, so the loop emits `stageProgress` per write and the 559 ms cadence is itself a strong liveness signal. Over half of stage 4 becomes a visibly advancing counter for free.

**4a — heartbeat mechanism (verified by spike, §3.1).** `wineboot` gets a **dual signal**, and both parts are required because neither is sufficient alone:

1. **Streamed output.** `wineboot`'s combined output is teed to `SetupLog` as it arrives; the disclosure triangle shows the last line live. `Subprocess`'s readability handler (`Subprocess.swift:52-61`) already receives chunks — the change is to surface them, not to add plumbing. Measured worst gap with today's `WINEDEBUG`: **9.71 s** — marginal on its own.
2. **Prefix filesystem growth, polled at 1 Hz.** The prefix grows 1 → 2,027 files / 331 MB during the boot. A poll that records entry count and total size, emitting `stageProgress` whenever either advances. Measured worst gap on its own: **7.3 s** (the boot's final 7.3 s writes nothing).

**Union of the two: worst gap 4.47 s** — comfortable against the 10 s criterion (§14.1), with ~2.2× margin on a fast machine. The two signals are complementary by nature: filesystem growth covers the boot's quiet mid-section, and output covers its flat tail.

**`WINEDEBUG` stays exactly as it is — `+loaddll` is rejected.** The spike tested it: it cuts the output-only gap to 4.63 s, but combined with filesystem polling it scores *no better* than the untouched `fixme-all` (4.63 s vs 4.47 s). It is therefore all cost and no benefit:

- `WINEDEBUG` is set in `WineEnvironment.build` (`Paths.swift:65-72`), which is shared by `Runner.launch` and every `reg add`. Changing it there would add ~735 lines to *every app launch's* `wine.log`, so adopting it would require a setup-only override — a new divergence between the setup and launch environments for no measured gain.
- It adds ~101 KB of log per boot.

Leaving `Paths.swift:69` untouched is the cheapest correct outcome, and it removes the spec's largest unknown.

### 5.2 Stage 3 — sub-progress for unpack

`tar -xf` (`EngineManager.swift:300-303`) becomes `tar -xvf`. Each extracted path is one line; the coordinator counts lines and reports `filesSeen / expectedEntries`, a constant on the stage definition, clamped to 1.0 and degrading to indeterminate if exceeded.

**`expectedEntries` must be measured from real `tar -xvf` output during implementation — do not use 5,324.** That figure is the *installed* tree (`engine/gcenx-stable-11.0_1`), which is a lower bound on the archive: it excludes everything outside the `Contents/Resources/wine` subtree that `findWineRoot` discards (`EngineManager.swift:311-314`), and includes two files written after extraction (`descriptor.json`, `version`). Using it unadjusted would peg the sub-bar at 100 % partway through the unpack. The clamp makes that cosmetic rather than harmful, but the constant should still be right.

Log volume is bounded by writing every 200th line to `SetupLog` while counting all of them. This also makes `tar` a first-class liveness source, which removes any need for filesystem-size polling.

Quarantine stripping (`EngineManager.swift:357-364`) — `chmod -R` and `xattr -dr` over 5,324 entries — gets its own detail line ("Preparing the Windows files…"). It currently has no progress case at all.

---

## 6. State, journal, and resume

### 6.1 Stage state machine

```
  pending ──▶ running ──▶ completed          (terminal, success)

  running ──▶ stalled                        watchdog: 60 s without evidence of life
  stalled ──▶ running                        user chose Keep Waiting, or output resumed
  stalled ──▶ cancelled                      user chose Cancel

  running ──▶ failed                         error, retry budget exhausted
  running ──▶ running                        error, retry budget remains (visible attempt)
  failed  ──▶ pending                        next run, attempt count carried forward
  failed  ──▶ cancelled                      user quit from the failure state

  running ──▶ cancelled                      user quit mid-stage
```

- `stalled` is a **UI state, not a terminal state.** The stage keeps running underneath; only the presentation escalates.
- `failed` is terminal for the run but not for the journal — the stage returns to `pending` on the next run, with its attempt count carried forward.
- `cancelled` is terminal for the run. Completed stages before it stay completed.
- The overall run is `succeeded` only when all six stages reach `completed`.

### 6.2 Journal schema

`~/Library/Application Support/OpenXE/setup-journal.json`, written after every stage transition via write-to-temp + `FileManager.replaceItemAt` (atomic; a crash mid-write cannot corrupt it).

```json
{
  "schemaVersion": 1,
  "runID": "9C1E…-UUID",
  "startedAt": "2026-08-08T20:31:04Z",
  "updatedAt": "2026-08-08T20:36:22Z",
  "outcome": "running",
  "engineID": "gcenx-stable-11.0_1",
  "engineSHA256": "b50dc50e…",
  "archiveVerified": true,
  "nwsTag": "8.2.1460",
  "nwsExpectedSize": 50331648,
  "stages": {
    "preflight":     { "state": "completed", "attempts": 1, "elapsedSeconds": 1.8,
                       "completedAt": "2026-08-08T20:31:06Z", "lastError": null },
    "downloadEngine":{ "state": "completed", "attempts": 2, "elapsedSeconds": 141.2,
                       "completedAt": "2026-08-08T20:33:27Z",
                       "lastError": { "kind": "network", "detail": "timed out", "at": "…20:32:0…" } },
    "unpackEngine":  { "state": "completed", "attempts": 1, "elapsedSeconds": 58.9,
                       "completedAt": "2026-08-08T20:34:26Z", "lastError": null },
    "preparePrefix": { "state": "running",   "attempts": 1, "elapsedSeconds": null,
                       "startedAt": "2026-08-08T20:34:26Z", "lastError": null },
    "downloadNWS":   { "state": "pending",   "attempts": 0, "elapsedSeconds": null, "lastError": null },
    "installNWS":    { "state": "pending",   "attempts": 0, "elapsedSeconds": null, "lastError": null }
  }
}
```

- `outcome` ∈ `running | succeeded | failed | cancelled`. A `running` outcome found at startup means the previous run died without unwinding (force-quit or crash) — the sweeper (§8.3) reconciles it to `cancelled`.
- `attempts` accumulates **across runs**, so a user failing the same stage four times is visible to us in the journal and the log.
- `elapsedSeconds` on completed stages feeds ETA recalibration (§7.3).
- Unknown keys are ignored on decode; a `schemaVersion` the build does not recognise causes the journal to be discarded and rebuilt from ground truth. Never a hard failure.

**The journal is advisory. The filesystem is authoritative.** This is the load-bearing rule of the design. On every run the coordinator recomputes ground truth (`EngineManager.isActiveInstalled`, `PrefixManager.isReady`, `NWSInstaller.isInstalled`) and reconciles the journal to it. The journal supplies only what the filesystem cannot express: attempt counts, error history, elapsed times, the chosen NWS tag, and whether a `.partial` archive was already checksum-verified. A journal that claims a stage is complete when the filesystem disagrees loses.

### 6.3 Resume decision per stage

| Stage | Ground-truth predicate | Journal contribution | Decision |
|---|---|---|---|
| 1 `preflight` | none | last result (informational) | **Always re-run.** Costs ~2 s and disk/Rosetta state can change between runs. |
| 2 `downloadEngine` | `EngineManager.isInstalled(id)` (`EngineManager.swift:144-149`); size of `engine/download-<id>.partial` (`:208`) | `archiveVerified`, `engineSHA256` | Engine installed → **skip**. Verified archive present → **skip**. `.partial` present and < 7 days old and `engineSHA256` matches the catalog → **resume via HTTP Range** (`:257-262`). Otherwise → **fresh download**. |
| 3 `unpackEngine` | `EngineManager.isInstalled(id)` — true only when `descriptor.json` exists, which after §9 is the atomic commit point | — | Installed → **skip**. Otherwise → delete any `engine/<id>` and any `engine/staging-*`, **re-run from the verified archive** (no re-download). |
| 4 `preparePrefix` | `PrefixManager.isReady` (`PrefixManager.swift:44-47`) | attempts only | Ready → **skip**. Otherwise → **wipe the prefix entirely and rebuild** (`:55-58`). No partial credit, by decision. |
| 5 `downloadNWS` | `NWSInstaller.isInstalled`; size of the new `.partial` | `nwsTag`, `nwsExpectedSize` | NWS installed → **skip** (the wizard still offers explicit reinstall). `.partial` present and journal `nwsTag` equals the selected tag → **resume via Range**. Tag differs → **discard and fresh**. |
| 6 `installNWS` | `NWSInstaller.isInstalled` (`NWSInstaller.swift:156-168`) | attempts only | Installed → **skip**. Otherwise → **re-run the installer**; Inno `/VERYSILENT` is idempotent over an existing install (`:293-310`). |

**Stage 4 is deliberately all-or-nothing.** A half-initialised prefix — registry written but Mono unverified, or fonts half-registered — is a silent-corruption hazard that would surface weeks later as unexplainable NWS behaviour with no diagnostic trail. Wiping costs the user the stage's ~3 minutes; not wiping costs us a bug class we cannot debug. See §11 R1 for the cost this imposes on cancel UX.

---

## 7. Progress UI

### 7.1 Layout

The wizard's setup step (`WizardWindow.swift:263-307`) is replaced by a calm, fixed layout. Nothing moves except the bar, the counters, and the detail line.

```
  Setting up New World Scheduler

  Step 4 of 6 — Preparing the Windows environment
  ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░░  71%
  Registering fonts (23 of 57)

  3 min 12 sec elapsed · about 1 min remaining

  ▸ Details                                    [ Cancel ]
```

*(The 71 % is worked through, not decorative: stages 1–3 complete = 1 + 33 + 22 = 56; within stage 4, sub-steps 4a–4d = 40 + 2 + 1 + 3 = 46 of 100, plus fonts at 23/57 × 52 = 21.0, giving 67.0 % of a 22-weight stage = 14.7. Total 70.7 %. Elapsed follows the same arithmetic: 152 s for stages 1–3, 27 s through 4d, 12.9 s of font writes = 192 s. Any implementation whose bar disagrees with this walkthrough has a weighting bug.)*

Expanded:

```
  ▾ Details                                    [ Cancel ]
    wine: registering FontSubstitutes\Consolas → Courier New
    ~/Library/Logs/OpenXE/setup.log            [ Show Log ]
```

- **One determinate overall bar**, weighted per §4.2. It never resets and never runs backwards; a retry within a stage holds the bar at the stage's start-of-stage value rather than rewinding.
- **"Step N of 6"** with the plain-English stage name. No Wine vocabulary above the fold.
- **Detail line** — one sentence, the current sub-step. Counters where a count exists (fonts 23/57, files 4210/5324, download 62%).
- **Elapsed and remaining**, both always present. Elapsed is exact; remaining is qualified with "about".
- **Disclosure triangle**, collapsed by default, state persisted in `UserDefaults` under `OpenXESetupDetailsExpanded`. Reveals the last log line and a **Show Log** button that reveals `setup.log` in Finder (mirroring `AppDelegate.swift:233-235`).
- **Cancel** button, always enabled during work, wired to the same confirm sheet as the close button (§8.1).

### 7.2 Stall presentation

On `.stalled` the layout does not jump. The bar switches to indeterminate, the detail line is replaced, and two buttons appear:

```
  Step 4 of 6 — Preparing the Windows environment
  ▓▒▓▒▓▒▓▒▓▒▓▒▓▒▓▒▓▒▓▒▓▒▓▒▓▒▓▒▓▒▓▒▓▒▓▒▓▒▓▒
  This is taking longer than usual. It may still be working.

  6 min 20 sec elapsed · 1 min 4 sec since the last sign of activity

  ▸ Details              [ Cancel ]  [ Keep Waiting ]
```

On `.recovered` it reverts to the normal layout without ceremony.

### 7.3 ETA

`remaining = (Σ weights of incomplete stages) × secondsPerWeightUnit`, where `secondsPerWeightUnit` starts at the reference `392 / 100 = 3.92 s` and is recalibrated after each completed stage from that stage's actual elapsed time against its weight. Within a byte-bounded stage, the in-stage remainder uses observed throughput rather than the weight.

**Suppression rule.** No remaining-time estimate is shown until at least one stage has completed *or* 15 s of download throughput has been observed — whichever comes first. Until then the line reads only elapsed time. An early ETA computed from nothing is worse than no ETA.

Displayed granularity is coarse on purpose: "less than a minute", then whole minutes. A counter ticking second-by-second invites the user to watch it and distrust it.

### 7.4 The launch path shares the same stream

`AppDelegate.runSetupThenLaunch` (`AppDelegate.swift:75-109`) currently duplicates orchestration and has its own copy of the messages — which is how the size strings drifted apart in the first place. It is replaced by a `SetupCoordinator` run over the stage subset `[preflight, downloadEngine, unpackEngine, preparePrefix]`, rendered by `ProgressWindowController` upgraded to consume `SetupEvent`. Weights renormalise over the subset. This deletes code rather than adding it, and structurally prevents the two paths from diverging again.

---

## 8. Cancel, quit, and cleanup

### 8.1 Confirm sheet

`WizardWindowController` gains `windowShouldClose(_:)`. While `SetupCoordinator` is running it returns `false` and presents a sheet:

> **Setup is still running**
> About 2 minutes left. If you quit now, OpenXE will stop cleanly. The Windows environment is not finished, so this step will start over next time — the parts already downloaded are kept.
>
> [ Keep Installing ]  [ Quit Setup ]

- The second paragraph is **stage-dependent and must state what is lost.** During stages 2, 3, 5 it says the downloaded parts are kept and setup will pick up where it left off. During stages 4 and 6 it says that step will start over. This is a direct consequence of the atomic-prefix decision and must not be softened — telling a user "you can resume" and then re-running three minutes of prefix work is worse than telling them the truth.
- "Keep Installing" is the default button. Escape maps to it.
- The in-wizard **Cancel** button presents the identical sheet through the same code path.

### 8.2 ⌘Q and the main menu

`main.swift:8-12` gains a minimal `NSMenu`: an application menu (About OpenXE, Quit ⌘Q) and a standard Edit menu so text fields in the settings and per-app windows behave correctly. This is the smallest addition that makes ⌘Q exist; it does not give the app a Dock presence and does not affect `LSUIElement`.

`AppDelegate` gains `applicationShouldTerminate(_:)`. If setup is running it returns `.terminateLater` and presents the §8.1 sheet, replying via `NSApp.reply(toApplicationShouldTerminate:)` with the user's choice. Otherwise `.terminateNow`. This covers ⌘Q, Apple-menu quit, and logout.

Force-quit remains uncoverable — no process can handle `SIGKILL`. The startup sweeper (§8.3) is the answer for that case, which is why it is not optional.

### 8.3 Cancel sequence

`SetupCoordinator.cancel()`, in order:

1. Set the `cancelled` flag; stop the stall detector.
2. `ChildRegistry.terminateAll()` — SIGTERM, 400 ms, SIGKILL.
3. `PrefixManager.shutdownServer()` (`PrefixManager.swift:157-163`) if stage 4 had started, so no daemonised `wineserver` outlives the cancel. This matters: `wineboot` starts a server that double-forks and is not in the child registry.
4. Write the journal with `outcome: "cancelled"` and the interrupted stage marked `cancelled`.
5. `SetupSweeper.sweep()` — remove `engine/staging-*` and any incomplete `nws-download/` contents. **Preserve** `download-<id>.partial` and a verified archive; they are the resume state.
6. Emit `.cancelled`, close the window, terminate.

### 8.4 Startup sweep

`SetupSweeper.sweep()` runs from `applicationDidFinishLaunching` (`AppDelegate.swift:35-50`) **before** any UI decision, and again after any cancel. It is the only defence against force-quit and crash.

| Artefact | Rule | Rationale |
|---|---|---|
| `engine/staging-*` | Delete unconditionally | Nothing legitimately holds one outside an active run, and no run is active at startup. Up to 666 MB each. Currently leaked forever (`EngineManager.swift:295-297`). |
| `nws-download/` | Delete if no `.partial` inside, or if the journal's `nwsTag` is absent | Transient; `cleanupDownloads` only fires on success (`WizardWindow.swift:438`). |
| `engine/download-*.partial` | Delete only if older than **7 days** | Valuable resume state. Age-gate rather than blanket-delete. |
| Journal with `outcome: "running"` | Rewrite to `cancelled`, preserving stage states and attempt counts | Detects the force-quit/crash case and keeps the history. |
| Orphaned `wineserver` for the prefix | `WineServerHousekeeping.sweepStaleServer` (`WineServerHousekeeping.swift:122-139`) | Already exists but is only reachable from `Runner.ensureWineserverWarm` (`Runner.swift:66-75`), so a wizard-only session never triggers it. Hoisting the call to startup fixes that. |

Every sweep action is logged to `setup.log` with the reclaimed byte count.

---

## 9. Failure handling

### 9.1 Error taxonomy

`EngineError`, `PrefixError`, and `NWSError` keep their current definitions and messages. They are wrapped, not replaced:

```swift
public struct SetupFailure: Error, Sendable {
    public enum Kind: String, Codable {
        case diskSpace, rosettaMissing, network, rateLimited, integrity,
             subprocessFailed, timedOut, stalled, environmentIncomplete, internalError
    }
    public let stage: SetupStage.ID
    public let kind: Kind
    public let userMessage: String       // plain English, no Wine vocabulary
    public let suggestedAction: String   // what to try
    public let technicalDetail: String   // underlying error + log tail
    public let isRetryable: Bool
}
```

| Kind | Trigger | User message (abridged) | Retryable |
|---|---|---|---|
| `diskSpace` | preflight, or `ENOSPC` mid-stage | "Your Mac needs about 2 GB of free space. It currently has N GB." | after freeing space |
| `rosettaMissing` | preflight on Apple Silicon | Existing Rosetta prompt (`AppDelegate.swift:177-193`), reused | yes |
| `network` | `NWSError.network`, `EngineError.downloadFailed` | "OpenXE couldn't reach the download server. Check your internet connection." | yes |
| `rateLimited` | `NWSError.rateLimited` | Existing message; auto-falls back to the vendor URL (`NWSInstaller.swift:236-242`) | automatic |
| `integrity` | `EngineError.checksumMismatch`, `NWSError.sizeMismatch` | "The download didn't arrive intact. OpenXE will try again." | yes, auto |
| `subprocessFailed` | non-zero `tar`/`wineboot`/`reg`/installer exit | "The Windows environment couldn't finish setting up." | yes, manual |
| `timedOut` | `SubprocessError.timedOut` | "That step took too long and was stopped." | yes, manual |
| `environmentIncomplete` | `PrefixError.monoOrGeckoMissing` | "Windows support files are missing. Setup will rebuild the environment." | yes, forces stage 4 rebuild |
| `internalError` | anything unmapped | Generic + log pointer | yes |

### 9.2 Retry policy

```swift
public struct RetryPolicy: Sendable {
    public let maxAttempts: Int
    public let baseDelay: TimeInterval
    public let multiplier: Double
    public let jitter: Double        // ±fraction
}
```

- **Network stages (2, 5): 3 attempts, base 2 s, ×4, ±25 % jitter** → ~2 s then ~8 s. Every retry emits `.attempt(stage, number:of:reason:)`, so the UI shows "Connection failed — trying again (2 of 3)…". Silent retries are forbidden.
- **Integrity (the checksum that terminates stage 2, per §4.2): 2 attempts.** This preserves the existing behaviour at `EngineManager.swift:211-225` but **makes it visible** — today a checksum retry restarts the percentage from zero with no explanation, which reads as a spontaneous failure. The integrity budget is separate from and consumed after the network budget: three connection failures exhaust the stage, and a connection that succeeds but delivers corrupt bytes gets two whole-file attempts.
- **Subprocess stages (4, 6): 1 attempt, manual retry only.** Automatically re-running a 3-minute `wineboot` that just failed is unlikely to help and burns the user's time. The failure state's "Try Again" button is the retry.
- Retry delays are cancellable — a user hitting Quit during a backoff does not wait it out.

### 9.3 Failure state

Failure becomes a real wizard state, replacing the red label at `WizardWindow.swift:151-154, 289-291, 442-453`:

```
  Setup couldn't finish

  OpenXE couldn't reach the download server.

  This usually means the internet connection dropped. The parts
  already downloaded have been saved, so trying again will pick
  up where it left off.

  ▸ Details

              [ Show Log ]        [ Try Again ]
```

- **Try Again** is the primary button and re-enters the coordinator, which recomputes resume decisions per §6.3 — so a retry genuinely resumes rather than restarting.
- **Show Log** reveals `setup.log` in Finder.
- The window title bar and the step counter stay visible so the user knows how far they got.

### 9.4 Notification

Setup is a walk-away operation, so completion and failure both notify:

- `UNUserNotificationCenter`, authorization requested lazily at the start of stage 2 (not at launch — no prompt for a user who never starts setup).
- **Fallback, required:** if authorization is denied or unavailable, `NSApp.requestUserAttention(.criticalRequest)` plus activating the window. See §11 R5 — an ad-hoc-signed, non-notarized `LSUIElement` app is not guaranteed a working notification path, so the fallback is not optional garnish.
- Notifications fire only when OpenXE is not frontmost.

### 9.5 Preflight (stage 1)

New, and it runs on **both** the wizard and launch paths — closing the gap where `ensureRosetta` is reachable only from the launch path (`AppDelegate.swift:59`), so a wizard user without Rosetta 2 today downloads 177 MB before failing cryptically at `wineboot`.

1. **Free space.** Require **2.0 GB** on the Application Support volume: 1.41 GB measured need (§3) plus ~0.6 GB headroom for APFS overhead, logs, and the transient archive. Read via `URLResourceValues.volumeAvailableCapacityForImportantUsage` — Foundation, no dependency. Failure is `diskSpace` with the actual figure quoted.
2. **Rosetta 2.** Reuse `RosettaCheck.canRunX86_64` (`Runner.swift:324-330`) and the existing install prompt.
3. **Write access** to `paths.root` and the log directory.
4. **Network reachability is deliberately not checked.** A reachability probe adds a failure mode of its own and tells us nothing the first real request will not. Stage 2's retry policy is the answer.

---

## 10. Additional corrections

### 10.1 The unrecoverable-state fix

`extractAndInstall` (`EngineManager.swift:293-330`) currently writes `descriptor.json` (`:324`), then `version` (`:326`), then calls `stripQuarantine` (`:329`). A kill between `:326` and `:329` leaves an engine that passes `isInstalled` (`:144-149`) but whose Wine binaries are still quarantined and possibly read-only. Gatekeeper blocks them, every later run fails opaquely at `wineboot`, and **no code path ever re-runs the strip**. Only a manual wipe recovers. This is the one true wedge in the current design.

**Fix — make `descriptor.json` the atomic commit point.** Reorder to:

1. `moveItem` the wine root into `engine/<id>/wine` (`:319`)
2. `stripQuarantine(at: engineDir)` (moved up from `:329`)
3. write `version` (`:326`)
4. write `descriptor.json` **last**, via write-to-temp + `replaceItemAt`

After this, `descriptor.json`'s existence means "fully installed and de-quarantined". Any kill before step 4 leaves an engine that correctly reports not-installed, and stage 3's resume rule (§6.3) wipes and re-extracts from the already-verified archive.

### 10.2 Resumable NWS download

`NWSInstaller.download` (`:244-284`) deletes the destination at `:249` and always fetches the full ~48 MB. It gains the same Range-resume logic already proven in `EngineManager.download` (`:254-289`), including that method's correct handling of the 200 / 206 / 416 status cases (`:270-288`), which covers a server that ignores the range header.

The vendor fallback URL (`:28-29`) redirects to the same GitHub asset, but its range support through the redirect is unverified — the 200 case already degrades to a full download, so this is safe by construction.

### 10.3 Size copy

One constant, three sites: `WizardWindow.swift:256`, `AppDelegate.swift:79`, `ProgressWindow.swift:58`. Canonical text: *"a one-time download of about 177 MB, which expands to about 700 MB on your Mac."*

---

## 11. Risks and open questions

**R1 — The atomic prefix makes cancel expensive, by decision — but far less than first thought.** Stage 4 is the one stage that cannot resume, so quitting near its end discards the whole of it. The original draft put that at 46 % of the run and ~3 minutes of lost work, which made the settled resume-granularity decision look costly. **Measurement (§3.1) revised it to 22 % and ~59 s.** Losing a minute is a materially easier thing to explain in the confirm sheet than losing three, so the decision now carries much less UX debt than flagged. The mitigation remains honesty in the sheet (§8.1), not engineering.

*Cheapest future relief, if it ever bites:* not sub-checkpointing, but making stage 4 faster. The spike showed **fonts (4e) are 52 % of the stage — ~32 s across 57 spawned `wine reg add` processes at 559 ms each.** Batching them into a single `regedit` file import would plausibly remove most of it and shrink the non-resumable window to ~27 s. Attractive, and now quantified. Still out of scope here — noted, not specified.

**R2 — ETA will sometimes be visibly wrong.** Static weights assume a reference network. On a 5 Mbit link stage 2 alone can exceed the whole reference run, inverting the weighting until recalibration kicks in after stage 2 completes. §7.3's suppression rule and coarse granularity reduce the damage but do not remove it. A visibly wrong estimate erodes trust in the whole panel — the exact problem this work exists to fix. Accepted with mitigation; worth revisiting if testing shows it misleads.

**R3 — RESOLVED by spike, 2026-08-08.** Was: "the `wineboot` heartbeat is unproven, the single largest unknown in the spec." Measurement (§3.1) found a working signal: **output ∪ 1 Hz prefix filesystem growth, worst gap 4.47 s** against a 10 s criterion, with `WINEDEBUG` left untouched. `+loaddll` was tested and rejected as no better than the free option. The residual risk is only that both figures come from a fast M2 with a warm Rosetta cache — see R2a.

**R2a — Stage weights rest on two remaining estimates and one warm-machine measurement.** Stages 2 (download, network-dependent) and 3 (unpack) were never measured; stage 4's 59 s came from a machine that had already Rosetta-translated the engine. On a cold, slower Mac all three grow, and not by the same factor — so the *ratios* that drive the bar may shift even though each absolute figure is a floor. §7.3's recalibration absorbs this within a run, but the first run on a new machine is exactly the one a user watches. Mitigation is the cold calibration in §13.4; until then, treat the weights as good defaults rather than settled constants.

**R4 — Stall-watchdog false positives.** 60 s of silence is a heuristic. A slow Mac doing genuine work during Mono installation could trip it. The design deliberately makes `stalled` non-terminal and "Keep Waiting" cheap (it resets the detector and doubles the threshold to 120 s), so a false positive costs one click, not a failed setup. The threshold is a tunable constant, not a hardcoded literal.

**R5 — Notifications may not work at all.** An ad-hoc-signed, non-notarized `LSUIElement` app has no guarantee of `UNUserNotificationCenter` authorization, particularly when launched from a non-standard location. The `requestUserAttention` fallback (§9.4) is mandatory for this reason.

**R6 — `Subprocess.run` blocks a cooperative thread.** Pre-existing (`Subprocess.swift:74-82`), and this design multiplies the call count — stage 4 alone makes 60+ blocking calls. It has not caused an observed problem, but the correct home for setup subprocess work is a dedicated serial `DispatchQueue`, not the cooperative pool. The spec authorises that change; it does not require it, and it should not gate the rest.

**R7 — Two renderers, one stream.** `WizardWindow` and `ProgressWindow` both consume `SetupEvent`. That is the point (§7.4) — but it is also how the size strings drifted apart. The mitigation is that neither renderer may hold orchestration logic or compose its own stage text; all user-facing copy lives in `SetupCopy`.

**R8 — Journal-versus-filesystem divergence.** The advisory-journal rule (§6.2) is what keeps this safe, and it must be enforced in code, not convention. Every resume decision must begin from a ground-truth predicate. A future change that lets the journal short-circuit a filesystem check reintroduces the entire bug class.

---

## 12. Budget and constraints

**Zero dependencies — held.** Everything specified uses Foundation, Dispatch, AppKit, CryptoKit, and UserNotifications. `UserNotifications` is the only framework not already linked; it is a system framework, not a package.

**Size budget — held with room.** The binary is 879 KB today against a 5 MB budget. The new code is roughly 900–1,200 lines of Swift with no generated code or resources; the expected contribution is well under 150 KB, leaving over 3.9 MB of headroom. No new bundled resources.

**Charter boundaries — held.** Wine remains an unmodified subprocess. No GPL code. No new UI surface beyond the setup panel's disclosure triangle and the minimal main menu (§8.2) — the menu is a correctness fix for a missing ⌘Q, not a feature.

**Where this pushes.** The main menu is the one addition that touches the "faceless app" principle in design spec §4.4. It is defensible: an accessory app with a window the user cannot quit from is a defect, not minimalism. It adds no Dock presence and no menu-bar item while idle.

---

## 13. Testing

### 13.1 Unit (in `Tests/OpenXECoreTests`, no network, no Wine)

- **Journal state machine** — every legal transition; illegal transitions rejected; attempt counts accumulate across simulated runs; atomic write survives a simulated mid-write crash; unknown `schemaVersion` discards cleanly; unknown keys ignored.
- **Resume decisions** — all six stages × the ground-truth/journal combinations in §6.3, driven by a temp-directory fixture. Explicitly including the case where the journal claims completion and the filesystem disagrees: the filesystem must win.
- **Stage weighting** — weights sum to 100; subset renormalisation for the launch path (§7.4); the overall fraction is monotonic across a scripted event sequence, including retries.
- **ETA** — suppression rule holds before the first data point; recalibration after a stage completes; no negative or `NaN` output.
- **Sweep logic** — `staging-*` always removed; `.partial` preserved at 6 days, removed at 8; `nws-download` rules; `outcome: "running"` reconciled to `cancelled`.
- **`SetupFailure` mapping** — every `EngineError`, `PrefixError`, and `NWSError` case maps to exactly one `Kind` with a non-empty user message and suggested action. A `switch` with no `default`, so a new error case fails the build rather than falling through to `internalError`.
- **`ChildRegistry`** — register/deregister under concurrency; `terminateAll` on a short-lived `/bin/sleep` fixture; `liveCount` returns to zero.
- **`SetupLog`** — rotation at threshold; `tail` correctness on empty, short, and rotated logs.

### 13.2 Fault injection

A `SetupEnvironment` seam (injected URLs, an injectable `Subprocess` runner, an injectable clock) lets each failure mode be provoked deterministically:

| Mode | Injection | Expected |
|---|---|---|
| Network drop mid-download | Fixture server closes the connection at 40 % | 3 visible attempts, backoff honoured, `.partial` preserved, resume on retry |
| Bad checksum | Fixture serves corrupted bytes | 2 visible attempts, poisoned artefact deleted, `integrity` failure |
| Disk full | Preflight forced under threshold; `ENOSPC` from the injected runner | `diskSpace` failure with the real figure quoted; no partial engine committed |
| Non-zero exit | Injected runner returns status 1 for `wineboot` | `subprocessFailed`, prefix wiped, "Try Again" re-runs stage 4 from scratch |
| Stall | Injected runner produces no output and does not exit | `.stalled` after 60 s; Keep Waiting resets and doubles; Cancel kills the child |
| Force-quit | `SIGKILL` the test host mid-stage | Next start: sweeper removes staging, reconciles journal to `cancelled`, resume decisions correct |

### 13.3 Manual matrix (added to `docs/smoke-checklist.md`)

Cancel at **each of the six stages**, then verify for every one:

- [ ] No `wine`, `wineserver`, or `tar` process survives (`pgrep` against the engine path)
- [ ] No `engine/staging-*` remains
- [ ] `.partial` preserved where §6.3 says it should be, absent where it should not
- [ ] Journal `outcome` is `cancelled` and the interrupted stage is marked correctly
- [ ] Next launch resumes at the documented stage and does not redo completed work
- [ ] `setup.log` contains the full narrative of both runs

Plus: `make fresh` end-to-end with the notification path exercised; ⌘Q during each stage; the confirm sheet's stage-dependent wording verified against §8.1 for a resumable and a non-resumable stage.

### 13.4 Cold-machine weight calibration

The §4.2 weights rest on two estimates and one warm-machine measurement (R2a). One calibration run closes this, and it needs no new tooling — `SetupLog` already records per-stage elapsed times (§4.4).

- Run `make fresh` on a Mac that has **never** run the engine (no Rosetta AOT cache), on a metered-bandwidth connection, and record all six stage durations from `setup.log`.
- Recompute the weights from those durations and update §4.2 if any weight moves by more than ±5 points.
- The developer's own Mac cannot serve for this: its Rosetta cache is warm and cannot be selectively cleared. **This step requires either a second machine or a user decision to accept the current defaults** — flagged rather than assumed.
- The measured 59 s stage-4 floor is a useful lower bound to check the result against: a cold run below it means the run was not actually cold.

---

## 14. Acceptance criteria

1. No stage goes more than **10 seconds** without *substantive* evidence of progress — a counter advance, a percentage change, or a new streamed log line. A ticking elapsed-time display does **not** satisfy this criterion; it ticks unconditionally and would make the requirement unfalsifiable.
   - **No exceptions.** The spike (§3.1) confirmed every stage can meet this, including 4a, whose dual signal measured a 4.47 s worst gap. The earlier draft reserved an exception for 4a; it is no longer needed and must not be reintroduced without new measurement.
   - Verified by instrumenting a real run and asserting the maximum inter-event gap, not by inspection.
2. `setup.log` exists after any setup attempt, successful or not, and contains a stage-by-stage narrative with timings and the resume decisions taken.
3. Closing the window, clicking Cancel, or pressing ⌘Q during setup always presents the confirm sheet; choosing Quit leaves zero orphaned processes and zero `staging-*` directories.
4. Force-quitting during any stage leaves state that the next launch sweeps and resumes correctly.
5. Every failure mode in §13.2 produces a wizard failure state with a plain-English cause, a working Try Again, and a working Show Log — never a bare error label.
6. No run of setup can produce an engine that reports installed while still quarantined.
7. Setup can be interrupted and resumed at each stage boundary without redoing completed stages, with the sole documented exception of the prefix build.
8. The app binary stays under 5 MB and gains no third-party dependency.
