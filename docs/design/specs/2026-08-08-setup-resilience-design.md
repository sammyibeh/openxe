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

Every weight, threshold, and string in this spec derives from measurements taken on the developer's Mac against the pinned engine `gcenx-stable-11.0_1`: the spikes of 2026-08-08 (§3.1, §3.2) and the full-run calibration of 2026-08-09 (§3.3), which supersedes them as the source of the §4.2 weights.

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

### 3.2 Font-batching spike (2026-08-08)

Ran both font-provisioning methods on two freshly-booted throwaway prefixes and diffed the resulting registry subtrees.

| Quantity | Measured |
|---|---|
| 57 individual `wine reg add` calls | **24.38 s** |
| One `wine regedit fonts.reg` import | **1.54 s** |
| Speedup | **15.8×, saving 22.8 s** |
| Registry equivalence | **Byte-identical.** 647 value lines each, across all five affected keys |

The diff covered `Software\Wine\Fonts\Replacements` (user.reg), and both the native and `Wow6432Node`-redirected views of `…\CurrentVersion\FontSubstitutes` and `…\CurrentVersion\Fonts` (system.reg). The WoW64 redirection was checked deliberately: `reg add` and `regedit` could plausibly have landed in different views, and they do not.

> **Method note.** The first run of this comparison reported "identical" from two *empty* extractions — `awk -v` consumes backslashes, so the registry key patterns never matched. The figures above are from the corrected extraction, which recovers 647 value lines per side. An equivalence result that compares nothing looks exactly like a pass.

**Caveat on all of the above.** The machine had already Rosetta-translated and cached the engine's binaries. A genuine first run on a friend's Mac pays one-time Rosetta AOT translation that these runs did not, so every figure here is **a floor, not a typical cold value** — the 24 s boot, the 559 ms per `reg add`, and the 1.54 s import alike. The weights in §4.2 no longer derive from these numbers; they come from the full-run calibration in §3.3. The spike figures remain the source for the stage-4 mechanism decisions (§5.1) and the sanity floor in §13.4.

### 3.3 Full-run calibration (2026-08-09) — the source of the §4.2 weights

One instrumented run of the whole wizard on a freshly reset install, timings taken from `setup.log`.

| | |
|---|---|
| Date | 2026-08-09 |
| Machine | macOS 27, build 26A5388g, Apple Silicon |
| Engine | `gcenx-stable-11.0_1` (the pinned `EngineCatalog.stock`) |
| Total across the six stages | **464.8 s** |

| Stage | Measured | Share | Weight (§4.2) |
|---|---|---|---|
| `preflight` | 0.4 s | 0.09 % | **1** |
| `downloadEngine` | 314.1 s | 67.58 % | **67** |
| `unpackEngine` | 14.1 s | 3.03 % | **3** |
| `preparePrefix` | 37.5 s | 8.07 % | **8** |
| `downloadNWS` | 81.1 s | 17.45 % | **17** |
| `installNWS` | 17.6 s | 3.79 % | **4** |

Weights are the shares rounded by largest remainder to integers summing to exactly 100. `preflight` is floored up to 1 so its segment is not zero-width, and that 1 is taken off `downloadEngine`'s 68.

**This is substantially a bandwidth snapshot, not a machine constant.** Both download stages are network-bound — NWS transferred at 618 KB/s, ~4.9 Mbit/s — and together they take **84 %** of the run. On a fast connection that share collapses and these weights are wrong in the opposite direction: `downloadEngine` far too heavy, `preparePrefix` and `installNWS` far too light. They are one link on one afternoon, recorded as such in the comment above `StageWeightTable.builtIn`. The §7.3 recalibration and the `OpenXEStageWeights` override are the two mechanisms that absorb it.

**Rosetta remains uncontrolled.** The AOT cache cannot be cleared on this machine (runbook §2), so `preparePrefix` and `installNWS` are still floors and §13.4's condition (a) for removing `useBatchedImport` stays unmet. What changed is that stages 2 and 3, which were pure estimates, are now measured.

Note the two spikes measured the per-write path independently and agreed closely: 32 s projected from 10 timed writes (§3.1) against 24.38 s for the real 57 (§3.2). The gap is warm-cache drift across runs; both support the same conclusion.

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

`detail` is the plain-English sub-line ("Unpacking… 4,210 files", "Setting up Windows for the first time…"). The technical line shown under the disclosure triangle comes from the tail of `SetupLog`, not from the event.

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

**The six stages and their weights.** Weights are the stage's share of a **measured** 464.8 s reference run (§3.3, 2026-08-09), rounded by largest remainder to sum to exactly 100.

> **Revised three times.** The prefix reference began as a 180 s estimate; direct measurement put it at 59 s (§3.1) and batching the font writes (§5.3) cut it to 29 s, taking stage 4's weight 46 → 22 → 12. The 2026-08-09 full-run calibration (§3.3) then replaced every remaining estimate with a measurement, and the picture changed shape: on that link the two download stages are 84 % of the run, so stage 2 rose 37 → **67** while stages 3 and 6 fell to 3 and 4. **These weights still assume batched fonts** (§5.3); reverting to the per-write path returns stage 4 to ~59 s and requires a recompute. **They also encode one connection's bandwidth** — see the caveat in §3.3.

| # | ID | Display name | Weight | Resumable | Retry | Ceiling |
|---|---|---|---|---|---|---|
| 1 | `preflight` | Checking your Mac | 1 | n/a | none | 15 s |
| 2 | `downloadEngine` | Downloading the Windows environment | **67** | **yes** (HTTP Range) | 3 × network, then 2 × integrity | 60 s idle |
| 3 | `unpackEngine` | Unpacking the Windows environment | **3** | no (restartable from the verified archive) | none (restart is free) | 900 s |
| 4 | `preparePrefix` | Preparing the Windows environment | **8** | **no — atomic** | none (manual only) | 900 s |
| 5 | `downloadNWS` | Downloading New World Scheduler | **17** | **yes** (new) | 3 × network | 600 s idle |
| 6 | `installNWS` | Installing New World Scheduler | **4** | no | none (manual only) | 1200 s |

Weights are static defaults. The ETA calculation (§7.3) rescales them from observed cost, so a slow network does not make the bar lie for the whole run.

**Weights are data, not logic.** They are a measurement of one machine on one connection (§3.3), so they will need correcting again. No code path may hardcode a weight: they live in one declarative table, and that table is resolved at startup as

```
UserDefaults "OpenXEStageWeights"  →  built-in defaults
```

The override is a dictionary of stage id to integer weight. It is accepted only if it names every stage exactly once, every value is positive, and the values sum to 100; an override failing any of those is ignored and the rejection logged, so a bad edit degrades to the shipped defaults rather than a broken bar. This makes a recalibration correctable with `defaults write dev.openxe.OpenXE OpenXEStageWeights …` and no rebuild — which matters for an ad-hoc-signed app where editing a bundled resource would invalidate the signature, and it is the escape hatch for a user whose connection is nothing like the one §3.3 measured.

The same applies to the stage-4 sub-step weights (§5.1) and to the two constants the spikes produced (`expectedArchiveEntries`, the stall threshold): each is a named value in one place, never an inline literal at a use site.

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
| 4a `wineboot --init` | `PrefixManager.swift:64-69` | **82** | 24 s | "Setting up Windows for the first time…" |
| 4b `wineserver -w` drain | `:71-72` | 3 | ~1 s | "Finishing background setup…" |
| 4c Mono/Gecko verify | `:78-84` | 2 | <0.5 s | "Checking .NET and browser support…" |
| 4d Retina / DPI / WPF registry | `:87-109` | 6 | 1.7 s | "Configuring display settings…" |
| 4e Font provisioning — **one batched import** (§5.3) | `:178-207` | 5 | 1.54 s | "Registering fonts…" |
| 4f Folder linking | `:119-142` | 1 | <0.5 s | "Linking your Documents and Downloads…" |
| 4g Ready marker | `:144-147` | 1 | ~0 | "Finishing up…" |

**Stage 4 is now dominated by 4a.** Before batching, fonts were 52 % of the stage and 4a only 40 %; after, 4a is 82 %. That is a real trade-off, not a free win — see §5.3.

**4a also gets a coarse determinate bar (closes §11 R3a).** Batching the fonts left 4a covering 82 % of stage 4 with liveness evidence only, which concentrated the stage's entire progress story on one mechanism. A completed `wineboot` produces **~2,027 files** in the prefix (measured, §3.1), so the same 1 Hz poll that supplies the liveness signal also supplies a fraction:

```
fraction(4a) = min(filesSeen / expectedPrefixEntries, 1.0)     // expectedPrefixEntries = 2027
```

**Advisory, clamped, and monotonic.** The reported value never decreases — a running maximum is kept, so a poll that transiently reads fewer entries cannot rewind the bar. A denominator that is wrong for some engine build degrades gracefully in both directions: too low and the bar saturates early then waits at 100 % on the heartbeat; too high and it advances slowly and completes on stage transition. Neither shows a *wrong* bar, only a lazy one. The count never gates completion — `wineboot` exiting does.

The heartbeat below and this counter run together and are independent: the counter answers "how far", the heartbeat answers "still alive".

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

**`expectedEntries` is measured, not estimated.** The obvious candidate — 5,324, the installed tree — is a lower bound on the archive: it excludes everything outside the `Contents/Resources/wine` subtree that `findWineRoot` discards (`EngineManager.swift:311-314`), and includes two files written after extraction (`descriptor.json`, `version`). Using it would peg the sub-bar at 100 % partway through the unpack.

The real value is obtained once, at implementation time, by listing the pinned archive without extracting it:

```
curl -L -o engine.tar.xz <EngineCatalog.stock.url>
tar -tf engine.tar.xz | wc -l
```

and recorded as `expectedArchiveEntries` alongside the other calibration constants (§4.2). It is re-derived only if the pinned engine changes. The clamp remains as a safety net, but the constant is not shipped as a guess.

Log volume is bounded by writing every 200th line to `SetupLog` while counting all of them. This also makes `tar` a first-class liveness source, which removes any need for filesystem-size polling.

Quarantine stripping (`EngineManager.swift:357-364`) — `chmod -R` and `xattr -dr` over 5,324 entries — gets its own detail line ("Preparing the Windows files…"). It currently has no progress case at all.

---

### 5.3 Batched font provisioning

`provisionFonts` (`PrefixManager.swift:178-207`) spawns 57 separate `wine reg add` processes — 28 substitutions × 2 registry tables, plus the bundled FontAwesome registration — at 559 ms each. Measured (§3.2): **24.38 s spawning processes to write 57 short strings.** Replacing them with a single generated `.reg` file imported by `regedit` costs **1.54 s**, a 15.8× improvement that removes ~23 s from the one stage that cannot be resumed.

**Generated file.** Written to a temporary path inside the prefix's own directory, deleted after import.

- **Format `REGEDIT4`, ASCII.** Chosen over `Windows Registry Editor Version 5.00` because that format expects UTF-16LE and buys nothing here: every family name in `FontProvisioning.substitutions` (`FontProvisioning.swift:44-82`) is ASCII, as is `FontAwesome.ttf`. ASCII keeps the generator trivial and side-steps a BOM/encoding failure mode that would be silent.
- Three key blocks, in this order: `HKEY_LOCAL_MACHINE\Software\Microsoft\Windows NT\CurrentVersion\Fonts` (the single FontAwesome value), `HKEY_LOCAL_MACHINE\Software\Microsoft\Windows NT\CurrentVersion\FontSubstitutes` (28 values), `HKEY_CURRENT_USER\Software\Wine\Fonts\Replacements` (28 values).
- Values are `"<from>"="<to>"`, one per line, generated from the same `FontProvisioning.substitutions` table that drives the per-write path. **The table stays the single source of truth** — the `.reg` file is generated from it, never hand-maintained.

**Invocation.** `wine regedit <path>` through the existing `Subprocess.run`, with the standard setup environment, a 120 s ceiling, and the `SetupLog` handle attached.

**Best-effort, exactly as today.** A non-zero exit, a missing `regedit`, or a write failure is logged and swallowed. Font provisioning must never fail the prefix build — that is the existing contract at `PrefixManager.swift:178-181` and it does not change. A prefix whose fonts did not register still boots and still runs NWS; it may fall back to a less pleasing face.

**The per-write path is retained**, behind `FontProvisioning.useBatchedImport` (default `true`). If the import proves unreliable on a machine we cannot inspect, flipping one flag restores the proven behaviour without a code revert.

**Removal condition, so the flag does not become permanent by default.** Both the flag and `provisionFontsPerWrite` are deleted once **(a)** one cold-machine run (§13.4) and **(b)** one real end-to-end install have both completed with the batched path. A fallback that is never exercised is not a safety net — it is a second code path that rots. Until then the flag stays; after both conditions are met it goes, in one commit, with `scripts/verify-font-batching.sh` retained as the regression guard.

**Equivalence is the acceptance bar, not absence of errors.** §3.2 records a byte-identical diff of all five affected registry keys, including the WoW64-redirected views. Any future change to the generator must reproduce that diff.

**The trade-off, stated plainly.** Batching removes the progress affordance that was going to cover half of stage 4: a 57-step counter ticking at 559 ms is excellent evidence of life, and a 1.5 s import is invisible. Stage 4 becomes 82 % `wineboot`, so the dual heartbeat of §5.1 — output plus filesystem growth — carries proportionally more weight than before. The net is still clearly favourable: 29 s of mostly-covered time beats 59 s of half-covered time, and the shortest non-resumable window is the one the user is least likely to sit through. But it does concentrate risk on R3's mechanism rather than diversifying away from it (§11 R3a).

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
  ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░░░  68%
  Setting up Windows for the first time…

  2 min 44 sec elapsed · about 1 min remaining

  ▸ Details                                    [ Cancel ]
```

*(The 68 % is worked through, not decorative: stages 1–3 complete = 1 + 37 + 25 = 63; within stage 4, `wineboot` (4a) is half done = 0.5 × 82 = 41 % of a 12-weight stage = 4.9. Total 67.9 %. Elapsed follows the same arithmetic: 152 s for stages 1–3 plus 12 s into a 24 s boot = 164 s. Any implementation whose bar disagrees with this walkthrough has a weighting bug.)*

*Note the detail line here is a heartbeat, not a counter — after font batching (§5.3), stage 4 is 82 % `wineboot`, which reports liveness rather than a fraction. The determinate counters now live in stage 3 (files unpacked) and the two download stages.*

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

`remaining = (Σ weights of incomplete stages) × secondsPerWeightUnit`, where `secondsPerWeightUnit` starts at the reference `464.8 / 100 = 4.648 s` (§3.3) and is recalibrated after each completed stage from that stage's actual elapsed time against its weight. Within a byte-bounded stage, the in-stage remainder uses observed throughput rather than the weight.

**The reference run was network-bound at ~4.9 Mbit/s (§3.3), so the initial estimate is wrong on any materially different connection — and now it errs long, not short.** On a fast link the download stages finish well inside their 84 % of the budget and the first estimate reads pessimistic; on slower hardware with the same link, the Rosetta-paying stages read optimistic. Either way the first number is a guess about someone else's machine. Two rules keep a confidently wrong number off the screen.

**Rule A — suppression before data.** No remaining-time estimate is shown until at least one stage has completed *or* 15 s of download throughput has been observed, whichever comes first. Until then the line reads only elapsed time. An early ETA computed from nothing is worse than no ETA.

**Rule B — suppression on overshoot.** If the in-flight stage's elapsed time exceeds its expected duration (`weight × secondsPerWeightUnit`) by a factor of **1.5 or more**, the numeric estimate is withdrawn and the line reads:

> `4 min 20 sec elapsed · still working — this can take longer on some Macs`

The estimate returns once the stage completes and recalibration has absorbed the real duration; subsequent stages then benefit from a `secondsPerWeightUnit` that reflects this machine and this link rather than the reference ones. Rule B is what makes a single-machine, single-link calibration safe to ship: where the weights are wrong, the ETA withdraws itself rather than counting down to a number it cannot meet.

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

Setup is a walk-away operation, so completion and failure both notify. But a permission dialog is itself an interruption, so **authorization is requested only once the run has given a concrete reason to want it.**

**Trigger, at most once per install, on the first of:**

1. **A `.stalled` event — the primary trigger.** The user has been waiting ≥60 s with no sign of life; this is precisely when a background notification becomes valuable, and it is a calm moment rather than a bad one.
2. **A `.failed` event, and only while OpenXE is not frontmost** — the secondary trigger.

Never at launch, never at the start of a stage, never during normal progress. A user whose install runs cleanly is never asked.

**Why the stall trigger is primary.** Stacking a permission dialog on top of an error message is the worst available timing: the user is already dealing with a failure and is being asked to make an unrelated decision about notifications. The stall trigger fires earlier in most bad runs anyway — 60 s of silence usually precedes a timeout or a subprocess failure — so in practice authorization is settled before any failure appears. The frontmost condition on trigger 2 closes the remaining case: if OpenXE is in front, the user is already looking at the error and needs no notification, so nothing is asked.

**Fallback, required and unconditional.** If authorization is denied, never requested, or unavailable, `NSApp.requestUserAttention(.criticalRequest)` plus activating the window. See §11 R5 — an ad-hoc-signed, non-notarized `LSUIElement` app is not guaranteed a working notification path, so this is the only mechanism guaranteed to work and it is not optional garnish.

Notifications themselves fire only when OpenXE is not frontmost.

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

**R1 — RESOLVED as a material risk.** Stage 4 is the one stage that cannot resume, so quitting near its end discards the whole of it. The original draft put that at 46 % of the run and ~3 minutes of lost work, which made the settled resume-granularity decision look costly. Two rounds of measurement and one optimisation reduced it to **~29 s** of work: first by measuring the stage honestly (§3.1), then by batching the font writes (§5.3). The cold run (§3.3) put it at 37.5 s and **8 %** of the bar. Roughly half a minute of lost work is a small enough cost that the atomic-prefix decision now carries essentially no UX debt, and the confirm sheet can state it without apology.

**R2 — ETA will sometimes be visibly wrong; the direction has now flipped.** Static weights encode a reference network, and after §3.3 that reference *is* a ~4.9 Mbit link where stage 2 alone is 67 % of the run. The failure mode is no longer "slow link inverts the weighting" — it is the mirror: on a fast link stage 2 finishes in a fraction of its budgeted share, the bar leaps forward, and the first estimate reads pessimistic until recalibration lands after stage 2. §7.3's suppression rules and coarse granularity reduce the damage but do not remove it. A visibly wrong estimate erodes trust in the whole panel — the exact problem this work exists to fix. Accepted with mitigation; worth revisiting if testing shows it misleads. **A second calibration on a materially faster connection is the cheapest thing that would resolve it** — two runs bracket the range, one does not.

**R3 — RESOLVED by spike, 2026-08-08.** Was: "the `wineboot` heartbeat is unproven, the single largest unknown in the spec." Measurement (§3.1) found a working signal: **output ∪ 1 Hz prefix filesystem growth, worst gap 4.47 s** against a 10 s criterion, with `WINEDEBUG` left untouched. `+loaddll` was tested and rejected as no better than the free option. The residual risk is only that both figures come from a fast M2 with a warm Rosetta cache — see R2a.

**R3a — RESOLVED by adding a second, independent signal to 4a.** Batching the fonts had left stage 4 with a single progress mechanism where it previously had two: the heartbeat covering 82 % of the stage alone, with the 57-step counter reduced to a 1.5 s blip. §5.1 now adds a coarse determinate bar driven by prefix file count against the ~2,027 a completed boot produces — advisory, clamped and monotonic, sharing the 1 Hz poll the liveness signal already needs. Stage 4 is back to two independent mechanisms answering different questions ("how far" and "still alive"), so degradation of either is no longer a single point of failure. The cold calibration run (§13.4) should still confirm the max inter-event gap during 4a clears the 10 s criterion on slower hardware.

**R2a — PARTIALLY RESOLVED by the 2026-08-09 calibration (§3.3); the residue is bandwidth, not hardware.** Was: stages 2 and 3 were never measured and stage 4 came from a warm-Rosetta machine, so the ratios driving the bar were guesswork. All six stages are now measured on a real end-to-end run, which removes the estimate-versus-measurement gap entirely.

What replaces it is narrower but not smaller: **the weights are substantially a snapshot of one connection.** The two download stages took 84 % of the calibration run at ~4.9 Mbit/s. A user on 100 Mbit sees a completely different shape, and the built-in weights would misdescribe their run as badly as the old guesses misdescribed this one. Rosetta also remains uncontrolled (runbook §2), so stages 4 and 6 are still floors.

Three things carry the residual risk:

1. **§7.3 Rule B** withdraws the numeric estimate as soon as the in-flight stage overshoots its expectation by 1.5×, rather than counting down to a number it cannot meet. This is the primary mitigation and it is what makes a one-link calibration safe to ship.
2. **§7.3 recalibration** means only the first stage of the first run uses reference numbers; everything after uses this machine's observed pace.
3. **§4.2 weights-as-data** means a later calibration is applied with `defaults write`, not a rebuild.

Residual risk: a user whose connection differs materially from the reference sees a wrong estimate through stage 2, then sees it correct or withdraw. That is honest but not pleasant. Treat the weights as a measured default, not a constant.

**R4 — Stall-watchdog false positives.** 60 s of silence is a heuristic. A slow Mac doing genuine work during Mono installation could trip it. The design deliberately makes `stalled` non-terminal and "Keep Waiting" cheap (it resets the detector and doubles the threshold to 120 s), so a false positive costs one click, not a failed setup.

**60 s is retained deliberately over a tighter 30 s.** The measured worst gap is 4.47 s, so 30 s would still carry 6.7× margin and would surface a genuinely hung install twice as fast. It is rejected because legitimate gaps grow on slower hardware — the same machines where the ETA already reads optimistic — and a false "something's wrong" on a working install is worse than a late warning on a broken one. The threshold is a named constant, not an inline literal, and is a calibration output of §13.4.

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

**Status: partially run, 2026-08-09.** A full instrumented run on this Mac produced all six stage durations and they are now the shipped weights (§3.3, §4.2). It was **not** a genuinely cold run: Rosetta's AOT cache cannot be cleared here (runbook §2), so condition (a) for removing `useBatchedImport` remains unmet and stages 4 and 6 remain floors. This section stays a runnable procedure — for a true no-AOT-cache machine, and for the faster-connection run R2 asks for.

**Tooling status, corrected 2026-08-09.** The claim "it needs no new tooling: `SetupLog` already records per-stage elapsed times" was false when written: `SetupLog` shipped as a type with no production caller, so a run produced no `setup.log` at all. It is true now, but only because the existing setup path was explicitly instrumented — see `docs/design/specs/2026-08-09-setup-log-instrumentation-design.md`, which adds two methods to `SetupLog` and no new types. Reaching the same timings via `SetupCoordinator` would have required Tasks 8, 9, 14, 15 and 17–18, i.e. the plan's whole back half, which is what the calibration gate sits in front of. `SetupCoordinator` is **Task 14**; Task 8 is `SetupJournal`.

Two limits survive that change and belong in any write-up: retry/resume decisions are not logged (Task 8), and inter-event gaps are not measured outside stage 4 (Task 11).

**Procedure.**

- Run `make fresh` on a Mac that has **never** run the engine (no Rosetta AOT cache), on a representative connection, and record all six stage durations from `setup.log`.
- Recompute the weights from those durations. Apply them with `defaults write dev.openxe.OpenXE OpenXEStageWeights …` (§4.2) to confirm they behave, then fold them into the built-in defaults.
- The developer's own Mac cannot serve: its Rosetta cache is warm and cannot be selectively cleared.
- **Record the connection speed.** The 2026-08-09 run (§3.3) proved the weights are as much a property of the link as of the machine; a duration set without a bandwidth figure beside it cannot be compared to the last one.
- The measured ~29 s stage-4 figure is a lower bound to sanity-check against — a cold run below it means the run was not actually cold. The 2026-08-09 warm-Rosetta run gave 37.5 s.

**Calibration outputs to capture while there.**

| Constant | Current | What to check |
|---|---|---|
| Stage weights (§4.2) | 1 / 67 / 3 / 8 / 17 / 4 — measured 2026-08-09 (§3.3) | Recompute from the six durations. Expect a very different split on a faster link; record the link speed alongside |
| `expectedPrefixEntries` (§5.1) | 2027 — confirmed 2026-08-09 | Plateau measured 2030 twice, with 2026 and 2029 adjacent; 2027 sits inside the tail band, so it is kept |
| Stall threshold (§7.2) | 60 s | Longest *legitimate* inter-event gap; 60 s must stay comfortably above it |
| Max inter-event gap in 4a (§11 R3a) | 4.47 s warm | Must still clear the 10 s criterion (§14.1) |
| `expectedArchiveEntries` (§5.2) | measured from the pinned archive | Unchanged unless the engine is repinned |
| `useBatchedImport` (§5.3) | `true` | Condition (a) of two for deleting the flag — **still unmet**, the 2026-08-09 run had a warm AOT cache |

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
