# Setup Log Instrumentation (calibration enabler) — Design Specification

**Date:** 2026-08-09 · **Author:** Kai Sørensen · **Status:** Approved design.
**Scope:** make the *existing* setup path write `~/Library/Logs/OpenXE/setup.log` with six
genuine stage boundaries, so the cold-machine calibration run has a primary measurement
source. Nothing else.

---

## 1. Problem

`docs/cold-calibration-runbook.md` §4 records the blocker: spec §13.4 claims the
calibration run "needs no new tooling: `SetupLog` already records per-stage elapsed
times", and that is not true of this build. `SetupLog` ships as a type, `SetupStage.ID`
ships as an enum, and the only callers of `beginRun`/`beginStage`/`endStage` are tests.
**A real run today produces no `setup.log` at all.** The runbook's fallback — a human at a
stopwatch plus a 1 Hz filesystem sampler — measures wizard *paint* times, not code
boundaries, and it cannot see the download/verify/unpack split at all.

The calibration gate sits between plan Task 7 and Task 8 precisely so the back half of the
plan is built on measured weights. Reaching instrumented timings the planned way means
Tasks 8, 9, 14, 15 and 17–18 — `SetupJournal`, `ChildRegistry`, `SetupCoordinator`,
`ProductionStageRunner`, wizard integration — i.e. building the thing the gate exists to
inform. That is backwards.

## 2. Goals / Non-Goals

**Goals**

1. A real setup run emits `setup.log` containing a run header and six stage brackets.
2. The boundaries are emitted by the code that does the work, not inferred from UI paint.
3. Zero new types. Zero new abstractions that Task 14/15 would have to unpick.
4. Deletable in one commit when `SetupCoordinator` lands (§7).

**Non-Goals**

- `SetupJournal` (Task 8), `ChildRegistry` (Task 9), `SetupPreflight` (Task 10),
  `StallDetector` (Task 11), `SetupCoordinator` (Task 14), `StageRunner` /
  `ProductionStageRunner` (Task 15). None of these are pre-empted.
- Retry, resume, cancellation, stall detection, hard ceilings. `RetryPolicy` and
  `hardCeiling` already exist as *data* in `SetupCatalog`; nothing here reads them.
- Any UI change. No new window, no new label, no `SetupEvent` plumbing.
- Weighted-progress rendering. The wizard keeps its four steps and its own progress bar.
- Teeing *every* setup subprocess. `PrefixManager` already tees; `EngineManager`'s `tar`
  stays sampled (spec §5.2); `NWSInstaller`'s Wine install keeps writing `wine.log`.

## 3. Design

### 3.1 One primitive pair on the type that already ships

`SetupLog` gains exactly two methods and one internal helper — no new type:

```swift
@discardableResult
public func startStage(_ stage: SetupStage.ID, attempt: Int = 1) -> DispatchTime
public func endStage(_ stage: SetupStage.ID, startedAt: DispatchTime)
```

`startStage` calls the existing `beginStage` and returns a **monotonic** mark;
`endStage(_:startedAt:)` computes the interval and calls the existing
`endStage(_:elapsed:)`. `DispatchTime.uptimeNanoseconds` is used rather than `Date` so an
NTP step during a multi-minute cold run cannot produce a negative or inflated stage time.

This is a timing bracket and nothing else: no retry, no ceiling, no cancellation, no
event stream. It is deliberately *not* a stage runner.

**Why a returned mark rather than a closure bracket.** A `stage { … }` helper would need
sync and async overloads (ambiguous at call sites with default arguments), and would be a
`StageRunner` in embryo. A returned instant works identically in sync code, `async` code
and across a `Task.detached` boundary, and reads as what it is.

### 3.2 Ownership: one log per app run, opened in the shell

`AppDelegate` owns the single `SetupLog`, created on first use and emitting `beginRun`
once (build ID via `Runner.currentBuildID`, active-or-default engine ID, free bytes via
`volumeAvailableCapacityForImportantUsage`). It is injected into
`WizardWindowController`. The file handle is never closed explicitly: `SetupLog.emit`
writes straight through `FileHandle.write` with no buffering, so process exit loses
nothing, and setup can outlive any one window.

`OpenXECore` stays AppKit-free; the log is passed *down* into Core as an optional
argument, exactly as `PrefixManager.ensurePrefix(log:)` already accepts it.

### 3.3 The six stages, as actually instrumented

| Stage | Bracket opens | Bracket closes | Emitted by |
|---|---|---|---|
| `preflight` | before the detached `RosettaGate.check()` | when `check()` returns | `AppDelegate.ensureRosetta`, `WizardWindowController.rosettaGatePassed` |
| `downloadEngine` | top of each attempt in `EngineManager.install` | after the SHA-256 **matches** | `EngineManager.install` |
| `unpackEngine` | at `progress(.extracting)` | after `extractAndInstall` returns | `EngineManager.install`, `installLocalArchive` |
| `preparePrefix` | after the `isReady` guard in `ensurePrefix` | after the ready marker is written | `PrefixManager.ensurePrefix` |
| `downloadNWS` | entry to `NWSInstaller.download` / `downloadViaFallback` | when the verified file is returned | `NWSInstaller` |
| `installNWS` | entry to `NWSInstaller.install` | after `installedExe` is confirmed | `NWSInstaller` |

Three decisions inside that table are worth stating, because a later reader will
otherwise assume the boundaries fell elsewhere.

**(a) Verification is the terminal act of `downloadEngine`, not the opening act of
`unpackEngine`.** Spec §4.2 settles this explicitly: "Stage 2 is complete only when the
archive is on disk *and* its checksum matches." So `.verifying` is **inside** stage 2,
not a boundary between stages. To keep the calibration decomposable anyway, the transfer
and the hash are each recorded as `note` lines with their own elapsed seconds:

```
engine archive transferred in 412.7s
engine archive sha256 verified in 6.1s
--- stage downloadEngine end (418.8s) ---
```

so a future reader can split stage 2 without re-running anything. This is the one place
the implementation departs from a literal reading of "three `EngineProgress` transitions
= three boundaries"; the weights table is defined over the six stage IDs, and §4.2 is the
authority on where the 2/3 boundary sits.

**(b) The Rosetta *install* is outside `preflight`.** `preflight` brackets only the
automated `check()` — milliseconds. If the gate finds Rosetta missing, the modal, the
user's authentication and `softwareupdate --install-rosetta` (minutes, mostly human
latency) are recorded as `note` lines with their own elapsed time, *not* folded into the
stage. Folding them in would make stage 1's weight a measure of how fast the user types
their password. Its `hardCeiling` of 15 s reflects the same intent.

**(c) An unterminated `begin` marker is the failure signal.** Stages emit `end` only on
success. A `--- stage X begin ---` with no matching `end` is where the run died; a
checksum mismatch therefore shows as `downloadEngine` attempt 1 unterminated, followed by
`downloadEngine` attempt 2. Error *events* are Task 14's job; this is the honest signal
available without them.

### 3.4 Signature changes (all additive, all defaulted)

| API | Change |
|---|---|
| `EngineManager.ensureDefaultActive` | gains `log: SetupLog? = nil` |
| `EngineManager.install` | already had `log:`; now uses it for stage brackets |
| `NWSInstaller.download(_:)`, `downloadViaFallback`, `install(installerAt:)` | gain `log: SetupLog? = nil` |
| `PrefixManager.ensurePrefix` | unchanged signature; now brackets `preparePrefix` |

Every existing call site — including tests and the gated e2e — compiles untouched.
Inside `NWSInstaller.install` the pre-existing local `log` (the `wine.log` handle) is
renamed `wineLog`; the two logs have different jobs and must not share a name.

## 4. Call sites that pass the log

Verified by grep, not assumed:

- `Sources/OpenXE/AppDelegate.swift` — `ensureRosetta` (preflight), `ensureDefaultActive`,
  `ensurePrefix`
- `Sources/OpenXE/WizardWindow.swift` — `rosettaGatePassed` (preflight),
  `ensureDefaultActive`, `ensurePrefix`, `nws.download` / `downloadViaFallback`,
  `nws.install`

No other production call site exists. `Tests/OpenXECoreTests/EndToEndTests.swift` and
`NWSInstallerTests.swift` call these APIs and stay on the `nil` default.

## 5. What the launch path emits

`AppDelegate.processQueue` runs the Rosetta gate on **every** `.exe` open, so a
double-click on an already-configured Mac appends a run header plus one `preflight`
bracket — four lines. That is intended: `SetupCatalog.launchPathSubset` includes
`preflight`, and the 5 MB rotation makes the volume irrelevant. Stages 2–6 appear only
when work is actually done.

## 6. Test plan

Unit tests, no network, no Wine, nothing near `~/Library/Application Support/OpenXE`:

1. `SetupLogTests` — `startStage`/`endStage(_:startedAt:)` write a matched begin/end pair
   with the attempt number and a non-negative elapsed figure; the mark is monotonic.
2. `SetupLogTests` — the pair composes with the existing `beginRun`/`note` API and the
   default `attempt` is 1.
3. `EngineManagerTests` — `installLocalArchive(_:archive:log:)` over a **locally built
   tar fixture** emits `stage unpackEngine begin` / `end` and the verify note. This is the
   one stage bracket that is fully exercisable offline, and it also covers
   `extractAndInstall`, which `install()` shares.
4. `EngineManagerTests` — a checksum mismatch in `installLocalArchive` emits **no**
   `unpackEngine` bracket (the stage never started).

Not unit-testable, by nature: `downloadEngine` (network), `preparePrefix` (Wine),
`downloadNWS`/`installNWS` (network + Wine), `preflight` (AppKit). These are covered by
the calibration run itself, which is the acceptance test — see §8.

## 7. How Tasks 14–15 supersede this

When `SetupCoordinator` (Task 14) and `ProductionStageRunner` (Task 15) land, the runner
owns stage boundaries and emits `SetupEvent`. Superseding this work is then a subtraction:

1. Delete `SetupLog.startStage` and `endStage(_:startedAt:)` — the runner calls the
   original `beginStage`/`endStage(_:elapsed:)` because it already tracks attempt number
   and elapsed time for the ETA.
2. Delete the brackets inside `EngineManager` / `PrefixManager` / `NWSInstaller`; the
   `log:` parameters **stay**, because the coordinator passes the same log down for
   subprocess teeing.
3. Delete the log-ownership code in `AppDelegate` and the `log:` parameter on
   `WizardWindowController.init`; the coordinator owns the log and the windows render its
   events.
4. Keep the `note` lines for transfer/verify/Rosetta-install elapsed — they are
   sub-stage detail no stage bracket carries.

Nothing here creates a type, protocol or seam that Task 14/15 must be designed around.

## 8. Acceptance and its limits

**Acceptance:** a real `make fresh` run produces `~/Library/Logs/OpenXE/setup.log`
containing a run header and six `begin`/`end` pairs whose elapsed figures are usable as
calibration input.

That run is destructive — it destroys the live NWS install — and is the user's step under
the runbook's supervision, not something to trigger from a build. What is proved by this
change alone is: the brackets exist at the boundaries above, the offline ones assert in
`swift test`, and the plumbing compiles with the log reaching every one of the six sites.
The end-to-end emission remains **inferred until the calibration run is executed**, and
the runbook says so where it matters (§4, §6.3).
