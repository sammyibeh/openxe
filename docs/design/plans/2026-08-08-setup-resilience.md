# Setup Resilience Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rework OpenXE's first-run setup into a resilient, observable, cancellable flow — a diagnosable log, real progress through the silent stretch, visible failures with retry, and a quit path that cleans up after itself.

**Architecture:** A new `SetupCoordinator` in `OpenXECore` owns setup end to end across six weighted stages, emitting a `SetupEvent` stream. `WizardWindowController` and `ProgressWindowController` become renderers of that stream and hold no orchestration. Supporting types: `SetupJournal` (advisory on-disk state), `SetupLog` (every subprocess teed), `ChildRegistry` (cancel actually kills children), `StallDetector`, `SetupSweeper`. Components keep narrow local progress callbacks; the coordinator maps them into the unified stream.

**Tech Stack:** Swift 6, SwiftPM, XCTest, AppKit, Foundation, CryptoKit, UserNotifications. No third-party dependencies.

**Spec:** [`docs/design/specs/2026-08-08-setup-resilience-design.md`](../specs/2026-08-08-setup-resilience-design.md) — section references below (§N) point there.

## Global Constraints

- **Zero third-party dependencies.** Foundation, Dispatch, AppKit, CryptoKit, UserNotifications only. `UserNotifications` is the one newly-linked framework.
- **App binary stays under 5 MB.** Currently 879,312 B. Check with `ls -la dist/OpenXE.app/Contents/MacOS/OpenXE` after `make app`.
- **`OpenXECore` must not import AppKit.** UI-facing types live in `Sources/OpenXE`.
- **Wine stays an unmodified subprocess.** No linking against Wine, no patching.
- **`WINEDEBUG` in `WineEnvironment.build` (`Paths.swift:69`) must not change.** Verified by spike (§3.1): `+loaddll` gives no benefit over the untouched value once filesystem polling is present, and changing it would affect every app launch.
- **Canonical size copy:** "a one-time download of about 177 MB, which expands to about 700 MB on your Mac." Never "1.7 GB", never "~200 MB", never "~1 GB".
- **Stage weights (§4.2), sum exactly 100:** preflight 1, downloadEngine 37, unpackEngine 25, preparePrefix 12, downloadNWS 10, installNWS 15. **These assume batched fonts (Task 6).** If Task 6 is reverted, stage 4 returns to ~59 s and the weights must be recomputed.
- **Weights are data, never inline literals.** They live in `StageWeightTable` and are overridable via the `OpenXEStageWeights` user default, because cold calibration is deferred and they will need correcting without a rebuild (§4.2). The same rule covers `expectedArchiveEntries`, `expectedPrefixEntries`, the stall threshold, and `overshootFactor` — each a named constant in one place.
- **All timing figures come from a warm Apple Silicon Mac.** The ETA will read optimistic on slower hardware; §7.3 Rule B is what keeps that from becoming a confidently wrong countdown.
- **Stage-4 sub-step weights (§5.1), sum exactly 100:** 4a boot 82, 4b drain 3, 4c verify 2, 4d registry 6, 4e fonts 5, 4f linking 1, 4g marker 1.
- **The journal is advisory; the filesystem is authoritative** (§6.2). Every resume decision starts from a ground-truth predicate.
- **Tests:** XCTest, `@testable import OpenXECore`, fixtures in `FileManager.default.temporaryDirectory` with `defer` cleanup. Never touch `~/Library/Application Support/OpenXE`.
- Run all tests with `swift test`. Filter with `swift test --filter <ClassName>/<testName>`.

## Sequencing rationale

Tasks 1–5 are front-loaded for diagnosability: after Task 5 a failed install on someone else's Mac produces a `setup.log` and a visibly advancing stage 4, which is what makes the next remote install debuggable. Task 6 is the font-batching performance change — placed here, adjacent to the font code it modifies and before any coordinator work, so it stays independently revertable. Tasks 7–13 build the resilience machinery. Task 14 assembles the coordinator. Tasks 16+ are UI and cleanup.

**Task 6 is a leaf.** It depends only on Tasks 2, 4 and 5, and nothing after it depends on it. It rides along with a correctness/observability effort without being entangled in it: `git revert` of that single commit restores the per-write path, and flipping `FontProvisioning.useBatchedImport` does so without a revert at all. Its only coupling is numeric — the stage weights in Task 3 assume it landed (see Global Constraints).

**Tasks requiring the injectable stage-runner seam to exist first (Task 14, Step 1):** Task 15 (fault-injection matrix) and the retry/stall/cancel tests inside Task 14 itself. Component-level fault tests (bad checksum, tar failure) need no seam — they use fixture files and are testable from Task 5 onward.

## File Structure

**New — `Sources/OpenXECore/`**

| File | Responsibility |
|---|---|
| `SetupCopy.swift` | All user-facing setup strings, single source of truth |
| `SetupLog.swift` | `~/Library/Logs/OpenXE/setup.log`, rotation, tail |
| `SetupStage.swift` | `SetupStage`, `SetupStage.ID`, `RetryPolicy`, the six-stage catalog |
| `SetupEvent.swift` | `SetupEvent`, `SetupFailure`, error→failure mapping |
| `SetupJournal.swift` | On-disk JSON, stage state machine, atomic write |
| `ChildRegistry.swift` | Live child PIDs; SIGTERM→SIGKILL termination |
| `SetupPreflight.swift` | Free-space and Rosetta gate |
| `StallDetector.swift` | Liveness watchdog |
| `SetupSweeper.swift` | Startup cleanup of orphaned artefacts |
| `SetupCoordinator.swift` | Stage machine, retry, resume, cancel, event stream |

**Modified — `Sources/OpenXECore/`**

| File | Change |
|---|---|
| `Paths.swift` | Add `setupLog`, `setupJournal`, `nwsDownloadDirectory` accessors |
| `Subprocess.swift` | Add `registry:` and `onLine:` params; stream to log as output arrives |
| `PrefixManager.swift` | Add `PrefixProgress` callback; 7 reported sub-steps; batched font import with per-write fallback |
| `FontProvisioning.swift` | Add `useBatchedImport` flag and the `.reg` generator (Task 6) |
| `EngineManager.swift` | Reorder commit sequence (wedge fix); `tar -xvf` with file counting |
| `NWSInstaller.swift` | Resumable download via HTTP Range |

**New/modified — `Sources/OpenXE/`**

| File | Change |
|---|---|
| `AppMenu.swift` | NEW — minimal main menu so ⌘Q exists |
| `SetupPanelView.swift` | NEW — the progress/failure panel, shared by both renderers |
| `WizardWindow.swift` | Renders `SetupEvent`; confirm sheet; failure state |
| `ProgressWindow.swift` | Renders `SetupEvent` (launch-path subset) |
| `AppDelegate.swift` | Owns coordinator; `applicationShouldTerminate`; startup sweep |
| `main.swift` | Install the main menu |

**New — `scripts/`:** `verify-font-batching.sh` — repeatable proof that the batched import and the per-write path produce identical registry state.

**Tests — `Tests/OpenXECoreTests/`:** `SetupLogTests`, `SetupStageTests`, `SetupJournalTests`, `ChildRegistryTests`, `SetupPreflightTests`, `StallDetectorTests`, `SetupSweeperTests`, `SetupCoordinatorTests`, `SetupFaultInjectionTests`, `FontProvisioningTests`, plus additions to `EngineManagerTests`, `NWSInstallerTests`, and a new `PrefixManagerTests`.

---

### Task 1: Canonical setup copy and new paths

Fixes the user-visible wrong size ("about 1.7 GB" against a measured 177 MB) and adds the path accessors every later task needs.

**Files:**
- Create: `Sources/OpenXECore/SetupCopy.swift`
- Modify: `Sources/OpenXECore/Paths.swift` (add accessors after `wineLog`, currently ends line 51)
- Modify: `Sources/OpenXE/WizardWindow.swift:254-257`, `Sources/OpenXE/AppDelegate.swift:78-80`, `Sources/OpenXE/ProgressWindow.swift:58`
- Test: `Tests/OpenXECoreTests/SetupCopyTests.swift`

**Interfaces:**
- Produces: `SetupCopy.engineSizeSummary: String`, `SetupCopy.engineDownloadBytes: Int64`, `OpenXEPaths.setupLog: URL`, `OpenXEPaths.setupJournal: URL`, `OpenXEPaths.nwsDownloadDirectory: URL`

- [x] **Step 1: Write the failing test**

```swift
import XCTest
@testable import OpenXECore

final class SetupCopyTests: XCTestCase {

    /// Spec §3: the pinned asset is 185,303,032 B. Copy must not drift from it.
    func testEngineSizeCopyMatchesThePinnedAsset() {
        XCTAssertEqual(SetupCopy.engineDownloadBytes, 185_303_032)
        XCTAssertTrue(SetupCopy.engineSizeSummary.contains("177 MB"),
                      "got: \(SetupCopy.engineSizeSummary)")
        XCTAssertTrue(SetupCopy.engineSizeSummary.contains("700 MB"))
        for banned in ["1.7 GB", "200 MB", "1 GB"] {
            XCTAssertFalse(SetupCopy.engineSizeSummary.contains(banned),
                           "banned figure \(banned) present")
        }
    }

    func testPathsExposeSetupLogAndJournal() {
        let p = OpenXEPaths(root: URL(fileURLWithPath: "/tmp/openxe-test"))
        XCTAssertEqual(p.setupJournal.lastPathComponent, "setup-journal.json")
        XCTAssertEqual(p.setupLog.lastPathComponent, "setup.log")
        XCTAssertEqual(p.nwsDownloadDirectory.lastPathComponent, "nws-download")
    }
}
```

- [x] **Step 2: Run test to verify it fails**

Run: `swift test --filter SetupCopyTests`
Expected: FAIL — `cannot find 'SetupCopy' in scope`

- [x] **Step 3: Create `SetupCopy.swift`**

```swift
import Foundation

/// Every user-facing string the setup flow shows. Single source of truth:
/// three separate copies of the engine size had drifted to "1.7 GB",
/// "~200 MB" and "~1 GB" against a measured 177 MB (spec §3).
public enum SetupCopy {
    /// Exact size of the pinned engine asset, verified against the live
    /// release Content-Length.
    public static let engineDownloadBytes: Int64 = 185_303_032

    /// The canonical phrasing. Used by the wizard, the launch-path progress
    /// window, and anywhere else the download is described.
    public static let engineSizeSummary =
        "a one-time download of about 177 MB, which expands to about 700 MB on your Mac"

    public static let preparingEnvironment = "Preparing the Windows environment"
    public static let takingLongerThanUsual =
        "This is taking longer than usual. It may still be working."
}
```

- [x] **Step 4: Add the path accessors to `Paths.swift`**

Insert after the `wineLog` accessor (currently ends at line 51, before the closing brace):

```swift
    /// ~/Library/Logs/OpenXE/setup.log — the first-run narrative (spec §4.4).
    /// Separate from wine.log, which stays scoped to program launches.
    public var setupLog: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/OpenXE/setup.log")
    }

    /// Advisory record of setup progress (spec §6.2). The filesystem, not this
    /// file, is authoritative for what is actually installed.
    public var setupJournal: URL { root.appendingPathComponent("setup-journal.json") }

    /// Where the NWS installer is downloaded. Was private to NWSInstaller;
    /// the sweeper needs it too (spec §8.4).
    public var nwsDownloadDirectory: URL {
        root.appendingPathComponent("nws-download", isDirectory: true)
    }
```

- [x] **Step 5: Point the three drifted copy sites at the constant**

In `Sources/OpenXE/WizardWindow.swift:254-257`, replace the `else` branch paragraph:

```swift
            bodyStack.addArrangedSubview(paragraph(
                "OpenXE needs to prepare a small Windows environment the first time you "
                + "run it. This is \(SetupCopy.engineSizeSummary). It can take several "
                + "minutes, and you only do this once."))
```

In `Sources/OpenXE/AppDelegate.swift:78-80`, replace the message:

```swift
        progress.show(message: needsEngine
            ? "Setting up your Windows environment — \(SetupCopy.engineSizeSummary)."
            : "Finishing your Windows environment setup.")
```

In `Sources/OpenXE/ProgressWindow.swift:58`:

```swift
            setIndeterminate(message: "Unpacking the Windows environment (about 700 MB)…")
```

- [x] **Step 6: Run tests and build**

Run: `swift test --filter SetupCopyTests && swift build`
Expected: PASS, build succeeds

- [x] **Step 7: Verify no stale figures remain**

Run: `grep -rn "1\.7 GB\|~200 MB\|~1 GB" Sources/`
Expected: no output

- [x] **Step 8: Commit**

```bash
git add Sources/OpenXECore/SetupCopy.swift Sources/OpenXECore/Paths.swift \
        Sources/OpenXE/WizardWindow.swift Sources/OpenXE/AppDelegate.swift \
        Sources/OpenXE/ProgressWindow.swift Tests/OpenXECoreTests/SetupCopyTests.swift
git commit -m "fix: correct engine size copy and add setup paths

The wizard advertised 1.7 GB against a measured 177 MB download. Three
sites had drifted apart; consolidate into SetupCopy."
```

---

### Task 2: SetupLog

The single highest-value gap: today stages 1–10 write nothing anywhere (spec §6).

**Files:**
- Create: `Sources/OpenXECore/SetupLog.swift`
- Test: `Tests/OpenXECoreTests/SetupLogTests.swift`

**Interfaces:**
- Consumes: `OpenXEPaths.setupLog` (Task 1)
- Produces: `SetupLog(url:)`, `.beginRun(buildID:engineID:freeBytes:)`, `.beginStage(_:attempt:)`, `.endStage(_:elapsed:)`, `.note(_:)`, `.write(_ data: Data)`, `.handle: FileHandle?`, `.tail(lines:) -> String`, `.rotateIfNeeded()`

- [x] **Step 1: Write the failing test**

```swift
import XCTest
@testable import OpenXECore

final class SetupLogTests: XCTestCase {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("openxe-setuplog-\(UUID().uuidString)/setup.log")
    }

    func testWritesRunAndStageMarkers() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let log = try SetupLog(url: url)
        log.beginRun(buildID: "OpenXE-123-456", engineID: "gcenx-stable-11.0_1",
                     freeBytes: 12_000_000_000)
        log.beginStage(.preparePrefix, attempt: 2)
        log.note("Registering fonts (23 of 57)")
        log.endStage(.preparePrefix, elapsed: 59.4)
        log.close()

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("OpenXE-123-456"))
        XCTAssertTrue(text.contains("gcenx-stable-11.0_1"))
        XCTAssertTrue(text.contains("preparePrefix"))
        XCTAssertTrue(text.contains("attempt 2"))
        XCTAssertTrue(text.contains("Registering fonts (23 of 57)"))
        XCTAssertTrue(text.contains("59.4"))
    }

    func testTailReturnsLastLines() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let log = try SetupLog(url: url)
        for i in 1...100 { log.note("line \(i)") }
        log.close()

        let tail = SetupLog.tail(of: url, lines: 3)
        XCTAssertTrue(tail.contains("line 100"))
        XCTAssertTrue(tail.contains("line 98"))
        XCTAssertFalse(tail.contains("line 97"))
    }

    func testTailOnMissingFileIsSafe() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("openxe-absent-\(UUID().uuidString).log")
        XCTAssertEqual(SetupLog.tail(of: missing, lines: 5), "(no setup log yet)")
    }

    /// Spec §4.4: rotate at 5 MB, keep one generation.
    func testRotationMovesOldLogAside() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // 6 MB of filler, over the 5 MB threshold.
        try Data(repeating: 0x41, count: 6 << 20).write(to: url)

        let log = try SetupLog(url: url)
        log.note("after rotation")
        log.close()

        let rotated = url.deletingLastPathComponent().appendingPathComponent("setup.log.1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: rotated.path))
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("after rotation"))
        XCTAssertLessThan(text.count, 1 << 20, "fresh log should not carry the old body")
    }
}
```

- [x] **Step 2: Run test to verify it fails**

Run: `swift test --filter SetupLogTests`
Expected: FAIL — `cannot find 'SetupLog' in scope`

- [x] **Step 3: Implement `SetupLog.swift`**

```swift
import Foundation

/// The setup narrative log (spec §4.4). Every subprocess spawned during setup
/// tees into this; today stages 1-10 write nothing anywhere, which is why a
/// failed install on someone else's Mac cannot be diagnosed.
///
/// Session-appended, rotated at 5 MB with one generation kept. Deliberately
/// separate from wine.log, which stays scoped to program launches.
public final class SetupLog: @unchecked Sendable {

    static let rotateThreshold = 5 << 20

    private let url: URL
    private let fileHandle: FileHandle
    private let lock = NSLock()

    /// The handle to hand to `Subprocess.run(logHandle:)`.
    public var handle: FileHandle { fileHandle }
    public var fileURL: URL { url }

    public init(url: URL) throws {
        self.url = url
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        Self.rotateIfNeeded(at: url)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        fileHandle = try FileHandle(forWritingTo: url)
        try fileHandle.seekToEnd()
    }

    static func rotateIfNeeded(at url: URL) {
        let fm = FileManager.default
        guard let size = (try? fm.attributesOfItem(atPath: url.path)[.size]) as? Int,
              size >= rotateThreshold else { return }
        let rotated = url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + ".1")
        try? fm.removeItem(at: rotated)
        try? fm.moveItem(at: url, to: rotated)
    }

    private func emit(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        let stamp = ISO8601DateFormatter().string(from: Date())
        try? fileHandle.write(contentsOf: Data("\(stamp) \(line)\n".utf8))
    }

    public func beginRun(buildID: String, engineID: String, freeBytes: Int64) {
        emit("===== setup run begin =====")
        emit("build=\(buildID) engine=\(engineID) freeBytes=\(freeBytes) "
             + "os=\(ProcessInfo.processInfo.operatingSystemVersionString)")
    }

    public func beginStage(_ stage: SetupStage.ID, attempt: Int) {
        emit("--- stage \(stage.rawValue) begin (attempt \(attempt)) ---")
    }

    public func endStage(_ stage: SetupStage.ID, elapsed: TimeInterval) {
        emit(String(format: "--- stage %@ end (%.1fs) ---", stage.rawValue, elapsed))
    }

    public func note(_ message: String) { emit(message) }

    /// Raw subprocess bytes, written verbatim without a timestamp prefix.
    public func write(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        try? fileHandle.write(contentsOf: data)
    }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        try? fileHandle.close()
    }

    /// Last `lines` lines, for the disclosure triangle and failure state.
    public static func tail(of url: URL, lines: Int = 40) -> String {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "(no setup log yet)"
        }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .suffix(lines).joined(separator: "\n")
    }
}
```

> **Note:** this file references `SetupStage.ID`, defined in Task 3. Implement Task 3 first if the compiler objects, or temporarily type the parameter as `String` — but prefer doing Task 3 first and keeping this signature.

- [x] **Step 4: Run tests**

Run: `swift test --filter SetupLogTests`
Expected: PASS (4 tests)

- [x] **Step 5: Commit**

```bash
git add Sources/OpenXECore/SetupLog.swift Tests/OpenXECoreTests/SetupLogTests.swift
git commit -m "feat: add SetupLog

Setup stages currently write nothing to disk, so a failed first run on
another Mac leaves no diagnostic trail."
```

---

### Task 3: SetupStage, SetupEvent, and the stage catalog

Pure data. No behaviour, so it is quick — but it locks the weights, which drive the whole progress bar.

**Files:**
- Create: `Sources/OpenXECore/SetupStage.swift`, `Sources/OpenXECore/SetupEvent.swift`
- Test: `Tests/OpenXECoreTests/SetupStageTests.swift`

**Interfaces:**
- Produces: `SetupStage.ID` (`.preflight .downloadEngine .unpackEngine .preparePrefix .downloadNWS .installNWS`), `SetupStage`, `RetryPolicy`, `SetupCatalog.all`, `SetupCatalog.launchPathSubset`, `SetupEvent`, `SetupFailure`, `SetupFailure.Kind`

- [x] **Step 1: Write the failing test**

```swift
import XCTest
@testable import OpenXECore

final class SetupStageTests: XCTestCase {

    /// Spec §4.2 — the bar is meaningless if these drift.
    func testStageWeightsSumTo100() {
        XCTAssertEqual(SetupCatalog.all.reduce(0) { $0 + $1.weight }, 100)
    }

    /// Spec §4.2: weights are data. Cold calibration is deferred, so they must
    /// be correctable with `defaults write` and no rebuild.
    func testValidOverrideIsAccepted() {
        let override = ["preflight": 2, "downloadEngine": 30, "unpackEngine": 30,
                        "preparePrefix": 20, "downloadNWS": 8, "installNWS": 10]
        let weights = StageWeightTable.resolve(override: override)
        XCTAssertEqual(weights[.downloadEngine], 30)
        XCTAssertEqual(weights.values.reduce(0, +), 100)
    }

    /// A bad override must degrade to the shipped defaults, never a broken bar.
    func testInvalidOverridesAreRejected() {
        let defaults = StageWeightTable.builtIn
        // Does not sum to 100.
        XCTAssertEqual(StageWeightTable.resolve(override: ["preflight": 1]), defaults)
        // Sums to 100 but omits stages.
        XCTAssertEqual(StageWeightTable.resolve(
            override: ["preflight": 50, "downloadEngine": 50]), defaults)
        // Negative value.
        XCTAssertEqual(StageWeightTable.resolve(
            override: ["preflight": -1, "downloadEngine": 38, "unpackEngine": 25,
                       "preparePrefix": 12, "downloadNWS": 10, "installNWS": 16]), defaults)
        // Unknown stage id.
        XCTAssertEqual(StageWeightTable.resolve(
            override: ["preflight": 1, "downloadEngine": 37, "unpackEngine": 25,
                       "preparePrefix": 12, "downloadNWS": 10, "installNWS": 14,
                       "bogusStage": 1]), defaults)
        // No override at all.
        XCTAssertEqual(StageWeightTable.resolve(override: nil), defaults)
    }

    /// Whatever the source, the bar is meaningless unless the weights sum to 100.
    func testResolvedWeightsAlwaysSumTo100() {
        XCTAssertEqual(StageWeightTable.builtIn.values.reduce(0, +), 100)
        XCTAssertEqual(StageWeightTable.resolveFromDefaults().values.reduce(0, +), 100)
    }

    func testStageOrderAndWeightsMatchSpec() {
        XCTAssertEqual(SetupCatalog.all.map(\.id),
                       [.preflight, .downloadEngine, .unpackEngine,
                        .preparePrefix, .downloadNWS, .installNWS])
        XCTAssertEqual(SetupCatalog.all.map(\.weight), [1, 37, 25, 12, 10, 15])
    }

    /// Spec §7.4: the launch path runs stages 1-4 and renormalises.
    func testLaunchPathSubsetRenormalisesTo100() {
        let subset = SetupCatalog.launchPathSubset
        XCTAssertEqual(subset.map(\.id),
                       [.preflight, .downloadEngine, .unpackEngine, .preparePrefix])
        XCTAssertEqual(SetupCatalog.renormalisedWeights(for: subset).reduce(0, +), 100)
    }

    func testOnlyNetworkStagesRetryAutomatically() {
        func policy(_ id: SetupStage.ID) -> RetryPolicy {
            SetupCatalog.all.first { $0.id == id }!.retry
        }
        XCTAssertEqual(policy(.downloadEngine).maxAttempts, 3)
        XCTAssertEqual(policy(.downloadNWS).maxAttempts, 3)
        // Spec §9.2: re-running a failed 59s wineboot automatically wastes the
        // user's time; retry there is manual only.
        XCTAssertEqual(policy(.preparePrefix).maxAttempts, 1)
        XCTAssertEqual(policy(.installNWS).maxAttempts, 1)
        XCTAssertEqual(policy(.unpackEngine).maxAttempts, 1)
    }

    func testBackoffGrowsAndIsJittered() {
        let p = RetryPolicy(maxAttempts: 3, baseDelay: 2, multiplier: 4, jitter: 0.25)
        let d1 = p.delay(beforeAttempt: 2)
        let d2 = p.delay(beforeAttempt: 3)
        XCTAssertTrue((1.5...2.5).contains(d1), "got \(d1)")
        XCTAssertTrue((6.0...10.0).contains(d2), "got \(d2)")
        XCTAssertEqual(p.delay(beforeAttempt: 1), 0, "first attempt is immediate")
    }
}
```

- [x] **Step 2: Run test to verify it fails**

Run: `swift test --filter SetupStageTests`
Expected: FAIL — `cannot find 'SetupCatalog' in scope`

- [x] **Step 3: Implement `SetupStage.swift`**

```swift
import Foundation

/// Retry behaviour for one stage (spec §9.2). Network stages retry
/// automatically and visibly; subprocess stages do not, because
/// re-running a failed multi-second Wine operation rarely helps.
public struct RetryPolicy: Sendable, Equatable {
    public let maxAttempts: Int
    public let baseDelay: TimeInterval
    public let multiplier: Double
    public let jitter: Double

    public init(maxAttempts: Int, baseDelay: TimeInterval = 0,
                multiplier: Double = 1, jitter: Double = 0) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.multiplier = multiplier
        self.jitter = jitter
    }

    public static let none = RetryPolicy(maxAttempts: 1)
    public static let network = RetryPolicy(maxAttempts: 3, baseDelay: 2,
                                            multiplier: 4, jitter: 0.25)

    /// Delay before `attempt` (1-based). Attempt 1 is immediate.
    public func delay(beforeAttempt attempt: Int) -> TimeInterval {
        guard attempt > 1 else { return 0 }
        let base = baseDelay * pow(multiplier, Double(attempt - 2))
        guard jitter > 0 else { return base }
        return base * (1 + Double.random(in: -jitter...jitter))
    }
}

/// One user-visible stage of first-run setup (spec §4.2).
public struct SetupStage: Sendable, Equatable {
    public enum ID: String, Codable, Sendable, CaseIterable {
        case preflight, downloadEngine, unpackEngine, preparePrefix, downloadNWS, installNWS
    }

    public let id: ID
    public let displayName: String
    public let weight: Int
    public let resumable: Bool
    public let retry: RetryPolicy
    public let hardCeiling: TimeInterval
}

/// Stage weights as DATA, not logic (spec §4.2). Cold-machine calibration is
/// deferred, so these will need correcting later on evidence we do not yet
/// have — via `defaults write dev.openxe.OpenXE OpenXEStageWeights`, with no
/// rebuild. An ad-hoc-signed bundle cannot have a bundled resource edited
/// without invalidating its signature, which is why the override lives in
/// UserDefaults rather than a plist in Resources.
public enum StageWeightTable {

    /// Share of a 241 s reference run (spec §3.1, §3.2). Assumes batched font
    /// provisioning (spec §5.3). MUST sum to 100.
    public static let builtIn: [SetupStage.ID: Int] = [
        .preflight: 1, .downloadEngine: 37, .unpackEngine: 25,
        .preparePrefix: 12, .downloadNWS: 10, .installNWS: 15,
    ]

    public static let defaultsKey = "OpenXEStageWeights"

    /// Resolution order: validated UserDefaults override, then built-in.
    /// An override is accepted only if it names every stage exactly once, all
    /// values are positive, and they sum to 100. Anything else is ignored and
    /// logged, so a bad edit degrades to the shipped defaults.
    public static func resolve(override: [String: Int]?) -> [SetupStage.ID: Int] {
        guard let override else { return builtIn }
        var parsed: [SetupStage.ID: Int] = [:]
        for (key, value) in override {
            guard let id = SetupStage.ID(rawValue: key), value > 0 else { return builtIn }
            guard parsed[id] == nil else { return builtIn }
            parsed[id] = value
        }
        guard parsed.count == SetupStage.ID.allCases.count,
              parsed.values.reduce(0, +) == 100 else { return builtIn }
        return parsed
    }

    public static func resolveFromDefaults() -> [SetupStage.ID: Int] {
        let raw = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Int]
        let resolved = resolve(override: raw)
        if raw != nil, resolved == builtIn {
            NSLog("OpenXE: ignoring invalid %@ override; using built-in weights", defaultsKey)
        }
        return resolved
    }
}

/// The six stages, their weights, and their policies.
public enum SetupCatalog {

    private static let weights = StageWeightTable.resolveFromDefaults()

    public static let all: [SetupStage] = [
        SetupStage(id: .preflight, displayName: "Checking your Mac",
                   weight: weights[.preflight]!, resumable: false,
                   retry: .none, hardCeiling: 15),
        SetupStage(id: .downloadEngine, displayName: "Downloading the Windows environment",
                   weight: weights[.downloadEngine]!, resumable: true,
                   retry: .network, hardCeiling: 60),
        SetupStage(id: .unpackEngine, displayName: "Unpacking the Windows environment",
                   weight: weights[.unpackEngine]!, resumable: false,
                   retry: .none, hardCeiling: 900),
        SetupStage(id: .preparePrefix, displayName: "Preparing the Windows environment",
                   weight: weights[.preparePrefix]!, resumable: false,
                   retry: .none, hardCeiling: 900),
        SetupStage(id: .downloadNWS, displayName: "Downloading New World Scheduler",
                   weight: weights[.downloadNWS]!, resumable: true,
                   retry: .network, hardCeiling: 600),
        SetupStage(id: .installNWS, displayName: "Installing New World Scheduler",
                   weight: weights[.installNWS]!, resumable: false,
                   retry: .none, hardCeiling: 1200),
    ]

    /// The `.exe` launch path needs setup only through the prefix (spec §7.4).
    public static let launchPathSubset: [SetupStage] =
        all.filter { $0.id != .downloadNWS && $0.id != .installNWS }

    /// Weights rescaled to sum to 100 over a subset. The last entry absorbs
    /// the rounding remainder so the total is exact.
    public static func renormalisedWeights(for stages: [SetupStage]) -> [Int] {
        let total = stages.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return stages.map { _ in 0 } }
        var out = stages.map { Int((Double($0.weight) / Double(total) * 100).rounded()) }
        if let last = out.indices.last {
            out[last] += 100 - out.reduce(0, +)
        }
        return out
    }
}
```

- [x] **Step 4: Implement `SetupEvent.swift`**

```swift
import Foundation

/// The unified outward progress stream (spec §4.1). Replaces EngineProgress
/// and NWSProgress as the contract the UI consumes; components keep their own
/// narrow callbacks and the coordinator maps them into this.
public enum SetupEvent: Sendable {
    case stageBegan(SetupStage.ID, index: Int, of: Int)
    /// `fraction` nil means indeterminate.
    case stageProgress(SetupStage.ID, fraction: Double?, detail: String)
    case stageCompleted(SetupStage.ID, elapsed: TimeInterval)
    case overall(fraction: Double, elapsed: TimeInterval, remaining: TimeInterval?)
    case attempt(SetupStage.ID, number: Int, of: Int, reason: String)
    case stalled(SetupStage.ID, silentFor: TimeInterval)
    case recovered(SetupStage.ID)
    case failed(SetupFailure)
    case cancelled(SetupStage.ID)
    case finished
}

/// A setup failure in terms the UI can render without knowing about Wine
/// (spec §9.1). Existing EngineError/PrefixError/NWSError are wrapped, not
/// replaced.
public struct SetupFailure: Error, Sendable {
    public enum Kind: String, Codable, Sendable {
        case diskSpace, rosettaMissing, network, rateLimited, integrity,
             subprocessFailed, timedOut, stalled, environmentIncomplete, internalError
    }

    public let stage: SetupStage.ID
    public let kind: Kind
    public let userMessage: String
    public let suggestedAction: String
    public let technicalDetail: String
    public let isRetryable: Bool

    public init(stage: SetupStage.ID, kind: Kind, userMessage: String,
                suggestedAction: String, technicalDetail: String, isRetryable: Bool) {
        self.stage = stage
        self.kind = kind
        self.userMessage = userMessage
        self.suggestedAction = suggestedAction
        self.technicalDetail = technicalDetail
        self.isRetryable = isRetryable
    }
}
```

- [x] **Step 5: Run tests**

Run: `swift test --filter SetupStageTests && swift build`
Expected: PASS (5 tests), build succeeds

- [x] **Step 6: Commit**

```bash
git add Sources/OpenXECore/SetupStage.swift Sources/OpenXECore/SetupEvent.swift \
        Tests/OpenXECoreTests/SetupStageTests.swift
git commit -m "feat: add setup stage catalog and event types

Six weighted stages per spec §4.2; weights measured, sum to 100."
```

---

### Task 4: Subprocess log tee and line streaming

Gives every setup subprocess a log destination and a live line callback — the mechanism behind both the disclosure triangle and half the stage-4 heartbeat.

**Files:**
- Modify: `Sources/OpenXECore/Subprocess.swift:24-92` (signature and pipe handling)
- Test: `Tests/OpenXECoreTests/SubprocessStreamingTests.swift`

**Interfaces:**
- Consumes: nothing new
- Produces: `Subprocess.run(..., onLine: (@Sendable (String) -> Void)? = nil)` — existing call sites unaffected because every new parameter is defaulted.

- [x] **Step 1: Write the failing test**

```swift
import XCTest
@testable import OpenXECore

final class SubprocessStreamingTests: XCTestCase {

    func testOnLineReceivesEachLineAsItArrives() throws {
        let lock = NSLock()
        var lines: [String] = []
        _ = try Subprocess.run(
            URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo alpha; echo beta; echo gamma"],
            timeout: 30,
            onLine: { line in lock.lock(); lines.append(line); lock.unlock() })

        lock.lock(); let got = lines; lock.unlock()
        XCTAssertEqual(got, ["alpha", "beta", "gamma"])
    }

    func testPartialLinesAreBufferedUntilNewline() throws {
        let lock = NSLock()
        var lines: [String] = []
        _ = try Subprocess.run(
            URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'one'; sleep 0.2; printf 'two\\n'"],
            timeout: 30,
            onLine: { line in lock.lock(); lines.append(line); lock.unlock() })

        lock.lock(); let got = lines; lock.unlock()
        XCTAssertEqual(got, ["onetwo"], "a split line must be reassembled, not emitted twice")
    }

    func testStillCapturesCombinedOutput() throws {
        let r = try Subprocess.run(
            URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo out; echo err 1>&2"],
            timeout: 30)
        XCTAssertEqual(r.status, 0)
        XCTAssertTrue(r.output.contains("out"))
        XCTAssertTrue(r.output.contains("err"))
    }
}
```

- [x] **Step 2: Run test to verify it fails**

Run: `swift test --filter SubprocessStreamingTests`
Expected: FAIL — `extra argument 'onLine' in call`

- [x] **Step 3: Add the parameter and line assembly**

In `Subprocess.swift`, add to the `run` signature after `logHandle`:

```swift
        onLine: (@Sendable (String) -> Void)? = nil,
```

Pass it into `OutputBuffer` at the construction site (currently line 50):

```swift
            let b = OutputBuffer(logHandle: logHandle, onLine: onLine)
```

Then extend `OutputBuffer` (currently lines 96-123) with line assembly:

```swift
private final class OutputBuffer: @unchecked Sendable {
    private var data = Data()
    private var pending = Data()          // bytes since the last newline
    private let lock = NSLock()
    private let logHandle: FileHandle?
    private let onLine: (@Sendable (String) -> Void)?
    private let eof = DispatchSemaphore(value: 0)

    init(logHandle: FileHandle?, onLine: (@Sendable (String) -> Void)? = nil) {
        self.logHandle = logHandle
        self.onLine = onLine
    }

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        var emit: [String] = []
        if onLine != nil {
            pending.append(chunk)
            while let nl = pending.firstIndex(of: 0x0A) {
                let lineData = pending[pending.startIndex..<nl]
                emit.append(String(decoding: lineData, as: UTF8.self))
                pending = pending[pending.index(after: nl)...]
            }
        }
        lock.unlock()
        try? logHandle?.write(contentsOf: chunk)
        for line in emit { onLine?(line) }
    }

    /// Flush any trailing bytes with no newline, so a final unterminated
    /// line is not silently dropped.
    func flushPending() {
        lock.lock()
        let rest = pending
        pending = Data()
        lock.unlock()
        guard !rest.isEmpty else { return }
        onLine?(String(decoding: rest, as: UTF8.self))
    }

    func markEOF() { eof.signal() }

    func waitForEOF(timeout: TimeInterval) -> Bool {
        eof.wait(timeout: .now() + timeout) == .success
    }

    var string: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
```

Finally, call `flushPending()` in the drain block (currently lines 86-89), just before returning:

```swift
        if let buffer, let pipe {
            _ = buffer.waitForEOF(timeout: 0.5)
            pipe.fileHandleForReading.readabilityHandler = nil
            buffer.flushPending()
        }
```

- [x] **Step 4: Run tests**

Run: `swift test --filter SubprocessStreamingTests`
Expected: PASS (3 tests)

- [x] **Step 5: Verify existing callers still compile and pass**

Run: `swift build && swift test`
Expected: build succeeds; full suite passes (all new params are defaulted)

- [x] **Step 6: Commit**

```bash
git add Sources/OpenXECore/Subprocess.swift Tests/OpenXECoreTests/SubprocessStreamingTests.swift
git commit -m "feat: stream subprocess output line-by-line

Adds an optional onLine callback with correct partial-line buffering.
All new parameters default, so existing call sites are unchanged."
```

---

### Task 5: PrefixManager sub-progress — closing the silent gap

The stage the user actually complained about. After this task, stage 4 reports seven sub-steps and a live 57-step font counter, and every Wine subprocess in it writes to `setup.log`.

**Files:**
- Modify: `Sources/OpenXECore/PrefixManager.swift` — signature at `:49`, sub-steps through `:148`, `provisionFonts` at `:178-207`, `regBestEffort` at `:209-212`, `registryAdd` at `:214-224`
- Test: `Tests/OpenXECoreTests/PrefixManagerTests.swift`

**Interfaces:**
- Consumes: `SetupLog` (Task 2)
- Produces: `PrefixProgress` enum; `PrefixManager.ensurePrefix(log:progress:)`; `PrefixManager.fontWriteCount: Int`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import OpenXECore

/// Sub-step weights and the font-write count drive stage 4's progress bar
/// (spec §5.1). These are pure and testable without booting Wine.
final class PrefixManagerTests: XCTestCase {

    func testSubStepWeightsSumTo100() {
        XCTAssertEqual(PrefixProgress.SubStep.allCases.reduce(0) { $0 + $1.weight }, 100)
    }

    func testSubStepWeightsMatchMeasuredSpec() {
        XCTAssertEqual(PrefixProgress.SubStep.boot.weight, 82)
        XCTAssertEqual(PrefixProgress.SubStep.drain.weight, 3)
        XCTAssertEqual(PrefixProgress.SubStep.verify.weight, 2)
        XCTAssertEqual(PrefixProgress.SubStep.registry.weight, 6)
        XCTAssertEqual(PrefixProgress.SubStep.fonts.weight, 5)
        XCTAssertEqual(PrefixProgress.SubStep.linking.weight, 1)
        XCTAssertEqual(PrefixProgress.SubStep.marker.weight, 1)
    }

    /// Spec §5.1: 28 substitutions x 2 registry tables + 1 FontAwesome = 57.
    func testFontWriteCountIs57() {
        XCTAssertEqual(PrefixManager.fontWriteCount, 57)
        XCTAssertEqual(FontProvisioning.substitutions.count * 2 + 1, 57)
    }

    /// Fraction must advance monotonically across the whole stage.
    func testFractionIsMonotonicAcrossSubSteps() {
        var last = -1.0
        for step in PrefixProgress.SubStep.allCases {
            let f = PrefixProgress.fraction(at: step, within: 0)
            XCTAssertGreaterThanOrEqual(f, last, "regressed at \(step)")
            last = f
        }
        XCTAssertEqual(PrefixProgress.fraction(at: .marker, within: 1.0), 1.0, accuracy: 0.001)
    }

    /// Spec §5.1 / R3a: 4a's determinate bar is advisory and must never rewind.
    func testBootFractionIsClampedAndMonotonic() {
        XCTAssertEqual(PrefixProgress.bootFraction(filesSeen: 0), 0, accuracy: 0.001)
        XCTAssertEqual(PrefixProgress.bootFraction(filesSeen: 2027), 1.0, accuracy: 0.001)
        // A denominator that is too low must saturate, not exceed 1.
        XCTAssertEqual(PrefixProgress.bootFraction(filesSeen: 99_999), 1.0, accuracy: 0.001)
        XCTAssertEqual(PrefixProgress.bootFraction(filesSeen: 1013), 0.5, accuracy: 0.01)
    }

    func testFontFractionInterpolatesWithinTheSubStep() {
        let start = PrefixProgress.fraction(at: .fonts, within: 0)
        let mid = PrefixProgress.fraction(at: .fonts, within: 0.5)
        let end = PrefixProgress.fraction(at: .fonts, within: 1)
        XCTAssertLessThan(start, mid)
        XCTAssertLessThan(mid, end)
        // 4a-4d = 82+3+2+6 = 93, fonts = 5 -> 93 + 0.5*5 = 95.5
        XCTAssertEqual(mid, 0.955, accuracy: 0.002)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PrefixManagerTests`
Expected: FAIL — `cannot find 'PrefixProgress' in scope`

- [ ] **Step 3: Add `PrefixProgress` at the top of `PrefixManager.swift`**

Insert after the `import Foundation` line:

```swift
/// Stage-4 sub-progress (spec §5.1). Weights are measured, not estimated:
/// wineboot 24 s dominates; fonts are one batched import at ~1.5 s (spec §5.3).
public enum PrefixProgress: Sendable {
    public enum SubStep: String, Sendable, CaseIterable {
        case boot, drain, verify, registry, fonts, linking, marker

        public var weight: Int {
            switch self {
            case .boot:     return 82
            case .drain:    return 3
            case .verify:   return 2
            case .registry: return 6
            case .fonts:    return 5
            case .linking:  return 1
            case .marker:   return 1
            }
        }

        public var detail: String {
            switch self {
            case .boot:     return "Setting up Windows for the first time…"
            case .drain:    return "Finishing background setup…"
            case .verify:   return "Checking .NET and browser support…"
            case .registry: return "Configuring display settings…"
            case .fonts:    return "Registering fonts…"
            case .linking:  return "Linking your Documents and Downloads…"
            case .marker:   return "Finishing up…"
            }
        }

        /// Cumulative weight of every sub-step before this one.
        var offset: Int {
            var total = 0
            for s in SubStep.allCases {
                if s == self { break }
                total += s.weight
            }
            return total
        }
    }

    case step(SubStep, fraction: Double, detail: String)

    /// Files a completed `wineboot --init` leaves in the prefix (measured,
    /// spec §3.1). Denominator for 4a's coarse determinate bar.
    public static let expectedPrefixEntries = 2027

    /// 4a progress from prefix file count (spec §5.1, closes R3a). Advisory:
    /// clamped to 1.0, and the caller keeps a running maximum so the bar can
    /// never rewind. A wrong denominator yields a lazy bar, never a wrong one.
    public static func bootFraction(filesSeen: Int) -> Double {
        min(Double(filesSeen) / Double(expectedPrefixEntries), 1.0)
    }

    /// Overall 0...1 position within stage 4.
    public static func fraction(at step: SubStep, within inner: Double) -> Double {
        let clamped = min(max(inner, 0), 1)
        return (Double(step.offset) + Double(step.weight) * clamped) / 100.0
    }
}
```

- [ ] **Step 3b: Add `BootProgressPoller` at the bottom of `PrefixManager.swift`**

```swift
/// Polls the prefix's file count at 1 Hz to give sub-step 4a a coarse
/// determinate bar (spec §5.1, closes R3a). `wineboot` reports no progress of
/// its own, and after font batching 4a covers 82 % of stage 4 — this is the
/// second, independent signal that keeps the stage from resting on liveness
/// evidence alone.
///
/// Advisory by construction: the reported fraction is a running maximum, so a
/// poll that transiently counts fewer entries cannot rewind the bar, and the
/// count never gates completion — `wineboot` exiting does.
final class BootProgressPoller: @unchecked Sendable {
    private let prefix: URL
    private let onProgress: (Double) -> Void
    private var timer: DispatchSourceTimer?
    private var highWater: Double = 0
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "dev.openxe.boot-progress")

    init(prefix: URL, onProgress: @escaping (Double) -> Void) {
        self.prefix = prefix
        self.onProgress = onProgress
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in self?.tick() }
        lock.lock(); timer = t; lock.unlock()
        t.resume()
    }

    func stop() {
        lock.lock(); let t = timer; timer = nil; lock.unlock()
        t?.cancel()
    }

    private func tick() {
        let count = Self.entryCount(at: prefix)
        let fraction = PrefixProgress.bootFraction(filesSeen: count)
        lock.lock()
        guard fraction > highWater else { lock.unlock(); return }
        highWater = fraction
        lock.unlock()
        onProgress(fraction)
    }

    /// ~10 ms on a 2,027-entry prefix (measured), i.e. ~1 % of one core at
    /// 1 Hz. Cheap enough not to warrant a smarter mechanism.
    static func entryCount(at url: URL) -> Int {
        guard let e = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else { return 0 }
        var n = 0
        for case _ as URL in e { n += 1 }
        return n
    }
}
```

- [ ] **Step 4: Thread the log and progress callback through `ensurePrefix`**

Add the static count and change the signature (currently `PrefixManager.swift:49`):

```swift
    /// 28 substitutions x 2 registry tables + 1 FontAwesome registration.
    public static var fontWriteCount: Int { FontProvisioning.substitutions.count * 2 + 1 }

    public func ensurePrefix(log: SetupLog? = nil,
                             progress: (@Sendable (PrefixProgress) -> Void)? = nil) throws {
```

Then report each sub-step. Replace the boot block (currently `:62-72`):

```swift
        // 1. Boot. Bundled shared Mono/Gecko auto-install here (spec §4.1).
        progress?(.step(.boot, fraction: 0, detail: PrefixProgress.SubStep.boot.detail))
        log?.note("wineboot --init starting")

        // Coarse determinate bar for 4a from prefix file count (spec §5.1,
        // closes R3a). Shares the 1 Hz cadence the liveness signal needs; the
        // running maximum is what guarantees the bar never rewinds.
        let bootProgress = BootProgressPoller(prefix: paths.prefix) { fraction in
            progress?(.step(.boot, fraction: fraction,
                            detail: PrefixProgress.SubStep.boot.detail))
        }
        bootProgress.start()
        defer { bootProgress.stop() }
        let boot = try Subprocess.run(engine.activeWineBinary,
                                      arguments: ["wineboot", "--init"],
                                      environment: env, timeout: 900,
                                      logHandle: log?.handle,
                                      onLine: { line in
                                          // Every line is a sign of life; the
                                          // coordinator's stall detector reads these.
                                          progress?(.step(.boot, fraction: 0.5, detail: line))
                                      })
        guard boot.status == 0 else {
            throw PrefixError.bootFailed(status: boot.status, detail: String(boot.output.suffix(400)))
        }

        progress?(.step(.drain, fraction: 0, detail: PrefixProgress.SubStep.drain.detail))
        _ = try? Subprocess.run(engine.activeWineserverBinary, arguments: ["-w"],
                                environment: env, timeout: 900, captureOutput: false,
                                logHandle: log?.handle)
```

Before the Mono/Gecko check (currently `:74`):

```swift
        progress?(.step(.verify, fraction: 0, detail: PrefixProgress.SubStep.verify.detail))
```

Before the Retina registry writes (currently `:86`):

```swift
        progress?(.step(.registry, fraction: 0, detail: PrefixProgress.SubStep.registry.detail))
```

Before the folder-linking loop (currently `:111`):

```swift
        progress?(.step(.linking, fraction: 0, detail: PrefixProgress.SubStep.linking.detail))
```

Before the ready-marker write (currently `:144`):

```swift
        progress?(.step(.marker, fraction: 0, detail: PrefixProgress.SubStep.marker.detail))
```

Change the `provisionFonts` call site (currently `:99`) to pass both through:

```swift
        provisionFonts(env: env, log: log, progress: progress)
```

- [ ] **Step 5: Make the 57 font writes counted**

Replace `provisionFonts` and `regBestEffort` (currently `:178-212`):

```swift
    private func provisionFonts(env: [String: String], log: SetupLog?,
                                progress: (@Sendable (PrefixProgress) -> Void)?) {
        let fm = FileManager.default
        let fontsDir = paths.prefix.appendingPathComponent("drive_c/windows/Fonts")
        try? fm.createDirectory(at: fontsDir, withIntermediateDirectories: true)

        let total = Self.fontWriteCount
        var done = 0
        func tick() {
            done += 1
            progress?(.step(.fonts, fraction: Double(done) / Double(total),
                            detail: "Registering fonts (\(done) of \(total))…"))
        }

        if let src = Bundle.main.url(forResource: FontProvisioning.bundledFontResource,
                                     withExtension: "ttf") {
            let dst = fontsDir.appendingPathComponent(FontProvisioning.bundledFontFileName)
            try? fm.removeItem(at: dst)
            if (try? fm.copyItem(at: src, to: dst)) != nil {
                regBestEffort([#"HKLM\Software\Microsoft\Windows NT\CurrentVersion\Fonts"#,
                               "/v", "FontAwesome (TrueType)", "/t", "REG_SZ",
                               "/d", FontProvisioning.bundledFontFileName, "/f"],
                              env: env, log: log)
            }
        }
        tick() // counted whether or not the bundled font was present

        for (from, to) in FontProvisioning.substitutions {
            regBestEffort([#"HKLM\Software\Microsoft\Windows NT\CurrentVersion\FontSubstitutes"#,
                           "/v", from, "/t", "REG_SZ", "/d", to, "/f"], env: env, log: log)
            tick()
            regBestEffort([#"HKCU\Software\Wine\Fonts\Replacements"#,
                           "/v", from, "/t", "REG_SZ", "/d", to, "/f"], env: env, log: log)
            tick()
        }
    }

    private func regBestEffort(_ args: [String], env: [String: String], log: SetupLog?) {
        _ = try? Subprocess.run(engine.activeWineBinary, arguments: ["reg", "add"] + args,
                                environment: env, timeout: 60, captureOutput: false,
                                logHandle: log?.handle)
    }
```

Also give `registryAdd` (currently `:214`) a `log:` parameter and pass `logHandle: log?.handle`, updating its three call sites in the Retina/DPI block.

- [ ] **Step 6: Run tests and confirm every setup subprocess now logs**

Run: `swift test --filter PrefixManagerTests && swift build`
Expected: PASS (5 tests), build succeeds

Run: `grep -n "Subprocess.run" Sources/OpenXECore/PrefixManager.swift`
Expected: every call inside `ensurePrefix` passes `logHandle:`. `shutdownServer` may omit it (it runs outside setup).

- [ ] **Step 7: Commit**

```bash
git add Sources/OpenXECore/PrefixManager.swift Tests/OpenXECoreTests/PrefixManagerTests.swift
git commit -m "feat: report stage-4 sub-progress and log its subprocesses

The prefix build was a single unchanging string for the whole of its
runtime. It now reports seven sub-steps with a live 57-step font
counter, and every Wine subprocess in it tees to setup.log."
```

---

### Task 6: Batched font provisioning

**Independently revertable performance change.** It touches only `FontProvisioning` and `provisionFonts`, depends on nothing after Task 5, and nothing later depends on it. `git revert` of this one commit restores the per-write path — and flipping `useBatchedImport` to `false` does so without even that.

Replaces 57 spawned `wine reg add` processes with one generated `.reg` import: **24.38 s → 1.54 s measured** (spec §3.2), removing ~23 s from the only stage that cannot be resumed.

**Files:**
- Modify: `Sources/OpenXECore/FontProvisioning.swift` (add flag + generator after the substitution table, currently ends line 82)
- Modify: `Sources/OpenXECore/PrefixManager.swift` (`provisionFonts`, as rewritten in Task 5)
- Create: `scripts/verify-font-batching.sh`
- Test: `Tests/OpenXECoreTests/FontProvisioningTests.swift`

**Interfaces:**
- Consumes: `SetupLog` (Task 2), `PrefixProgress` (Task 5)
- Produces: `FontProvisioning.useBatchedImport: Bool`, `FontProvisioning.regFileContents() -> String`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import OpenXECore

/// Spec §5.3. The generator is pure, so its output is fully testable without
/// Wine. Registry *equivalence* is proven separately by
/// scripts/verify-font-batching.sh, which needs a real prefix.
final class FontProvisioningTests: XCTestCase {

    func testBatchedImportIsTheDefault() {
        XCTAssertTrue(FontProvisioning.useBatchedImport)
    }

    func testRegFileHasTheREGEDIT4HeaderAndIsASCII() {
        let reg = FontProvisioning.regFileContents()
        XCTAssertTrue(reg.hasPrefix("REGEDIT4\r\n"),
                      "wine's regedit needs the REGEDIT4 magic on line 1")
        XCTAssertTrue(reg.allSatisfy { $0.isASCII },
                      "ASCII only — chosen so no UTF-16LE/BOM handling is needed")
        XCTAssertTrue(reg.hasSuffix("\r\n"), "trailing newline required")
    }

    /// All three keys the per-write path touches, and no others.
    func testRegFileDeclaresExactlyTheThreeExpectedKeys() {
        let keys = FontProvisioning.regFileContents()
            .split(separator: "\r\n").filter { $0.hasPrefix("[") }.map(String.init)
        XCTAssertEqual(keys, [
            #"[HKEY_LOCAL_MACHINE\Software\Microsoft\Windows NT\CurrentVersion\Fonts]"#,
            #"[HKEY_LOCAL_MACHINE\Software\Microsoft\Windows NT\CurrentVersion\FontSubstitutes]"#,
            #"[HKEY_CURRENT_USER\Software\Wine\Fonts\Replacements]"#,
        ])
    }

    /// 1 FontAwesome + 28 substitutes + 28 replacements = 57, matching the
    /// per-write path exactly.
    func testRegFileContainsAll57Values() {
        let values = FontProvisioning.regFileContents()
            .split(separator: "\r\n").filter { $0.hasPrefix("\"") }
        XCTAssertEqual(values.count, PrefixManager.fontWriteCount)
        XCTAssertEqual(values.count, 57)
    }

    /// The substitution table stays the single source of truth — the .reg file
    /// is generated from it, never hand-maintained.
    func testEverySubstitutionAppearsInBothTables() {
        let reg = FontProvisioning.regFileContents()
        for (from, to) in FontProvisioning.substitutions {
            XCTAssertTrue(reg.contains("\"\(from)\"=\"\(to)\""),
                          "missing \(from) -> \(to)")
        }
        XCTAssertTrue(reg.contains(#""FontAwesome (TrueType)"="FontAwesome.ttf""#))
    }

    /// A family name containing a quote or backslash would corrupt the file.
    /// The table has none today; this guards against a future addition.
    func testNoSubstitutionNeedsEscaping() {
        for (from, to) in FontProvisioning.substitutions {
            XCTAssertFalse(from.contains("\"") || from.contains("\\"), "unescaped: \(from)")
            XCTAssertFalse(to.contains("\"") || to.contains("\\"), "unescaped: \(to)")
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter FontProvisioningTests`
Expected: FAIL — `type 'FontProvisioning' has no member 'useBatchedImport'`

- [ ] **Step 3: Add the flag and generator to `FontProvisioning.swift`**

Append inside the enum, after the `substitutions` table:

```swift
    /// Spec §5.3. When true, the 28x2+1 font registry values are written by a
    /// single `wine regedit` import instead of 57 spawned `wine reg add`
    /// processes — measured 24.38 s -> 1.54 s.
    ///
    /// The per-write path is retained as a fallback. If the import ever proves
    /// unreliable on a machine we cannot inspect, flip this to false to restore
    /// the proven behaviour with no code revert.
    ///
    /// REMOVAL CONDITION (spec §5.3) — this flag is not permanent. Delete it
    /// and `provisionFontsPerWrite` in one commit once BOTH have happened:
    ///   (a) one cold-machine run (spec §13.4) with the batched path, and
    ///   (b) one real end-to-end install with the batched path.
    /// `scripts/verify-font-batching.sh` stays afterwards as the regression
    /// guard. A fallback that is never exercised is not a safety net — it is a
    /// second code path that rots.
    public static let useBatchedImport = true

    /// The `.reg` file body, generated from `substitutions` so that table stays
    /// the single source of truth.
    ///
    /// REGEDIT4 / ASCII rather than "Windows Registry Editor Version 5.00":
    /// that format expects UTF-16LE and buys nothing here, because every family
    /// name above is ASCII. CRLF line endings are what the format specifies.
    public static func regFileContents() -> String {
        var lines: [String] = ["REGEDIT4", ""]

        lines.append(#"[HKEY_LOCAL_MACHINE\Software\Microsoft\Windows NT\CurrentVersion\Fonts]"#)
        lines.append("\"FontAwesome (TrueType)\"=\"\(bundledFontFileName)\"")
        lines.append("")

        lines.append(#"[HKEY_LOCAL_MACHINE\Software\Microsoft\Windows NT\CurrentVersion\FontSubstitutes]"#)
        for (from, to) in substitutions { lines.append("\"\(from)\"=\"\(to)\"") }
        lines.append("")

        lines.append(#"[HKEY_CURRENT_USER\Software\Wine\Fonts\Replacements]"#)
        for (from, to) in substitutions { lines.append("\"\(from)\"=\"\(to)\"") }
        lines.append("")

        return lines.joined(separator: "\r\n") + "\r\n"
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter FontProvisioningTests`
Expected: PASS (6 tests)

- [ ] **Step 5: Branch `provisionFonts` onto the batched path**

In `PrefixManager.swift`, keep the per-write body from Task 5 intact as `provisionFontsPerWrite` and add the batched path in front. Both remain best-effort: a failure is logged and swallowed, never thrown.

```swift
    private func provisionFonts(env: [String: String], log: SetupLog?,
                                progress: (@Sendable (PrefixProgress) -> Void)?) {
        let fm = FileManager.default
        let fontsDir = paths.prefix.appendingPathComponent("drive_c/windows/Fonts")
        try? fm.createDirectory(at: fontsDir, withIntermediateDirectories: true)

        // The bundled font file must be copied either way — the registry value
        // only names it.
        if let src = Bundle.main.url(forResource: FontProvisioning.bundledFontResource,
                                     withExtension: "ttf") {
            let dst = fontsDir.appendingPathComponent(FontProvisioning.bundledFontFileName)
            try? fm.removeItem(at: dst)
            try? fm.copyItem(at: src, to: dst)
        }

        progress?(.step(.fonts, fraction: 0, detail: "Registering fonts…"))

        if FontProvisioning.useBatchedImport, importFontRegistry(env: env, log: log) {
            progress?(.step(.fonts, fraction: 1, detail: "Registering fonts…"))
            return
        }

        // Fallback: the proven per-write path (spec §5.3).
        log?.note("font batch import unavailable or failed; using per-write fallback")
        provisionFontsPerWrite(env: env, log: log, progress: progress)
    }

    /// One `wine regedit <file>` import. Best-effort: returns false on any
    /// failure so the caller falls back. Never throws — font provisioning must
    /// never fail the prefix build.
    private func importFontRegistry(env: [String: String], log: SetupLog?) -> Bool {
        let fm = FileManager.default
        let regURL = paths.prefix.appendingPathComponent("openxe-fonts.reg")
        defer { try? fm.removeItem(at: regURL) }

        do {
            // ASCII by construction (spec §5.3); .ascii encoding makes that a
            // hard guarantee rather than an assumption.
            guard let data = FontProvisioning.regFileContents().data(using: .ascii) else {
                log?.note("font .reg contents were not ASCII; falling back")
                return false
            }
            try data.write(to: regURL)
        } catch {
            log?.note("could not write font .reg: \(error.localizedDescription)")
            return false
        }

        let result = try? Subprocess.run(engine.activeWineBinary,
                                         arguments: ["regedit", regURL.path],
                                         environment: env, timeout: 120,
                                         logHandle: log?.handle)
        guard let result, result.status == 0 else {
            log?.note("regedit import exited \(result?.status.description ?? "n/a")")
            return false
        }
        log?.note("font registry imported in one pass (\(PrefixManager.fontWriteCount) values)")
        return true
    }
```

Rename the Task 5 implementation to `provisionFontsPerWrite(env:log:progress:)`, unchanged otherwise — its 57-step counter is now the fallback path's progress reporting.

- [ ] **Step 6: Create `scripts/verify-font-batching.sh`**

Registry equivalence cannot be unit-tested — it needs a real prefix. Ship the proof as a repeatable script.

```bash
#!/bin/zsh
# Proves the batched font import produces registry state identical to the 57
# individual `wine reg add` calls (spec §5.3). Boots two throwaway prefixes,
# applies one method to each, and diffs the affected registry subtrees.
#
# Usage: scripts/verify-font-batching.sh [workdir]
# Exit 0 = identical. Exit 1 = differences (do NOT ship).
set -u
ENGINE="$HOME/Library/Application Support/OpenXE/engine/current"
WORK="${1:-$(mktemp -d)}"
REAL_PREFIX="$HOME/Library/Application Support/OpenXE/prefix"
case "$WORK" in "$REAL_PREFIX"*) echo "REFUSING: would touch the real prefix"; exit 1;; esac
[[ -x "$ENGINE/wine/bin/wine" ]] || { echo "no engine installed"; exit 1; }

export PATH="$ENGINE/wine/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export DYLD_FALLBACK_LIBRARY_PATH="$ENGINE/wine/lib:/usr/lib:/usr/local/lib"
export WINEDEBUG=fixme-all

PA="$WORK/pfx-individual"; PB="$WORK/pfx-batched"
boot() { rm -rf "$1"; mkdir -p "$1"; WINEPREFIX="$1" wine wineboot --init >/dev/null 2>&1; WINEPREFIX="$1" wineserver -w; }
echo "booting two throwaway prefixes..."; boot "$PA" & boot "$PB" & wait

# Method A: per-write. Generated from the same table the app uses.
swift run --package-path . openxe-dump-fontcmds 2>/dev/null || true
export WINEPREFIX="$PA"
wine reg add 'HKLM\Software\Microsoft\Windows NT\CurrentVersion\Fonts' \
    /v "FontAwesome (TrueType)" /t REG_SZ /d "FontAwesome.ttf" /f >/dev/null 2>&1
while IFS='|' read -r from to; do
  [[ -z "$from" ]] && continue
  wine reg add 'HKLM\Software\Microsoft\Windows NT\CurrentVersion\FontSubstitutes' \
      /v "$from" /t REG_SZ /d "$to" /f >/dev/null 2>&1
  wine reg add 'HKCU\Software\Wine\Fonts\Replacements' \
      /v "$from" /t REG_SZ /d "$to" /f >/dev/null 2>&1
done < "$WORK/substitutions.txt"

# Method B: batched import of the file the app generates.
export WINEPREFIX="$PB"
wine regedit "$WORK/fonts.reg" >/dev/null 2>&1

# Extract + normalise the affected subtrees. NOTE: do not pass registry key
# patterns through `awk -v` — it consumes backslashes and silently matches
# nothing, which looks exactly like a passing diff.
extract() {
  local P="$1" OUT="$2"; : > "$OUT"
  for pair in "user.reg:Wine.*Fonts.*Replacements" \
              "system.reg:Microsoft.*Windows NT.*CurrentVersion.*FontSubstitutes" \
              "system.reg:Microsoft.*Windows NT.*CurrentVersion.*Fonts\]"; do
    local f="${pair%%:*}" pat="${pair##*:}"
    print -r -- "### $pat" >> "$OUT"
    grep -n "^\[.*${pat}" "$P/$f" 2>/dev/null | cut -d: -f1 | while read -r ln; do
      print -r -- "--- key: $(sed -n "${ln}p" "$P/$f" | sed 's/ [0-9]*$//')" >> "$OUT"
      sed -n "$((ln+1)),\$p" "$P/$f" | sed -n '/^\[/q;/^"/p' | LC_ALL=C sort >> "$OUT"
    done
  done
}
extract "$PA" "$WORK/A.txt"; extract "$PB" "$WORK/B.txt"

COUNT_A=$(grep -c '^"' "$WORK/A.txt"); COUNT_B=$(grep -c '^"' "$WORK/B.txt")
echo "value lines: individual=$COUNT_A batched=$COUNT_B"
if [[ "$COUNT_A" -eq 0 || "$COUNT_B" -eq 0 ]]; then
  echo "FAIL: extraction produced nothing — the comparison is meaningless"; RC=1
elif diff -u "$WORK/A.txt" "$WORK/B.txt"; then
  echo "PASS: registry state is identical"; RC=0
else
  echo "FAIL: registry state differs"; RC=1
fi

for P in "$PA" "$PB"; do WINEPREFIX="$P" wineserver -k 2>/dev/null; done
exit $RC
```

The script reads `$WORK/substitutions.txt` (`from|to` per line) and `$WORK/fonts.reg`. Add a tiny debug entry point that writes both from the live `FontProvisioning` table, so the script can never drift from the app's own data:

```swift
// In FontProvisioning, for the verification script.
public static func writeVerificationFixtures(to directory: URL) throws {
    let subs = substitutions.map { "\($0.from)|\($0.to)" }.joined(separator: "\n") + "\n"
    try Data(subs.utf8).write(to: directory.appendingPathComponent("substitutions.txt"))
    try Data(regFileContents().utf8).write(to: directory.appendingPathComponent("fonts.reg"))
}
```

- [ ] **Step 7: Run the equivalence proof — this is the acceptance bar**

Run:
```bash
chmod +x scripts/verify-font-batching.sh
scripts/verify-font-batching.sh /tmp/openxe-fontverify
```

Expected: `value lines: individual=647 batched=647` (exact count varies with the engine's own font registrations, but **both sides must be non-zero and equal**), then `PASS: registry state is identical`, exit 0.

A zero count on either side is a FAIL, not a pass — the reference run of this comparison reported "identical" from two empty extractions (spec §3.2). **Do not proceed on "it didn't error".**

Then confirm no stray processes and the real prefix is untouched:

```bash
pgrep -fl wineserver || echo "no stray wineservers"
cat "$HOME/Library/Application Support/OpenXE/prefix/.openxe-ready"
```

Expected: no strays; the marker still reads `engine=gcenx-stable-11.0_1`.

- [ ] **Step 8: Verify the stage-4 speedup landed**

Run: `swift test --filter PrefixManagerTests && swift build`
Expected: PASS; build succeeds

- [ ] **Step 9: Commit**

```bash
git add Sources/OpenXECore/FontProvisioning.swift Sources/OpenXECore/PrefixManager.swift \
        scripts/verify-font-batching.sh Tests/OpenXECoreTests/FontProvisioningTests.swift
git commit -m "perf: batch font registry writes into one regedit import

57 spawned wine reg add processes (24.38s) become one .reg import
(1.54s), removing ~23s from the only stage that cannot resume.
Equivalence proven by scripts/verify-font-batching.sh: byte-identical
registry state across all five affected keys.

Per-write path retained behind FontProvisioning.useBatchedImport."
```

---

### Task 7: EngineManager — commit reordering and unpack counting

Eliminates the one unrecoverable state in the current code (§10.1) and gives stage 3 a file counter.

**Files:**
- Modify: `Sources/OpenXECore/EngineManager.swift:293-330` (`extractAndInstall`)
- Test: `Tests/OpenXECoreTests/EngineManagerTests.swift` (append)

**Interfaces:**
- Consumes: `SetupLog` (Task 2)
- Produces: `EngineManager.expectedArchiveEntries: Int`; `extractAndInstall` gains `log:` and `onEntry:`

- [ ] **Step 1: Write the failing test**

```swift
    /// Spec §10.1: descriptor.json is the atomic commit point. If it exists,
    /// the engine is fully installed AND de-quarantined. A kill before that
    /// must leave the engine reporting not-installed so it is re-extracted.
    func testDescriptorIsWrittenLastSoItActsAsTheCommitPoint() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("openxe-commit-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let paths = OpenXEPaths(root: root)
        let mgr = EngineManager(paths: paths)

        let engineDir = paths.engineVersions.appendingPathComponent("test-engine")
        let binDir = engineDir.appendingPathComponent("wine/bin")
        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        fm.createFile(atPath: binDir.appendingPathComponent("wine").path,
                      contents: Data("x".utf8), attributes: [.posixPermissions: 0o755])
        // version marker present, descriptor.json absent = interrupted mid-commit
        try Data("test\n".utf8).write(to: engineDir.appendingPathComponent("version"))

        XCTAssertNil(mgr.descriptor(forInstalledID: "test-engine"),
                     "a version file without descriptor.json must NOT look installed")
        XCTAssertFalse(mgr.isInstalled("test-engine"))
    }

    /// Measured via `tar -tf` in Step 4, not estimated. The installed tree is
    /// 5,324 entries and is a strict subset of the archive.
    func testExpectedArchiveEntriesWasMeasured() {
        XCTAssertGreaterThan(EngineManager.expectedArchiveEntries, 5_324,
                             "must be the measured archive count, not the installed-tree count")
    }
```

> **Note:** the first assertion changes existing behaviour. `descriptor(forInstalledID:)` currently backfills a descriptor from a bare `version` file (`EngineManager.swift:123-141`), which is exactly what makes the half-committed engine look installed. The backfill must now additionally require that quarantine has been stripped — see Step 3.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter EngineManagerTests/testDescriptorIsWrittenLastSoItActsAsTheCommitPoint`
Expected: FAIL — the legacy backfill synthesises a descriptor, so `descriptor(...)` is non-nil

- [ ] **Step 3: Reorder the commit sequence**

Replace the tail of `extractAndInstall` (currently `EngineManager.swift:316-330`) so de-quarantine precedes the metadata writes and `descriptor.json` lands last, atomically:

```swift
        let engineDir = paths.engineVersions.appendingPathComponent(descriptor.id, isDirectory: true)
        try? fm.removeItem(at: engineDir)
        try fm.createDirectory(at: engineDir, withIntermediateDirectories: true)
        try fm.moveItem(at: wineRoot, to: engineDir.appendingPathComponent("wine"))

        // De-quarantine BEFORE recording the descriptor. Gatekeeper would block
        // the unsigned Wine binaries otherwise, and until 2026-08-08 a kill in
        // this window left an engine that reported installed but could never
        // run, with no code path to repair it (spec §10.1).
        try Self.stripQuarantine(at: engineDir)

        try Data("\(descriptor.version)\n".utf8)
            .write(to: engineDir.appendingPathComponent("version"))

        // descriptor.json is the atomic commit point: its existence means
        // "fully installed and de-quarantined". Written via a temp file so a
        // crash mid-write cannot leave a truncated descriptor behind.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let descriptorURL = engineDir.appendingPathComponent("descriptor.json")
        let tmp = engineDir.appendingPathComponent("descriptor.json.tmp")
        try encoder.encode(descriptor).write(to: tmp)
        _ = try fm.replaceItemAt(descriptorURL, withItemAt: tmp)
```

Then tighten the legacy backfill so it cannot resurrect a half-committed engine. In `descriptor(forInstalledID:)` (currently `:124-128`), add a quarantine check to the guard:

```swift
        let fm = FileManager.default
        let wineLoader = engineDir.appendingPathComponent("wine/bin/wine")
        guard fm.isExecutableFile(atPath: wineLoader.path),
              !Self.isQuarantined(at: wineLoader),
              let version = try? String(contentsOf: engineDir.appendingPathComponent("version"),
                                        encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
```

And add the helper beside `stripQuarantine`:

```swift
    /// True when the file still carries com.apple.quarantine. Used to refuse
    /// the legacy backfill for an engine that was never de-quarantined.
    static func isQuarantined(at url: URL) -> Bool {
        let result = try? Subprocess.run(URL(fileURLWithPath: "/usr/bin/xattr"),
                                         arguments: ["-p", "com.apple.quarantine", url.path],
                                         timeout: 10)
        return result?.status == 0
    }
```

- [ ] **Step 4: Measure `expectedArchiveEntries` — do not estimate it**

The pinned archive is listed without extracting. This is a one-time developer action; re-run it only if the engine is repinned.

```bash
cd "$(mktemp -d)"
curl -L -o engine.tar.xz \
  "https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.0_1/wine-stable-11.0_1-osx64.tar.xz"
shasum -a 256 engine.tar.xz   # must be b50dc50ec7f41d58b115a6b685d4d1315ba3c797bd3aa0f49213f2703cb82388
tar -tf engine.tar.xz | wc -l
```

Expected: the checksum matches `EngineCatalog.stock.sha256`, and the count is a number above 5,324 (the installed tree is a strict subset). Put that number into `expectedArchiveEntries`, replacing the `0` placeholder, and update the test below to assert it.

If the checksum does **not** match, stop — the pinned asset has been replaced upstream and that is a separate problem (spec §4.1 notes the pin exists to catch exactly this).

- [ ] **Step 5: Add unpack counting**

Add the constant near `findWineRoot`:

```swift
    /// Entries the pinned engine archive contains. MEASURED via `tar -tf`
    /// (spec §5.2) — not the installed tree's 5,324, which excludes the outer
    /// `.app` wrapper `findWineRoot` discards and includes two files written
    /// after extraction. Re-derive only if the engine is repinned; see
    /// Step 4 for the exact command. Progress clamps as a safety net.
    public static let expectedArchiveEntries = 0   // <- replace in Step 4
```

Change the `tar` invocation (currently `:300-303`) to stream and count:

```swift
        let counter = EntryCounter()
        let untar = try Subprocess.run(
            URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-xvf", archive.path, "-C", staging.path],
            timeout: 900,
            logHandle: nil,               // sampled below, not teed verbatim
            onLine: { _ in
                let n = counter.increment()
                // Bound log volume: every 200th path, per spec §5.2.
                if n % 200 == 0 { log?.note("unpacked \(n) entries") }
                onEntry?(n)
            })
```

Add the counter type at file scope:

```swift
/// Thread-safe entry counter for the unpack progress stream.
final class EntryCounter: @unchecked Sendable {
    private var count = 0
    private let lock = NSLock()
    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return count
    }
}
```

Widen `extractAndInstall` and `install` to carry `log: SetupLog?` and `onEntry: (@Sendable (Int) -> Void)?`, both defaulted to `nil` so existing callers and tests compile unchanged.

- [ ] **Step 6: Run tests**

Run: `swift test --filter EngineManagerTests && swift build`
Expected: PASS, build succeeds. `testExpectedArchiveEntriesIsPlausible` now asserts the measured value, not a guess.

- [ ] **Step 7: Commit**

```bash
git add Sources/OpenXECore/EngineManager.swift Tests/OpenXECoreTests/EngineManagerTests.swift
git commit -m "fix: make descriptor.json the atomic engine commit point

A kill between the version write and stripQuarantine left an engine that
passed isInstalled but whose Wine binaries were still quarantined, with
no path to repair it. De-quarantine now precedes the metadata writes and
descriptor.json is written last, atomically."
```

---

### Task 8: SetupJournal

**Files:**
- Create: `Sources/OpenXECore/SetupJournal.swift`
- Test: `Tests/OpenXECoreTests/SetupJournalTests.swift`

**Interfaces:**
- Consumes: `SetupStage.ID` (Task 3)
- Produces: `SetupJournal`, `StageState`, `StageRecord`, `SetupJournal.load(from:)`, `.save(to:)`, `.record(_:as:error:elapsed:)`, `.beginAttempt(_:)`, `.reconcileInterruptedRun()`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import OpenXECore

final class SetupJournalTests: XCTestCase {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("openxe-journal-\(UUID().uuidString).json")
    }

    func testRoundTripsThroughJSON() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        var j = SetupJournal.fresh()
        j.engineID = "gcenx-stable-11.0_1"
        j.nwsTag = "8.2.1460"
        j.record(.downloadEngine, as: .completed, elapsed: 141.2)
        try j.save(to: url)

        let back = try XCTUnwrap(SetupJournal.load(from: url))
        XCTAssertEqual(back.engineID, "gcenx-stable-11.0_1")
        XCTAssertEqual(back.nwsTag, "8.2.1460")
        XCTAssertEqual(back.stages[.downloadEngine]?.state, .completed)
        XCTAssertEqual(back.stages[.downloadEngine]?.elapsedSeconds ?? 0, 141.2, accuracy: 0.01)
    }

    func testAttemptsAccumulateAcrossRuns() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        var j = SetupJournal.fresh()
        j.beginAttempt(.downloadEngine)
        j.record(.downloadEngine, as: .failed,
                 error: .init(kind: "network", detail: "timed out"))
        try j.save(to: url)

        var second = try XCTUnwrap(SetupJournal.load(from: url))
        second.beginAttempt(.downloadEngine)
        XCTAssertEqual(second.stages[.downloadEngine]?.attempts, 2,
                       "attempt count must survive across runs")
        XCTAssertEqual(second.stages[.downloadEngine]?.lastError?.kind, "network")
    }

    /// Spec §8.4: outcome "running" at startup means the previous run was
    /// force-quit or crashed.
    func testInterruptedRunReconcilesToCancelled() throws {
        var j = SetupJournal.fresh()
        j.beginAttempt(.preparePrefix)
        j.record(.downloadEngine, as: .completed, elapsed: 10)
        XCTAssertEqual(j.outcome, .running)

        j.reconcileInterruptedRun()
        XCTAssertEqual(j.outcome, .cancelled)
        XCTAssertEqual(j.stages[.preparePrefix]?.state, .cancelled)
        XCTAssertEqual(j.stages[.downloadEngine]?.state, .completed,
                       "completed stages must survive reconciliation")
    }

    func testUnknownSchemaVersionIsDiscarded() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"schemaVersion": 99, "runID": "x", "outcome": "running"}"#.utf8).write(to: url)
        XCTAssertNil(SetupJournal.load(from: url),
                     "a future schema must be discarded, never crash")
    }

    func testCorruptJournalIsDiscardedNotThrown() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{ this is not json".utf8).write(to: url)
        XCTAssertNil(SetupJournal.load(from: url))
    }

    func testSaveIsAtomic() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        var j = SetupJournal.fresh()
        try j.save(to: url)
        j.record(.installNWS, as: .completed, elapsed: 35)
        try j.save(to: url)
        // A readable, complete journal after an overwrite.
        let back = try XCTUnwrap(SetupJournal.load(from: url))
        XCTAssertEqual(back.stages[.installNWS]?.state, .completed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path + ".tmp"),
                       "temp file must not be left behind")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SetupJournalTests`
Expected: FAIL — `cannot find 'SetupJournal' in scope`

- [ ] **Step 3: Implement `SetupJournal.swift`**

```swift
import Foundation

public enum StageState: String, Codable, Sendable {
    case pending, running, completed, failed, cancelled
}

public enum SetupOutcome: String, Codable, Sendable {
    case running, succeeded, failed, cancelled
}

public struct JournalError: Codable, Sendable, Equatable {
    public let kind: String
    public let detail: String
    public var at: String = ISO8601DateFormatter().string(from: Date())

    public init(kind: String, detail: String) {
        self.kind = kind
        self.detail = detail
    }
}

public struct StageRecord: Codable, Sendable {
    public var state: StageState = .pending
    public var attempts: Int = 0
    public var elapsedSeconds: Double?
    public var startedAt: String?
    public var completedAt: String?
    public var lastError: JournalError?
}

/// Advisory record of setup progress (spec §6.2).
///
/// THE FILESYSTEM IS AUTHORITATIVE. This file supplies only what the
/// filesystem cannot express: attempt counts, error history, elapsed times,
/// the chosen NWS tag, and whether a partial archive was already verified.
/// A journal claiming a stage is complete never overrides a ground-truth
/// check that says otherwise.
public struct SetupJournal: Codable, Sendable {

    public static let currentSchema = 1

    public var schemaVersion: Int = SetupJournal.currentSchema
    public var runID: String
    public var startedAt: String
    public var updatedAt: String
    public var outcome: SetupOutcome = .running
    public var engineID: String?
    public var engineSHA256: String?
    public var archiveVerified: Bool = false
    public var nwsTag: String?
    public var nwsExpectedSize: Int64?
    public var stages: [SetupStage.ID: StageRecord] = [:]

    public static func fresh() -> SetupJournal {
        let now = ISO8601DateFormatter().string(from: Date())
        var j = SetupJournal(runID: UUID().uuidString, startedAt: now, updatedAt: now)
        for id in SetupStage.ID.allCases { j.stages[id] = StageRecord() }
        return j
    }

    public mutating func beginAttempt(_ id: SetupStage.ID) {
        var r = stages[id] ?? StageRecord()
        r.attempts += 1
        r.state = .running
        r.startedAt = ISO8601DateFormatter().string(from: Date())
        stages[id] = r
        outcome = .running
        touch()
    }

    public mutating func record(_ id: SetupStage.ID, as state: StageState,
                                error: JournalError? = nil, elapsed: Double? = nil) {
        var r = stages[id] ?? StageRecord()
        r.state = state
        if let elapsed { r.elapsedSeconds = elapsed }
        if let error { r.lastError = error }
        if state == .completed {
            r.completedAt = ISO8601DateFormatter().string(from: Date())
            r.lastError = nil
        }
        stages[id] = r
        touch()
    }

    /// A journal found with `outcome == .running` belongs to a run that died
    /// without unwinding — force-quit or crash (spec §8.4). Completed stages
    /// and attempt counts are preserved.
    public mutating func reconcileInterruptedRun() {
        guard outcome == .running else { return }
        for (id, record) in stages where record.state == .running {
            var r = record
            r.state = .cancelled
            stages[id] = r
        }
        outcome = .cancelled
        touch()
    }

    private mutating func touch() {
        updatedAt = ISO8601DateFormatter().string(from: Date())
    }

    // MARK: persistence

    /// Returns nil for a missing, corrupt, or future-schema journal — never
    /// throws. A bad journal must degrade to "no journal", not block setup.
    public static func load(from url: URL) -> SetupJournal? {
        guard let data = try? Data(contentsOf: url),
              let j = try? JSONDecoder().decode(SetupJournal.self, from: data),
              j.schemaVersion == currentSchema
        else { return nil }
        return j
    }

    /// Atomic: write to a sibling temp file, then replace. A crash mid-write
    /// cannot corrupt the live journal.
    public func save(to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        let tmp = URL(fileURLWithPath: url.path + ".tmp")
        try data.write(to: tmp)
        if fm.fileExists(atPath: url.path) {
            _ = try fm.replaceItemAt(url, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: url)
        }
    }
}
```

> `[SetupStage.ID: StageRecord]` encodes as a JSON object because `SetupStage.ID`'s raw value is `String`.

- [ ] **Step 4: Run tests**

Run: `swift test --filter SetupJournalTests`
Expected: PASS (6 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenXECore/SetupJournal.swift Tests/OpenXECoreTests/SetupJournalTests.swift
git commit -m "feat: add SetupJournal

Advisory on-disk record of setup progress. Atomic writes; corrupt or
future-schema journals degrade to nil rather than blocking setup."
```

---

### Task 9: ChildRegistry

Without this, cancel cannot work: `Task.cancel()` cannot interrupt `Subprocess.run`'s semaphore wait (§4.3).

**Files:**
- Create: `Sources/OpenXECore/ChildRegistry.swift`
- Modify: `Sources/OpenXECore/Subprocess.swift` (register/deregister around `process.run()`)
- Test: `Tests/OpenXECoreTests/ChildRegistryTests.swift`

**Interfaces:**
- Produces: `ChildRegistry()`, `.register(_:label:)`, `.deregister(_:)`, `.terminateAll()`, `.liveCount`
- Modifies: `Subprocess.run(..., registry: ChildRegistry? = nil)`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import OpenXECore

final class ChildRegistryTests: XCTestCase {

    func testRegisterAndDeregisterTrackLiveCount() {
        let r = ChildRegistry()
        XCTAssertEqual(r.liveCount, 0)
        r.register(4242, label: "fake")
        XCTAssertEqual(r.liveCount, 1)
        r.deregister(4242)
        XCTAssertEqual(r.liveCount, 0)
    }

    /// The behaviour cancel depends on: a long-running child is actually killed.
    func testTerminateAllKillsALiveChild() throws {
        let registry = ChildRegistry()
        let started = expectation(description: "child started")
        var result: SubprocessResult?

        DispatchQueue.global().async {
            started.fulfill()
            result = try? Subprocess.run(URL(fileURLWithPath: "/bin/sleep"),
                                         arguments: ["30"], timeout: 60,
                                         registry: registry)
        }
        wait(for: [started], timeout: 5)

        // Give the child a moment to register.
        let deadline = Date().addingTimeInterval(5)
        while registry.liveCount == 0 && Date() < deadline { usleep(50_000) }
        XCTAssertEqual(registry.liveCount, 1, "child should be registered")

        let t0 = Date()
        registry.terminateAll()
        let waitUntil = Date().addingTimeInterval(10)
        while result == nil && Date() < waitUntil { usleep(50_000) }

        XCTAssertNotNil(result, "terminateAll must unblock the subprocess wait")
        XCTAssertLessThan(Date().timeIntervalSince(t0), 8,
                          "kill should be prompt, not wait out the 30s sleep")
        XCTAssertEqual(registry.liveCount, 0)
    }

    func testTerminateAllOnEmptyRegistryIsSafe() {
        let r = ChildRegistry()
        r.terminateAll()
        XCTAssertEqual(r.liveCount, 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ChildRegistryTests`
Expected: FAIL — `cannot find 'ChildRegistry' in scope`

- [ ] **Step 3: Implement `ChildRegistry.swift`**

```swift
import Foundation

/// Tracks live setup child processes so a cancel can actually kill them
/// (spec §4.3). Children are otherwise never signalled: the app exits and
/// `tar`/`wine` keep running, reparented to launchd.
///
/// Killing the child is also what releases `Subprocess.run`'s blocked
/// semaphore — a cancellation flag alone cannot.
public final class ChildRegistry: @unchecked Sendable {

    private var pids: [pid_t: String] = [:]
    private let lock = NSLock()

    public init() {}

    public var liveCount: Int {
        lock.lock(); defer { lock.unlock() }
        return pids.count
    }

    public func register(_ pid: pid_t, label: String) {
        lock.lock(); pids[pid] = label; lock.unlock()
    }

    public func deregister(_ pid: pid_t) {
        lock.lock(); pids.removeValue(forKey: pid); lock.unlock()
    }

    /// SIGTERM every live child, allow a 400 ms grace period, then SIGKILL any
    /// survivor. Same pattern as WineServerHousekeeping.terminate.
    public func terminateAll() {
        lock.lock()
        let live = Array(pids.keys)
        lock.unlock()
        guard !live.isEmpty else { return }

        for pid in live { kill(pid, SIGTERM) }
        usleep(400_000)
        for pid in live where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }
}
```

- [ ] **Step 4: Wire it into `Subprocess.run`**

Add the parameter after `captureOutput`:

```swift
        registry: ChildRegistry? = nil
```

Then, immediately after `try process.run()` (currently line 72):

```swift
        try process.run()
        let childPID = process.processIdentifier
        registry?.register(childPID, label: executable.lastPathComponent)
        defer { registry?.deregister(childPID) }
```

- [ ] **Step 5: Run tests**

Run: `swift test --filter ChildRegistryTests && swift build && swift test`
Expected: PASS (3 tests); full suite green

- [ ] **Step 6: Commit**

```bash
git add Sources/OpenXECore/ChildRegistry.swift Sources/OpenXECore/Subprocess.swift \
        Tests/OpenXECoreTests/ChildRegistryTests.swift
git commit -m "feat: add ChildRegistry so cancel can kill children

Setup children are never signalled today; the app exits and tar/wine
keep running. Killing the child is also what unblocks Subprocess.run."
```

---

### Task 10: SetupPreflight

**Files:**
- Create: `Sources/OpenXECore/SetupPreflight.swift`
- Test: `Tests/OpenXECoreTests/SetupPreflightTests.swift`

**Interfaces:**
- Consumes: `RosettaCheck` (`Runner.swift:314-339`), `SetupFailure` (Task 3)
- Produces: `SetupPreflight(paths:)`, `.requiredFreeBytes`, `.check(freeBytesOverride:rosettaOverride:) throws`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import OpenXECore

final class SetupPreflightTests: XCTestCase {

    private func paths() -> OpenXEPaths {
        OpenXEPaths(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("openxe-preflight-\(UUID().uuidString)"))
    }

    /// Spec §9.5: 1.41 GB measured need + headroom = 2.0 GB.
    func testRequiredFreeSpaceIs2GB() {
        XCTAssertEqual(SetupPreflight.requiredFreeBytes, 2_147_483_648)
    }

    func testFailsWhenDiskIsTooSmall() {
        let p = SetupPreflight(paths: paths())
        XCTAssertThrowsError(try p.check(freeBytesOverride: 500_000_000,
                                         rosettaOverride: true)) { error in
            let f = error as? SetupFailure
            XCTAssertEqual(f?.kind, .diskSpace)
            XCTAssertEqual(f?.stage, .preflight)
            // The real figure must appear, so the user knows how much to free.
            XCTAssertTrue(f?.userMessage.contains("0.5 GB") ?? false,
                          "got: \(f?.userMessage ?? "nil")")
        }
    }

    func testFailsWhenRosettaMissing() {
        let p = SetupPreflight(paths: paths())
        XCTAssertThrowsError(try p.check(freeBytesOverride: 10_000_000_000,
                                         rosettaOverride: false)) { error in
            XCTAssertEqual((error as? SetupFailure)?.kind, .rosettaMissing)
        }
    }

    func testPassesWhenBothSatisfied() throws {
        let p = SetupPreflight(paths: paths())
        XCTAssertNoThrow(try p.check(freeBytesOverride: 10_000_000_000,
                                     rosettaOverride: true))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SetupPreflightTests`
Expected: FAIL — `cannot find 'SetupPreflight' in scope`

- [ ] **Step 3: Implement `SetupPreflight.swift`**

```swift
import Foundation

/// Stage 1 (spec §9.5). Runs on BOTH the wizard and launch paths — today the
/// Rosetta gate is reachable only from the launch path, so a wizard user
/// without Rosetta downloads 177 MB before failing cryptically at wineboot.
public struct SetupPreflight: Sendable {

    /// 1.41 GB measured peak (spec §3) plus ~0.6 GB headroom for APFS
    /// overhead, logs, and the transient archive.
    public static let requiredFreeBytes: Int64 = 2_147_483_648

    private let paths: OpenXEPaths

    public init(paths: OpenXEPaths) { self.paths = paths }

    /// Overrides exist for tests; production passes nil and measures.
    public func check(freeBytesOverride: Int64? = nil,
                      rosettaOverride: Bool? = nil) throws {
        let free = try freeBytesOverride ?? Self.freeBytes(forVolumeContaining: paths.root)
        guard free >= Self.requiredFreeBytes else {
            throw SetupFailure(
                stage: .preflight, kind: .diskSpace,
                userMessage: "Your Mac needs about 2 GB of free space to set up "
                    + "New World Scheduler. It currently has \(Self.gb(free)) free.",
                suggestedAction: "Free up some space, then try again.",
                technicalDetail: "free=\(free) required=\(Self.requiredFreeBytes)",
                isRetryable: true)
        }

        let rosetta = rosettaOverride ?? RosettaCheck.canRunX86_64
        guard rosetta else {
            throw SetupFailure(
                stage: .preflight, kind: .rosettaMissing,
                userMessage: "OpenXE needs Apple's Rosetta 2 to run the Windows environment.",
                suggestedAction: "Install Rosetta 2 when prompted, then try again.",
                technicalDetail: "RosettaCheck.canRunX86_64 == false",
                isRetryable: true)
        }
    }

    /// Free space on the volume holding `url`, walking up to the nearest
    /// existing ancestor since the root may not exist on a first run.
    static func freeBytes(forVolumeContaining url: URL) throws -> Int64 {
        var probe = url
        let fm = FileManager.default
        while !fm.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe = probe.deletingLastPathComponent()
        }
        let values = try probe.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values.volumeAvailableCapacityForImportantUsage ?? 0
    }

    static func gb(_ bytes: Int64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter SetupPreflightTests`
Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenXECore/SetupPreflight.swift Tests/OpenXECoreTests/SetupPreflightTests.swift
git commit -m "feat: add setup preflight (disk space + Rosetta)

Runs on both the wizard and launch paths; the Rosetta gate was
previously reachable only from the launch path."
```

---

### Task 11: StallDetector

**Files:**
- Create: `Sources/OpenXECore/StallDetector.swift`
- Test: `Tests/OpenXECoreTests/StallDetectorTests.swift`

**Interfaces:**
- Produces: `StallDetector(threshold:onStall:onRecover:)`, `.noteActivity()`, `.start()`, `.stop()`, `.keepWaiting()`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import OpenXECore

final class StallDetectorTests: XCTestCase {

    func testFiresAfterThresholdOfSilence() {
        let stalled = expectation(description: "stalled")
        let d = StallDetector(threshold: 0.3, pollInterval: 0.05,
                              onStall: { _ in stalled.fulfill() }, onRecover: {})
        d.start()
        defer { d.stop() }
        wait(for: [stalled], timeout: 3)
    }

    func testActivityPreventsTheStall() {
        let stalled = expectation(description: "must not stall")
        stalled.isInverted = true
        let d = StallDetector(threshold: 0.4, pollInterval: 0.05,
                              onStall: { _ in stalled.fulfill() }, onRecover: {})
        d.start()
        defer { d.stop() }
        // Beat the threshold repeatedly.
        for _ in 0..<10 { usleep(100_000); d.noteActivity() }
        wait(for: [stalled], timeout: 0.5)
    }

    func testRecoversWhenActivityResumes() {
        let stalled = expectation(description: "stalled")
        let recovered = expectation(description: "recovered")
        let d = StallDetector(threshold: 0.3, pollInterval: 0.05,
                              onStall: { _ in stalled.fulfill() },
                              onRecover: { recovered.fulfill() })
        d.start()
        defer { d.stop() }
        wait(for: [stalled], timeout: 3)
        d.noteActivity()
        wait(for: [recovered], timeout: 3)
    }

    /// Spec §7.2: Keep Waiting doubles the threshold so one click is cheap.
    func testKeepWaitingDoublesTheThreshold() {
        let d = StallDetector(threshold: 60, pollInterval: 1,
                              onStall: { _ in }, onRecover: {})
        XCTAssertEqual(d.currentThreshold, 60)
        d.keepWaiting()
        XCTAssertEqual(d.currentThreshold, 120)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter StallDetectorTests`
Expected: FAIL — `cannot find 'StallDetector' in scope`

- [ ] **Step 3: Implement `StallDetector.swift`**

```swift
import Foundation

/// Liveness watchdog (spec §7.2). "Stalled" is a UI state, not a terminal
/// one: the stage keeps running underneath and the hard ceiling still governs.
///
/// The spike measured a 4.47 s worst gap between signs of life during the
/// prefix build, so the 60 s default carries ~13x margin against false
/// positives.
public final class StallDetector: @unchecked Sendable {

    public static let defaultThreshold: TimeInterval = 60

    private let pollInterval: TimeInterval
    private let onStall: @Sendable (TimeInterval) -> Void
    private let onRecover: @Sendable () -> Void

    private var threshold: TimeInterval
    private var lastActivity = Date()
    private var isStalled = false
    private var timer: DispatchSourceTimer?
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "dev.openxe.stall-detector")

    public init(threshold: TimeInterval = StallDetector.defaultThreshold,
                pollInterval: TimeInterval = 1,
                onStall: @escaping @Sendable (TimeInterval) -> Void,
                onRecover: @escaping @Sendable () -> Void) {
        self.threshold = threshold
        self.pollInterval = pollInterval
        self.onStall = onStall
        self.onRecover = onRecover
    }

    public var currentThreshold: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return threshold
    }

    /// Any sign of life: an output line, a counter advance, filesystem growth.
    public func noteActivity() {
        lock.lock()
        lastActivity = Date()
        let wasStalled = isStalled
        isStalled = false
        lock.unlock()
        if wasStalled { onRecover() }
    }

    /// User chose Keep Waiting: reset and double the threshold so a second
    /// warning is not immediate.
    public func keepWaiting() {
        lock.lock()
        threshold *= 2
        lastActivity = Date()
        isStalled = false
        lock.unlock()
    }

    public func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        t.setEventHandler { [weak self] in self?.tick() }
        lock.lock(); timer = t; lastActivity = Date(); lock.unlock()
        t.resume()
    }

    public func stop() {
        lock.lock(); let t = timer; timer = nil; lock.unlock()
        t?.cancel()
    }

    private func tick() {
        lock.lock()
        let silent = Date().timeIntervalSince(lastActivity)
        let shouldFire = !isStalled && silent >= threshold
        if shouldFire { isStalled = true }
        lock.unlock()
        if shouldFire { onStall(silent) }
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter StallDetectorTests`
Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenXECore/StallDetector.swift Tests/OpenXECoreTests/StallDetectorTests.swift
git commit -m "feat: add StallDetector liveness watchdog"
```

---

### Task 12: SetupSweeper

The only defence against force-quit, which no handler can intercept (§8.2).

**Files:**
- Create: `Sources/OpenXECore/SetupSweeper.swift`
- Test: `Tests/OpenXECoreTests/SetupSweeperTests.swift`

**Interfaces:**
- Consumes: `OpenXEPaths` (Task 1), `SetupJournal` (Task 8), `WineServerHousekeeping.sweepStaleServer`
- Produces: `SetupSweeper(paths:)`, `.sweep(log:) -> SweepReport`, `SweepReport{stagingRemoved, partialsRemoved, nwsDownloadRemoved, journalReconciled, bytesReclaimed}`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import OpenXECore

final class SetupSweeperTests: XCTestCase {

    private func makeRoot() throws -> (OpenXEPaths, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openxe-sweep-\(UUID().uuidString)")
        let paths = OpenXEPaths(root: root)
        try FileManager.default.createDirectory(at: paths.engineVersions,
                                                withIntermediateDirectories: true)
        return (paths, root)
    }

    /// Up to 666 MB each, leaked forever today (spec §8.4).
    func testStagingDirectoriesAreAlwaysRemoved() throws {
        let (paths, root) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = paths.engineVersions.appendingPathComponent("staging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 4096).write(to: staging.appendingPathComponent("junk"))

        let report = SetupSweeper(paths: paths).sweep()
        XCTAssertEqual(report.stagingRemoved, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    /// Partial downloads are resume state — age-gate, never blanket-delete.
    func testRecentPartialIsPreservedAndOldOneRemoved() throws {
        let (paths, root) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default

        let fresh = paths.engineVersions.appendingPathComponent("download-fresh.partial")
        try Data("x".utf8).write(to: fresh)

        let stale = paths.engineVersions.appendingPathComponent("download-stale.partial")
        try Data("x".utf8).write(to: stale)
        let eightDaysAgo = Date().addingTimeInterval(-8 * 86_400)
        try fm.setAttributes([.modificationDate: eightDaysAgo], ofItemAtPath: stale.path)

        let report = SetupSweeper(paths: paths).sweep()
        XCTAssertTrue(fm.fileExists(atPath: fresh.path), "6-day-old partial must survive")
        XCTAssertFalse(fm.fileExists(atPath: stale.path), "8-day-old partial must go")
        XCTAssertEqual(report.partialsRemoved, 1)
    }

    func testInterruptedJournalIsReconciled() throws {
        let (paths, root) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var j = SetupJournal.fresh()
        j.beginAttempt(.preparePrefix)
        try j.save(to: paths.setupJournal)

        let report = SetupSweeper(paths: paths).sweep()
        XCTAssertTrue(report.journalReconciled)
        let back = try XCTUnwrap(SetupJournal.load(from: paths.setupJournal))
        XCTAssertEqual(back.outcome, .cancelled)
    }

    func testEmptyNWSDownloadDirIsRemoved() throws {
        let (paths, root) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: paths.nwsDownloadDirectory,
                                                withIntermediateDirectories: true)
        let report = SetupSweeper(paths: paths).sweep()
        XCTAssertTrue(report.nwsDownloadRemoved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.nwsDownloadDirectory.path))
    }

    func testSweepOnPristineTreeIsANoOp() throws {
        let (paths, root) = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let report = SetupSweeper(paths: paths).sweep()
        XCTAssertEqual(report.stagingRemoved, 0)
        XCTAssertEqual(report.partialsRemoved, 0)
        XCTAssertFalse(report.journalReconciled)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SetupSweeperTests`
Expected: FAIL — `cannot find 'SetupSweeper' in scope`

- [ ] **Step 3: Implement `SetupSweeper.swift`**

```swift
import Foundation

public struct SweepReport: Sendable, Equatable {
    public var stagingRemoved = 0
    public var partialsRemoved = 0
    public var nwsDownloadRemoved = false
    public var journalReconciled = false
    public var bytesReclaimed: Int64 = 0
}

/// Startup cleanup of artefacts a previous run leaked (spec §8.4).
///
/// This is the only defence against force-quit, which no handler can
/// intercept, so it must run before any UI decision.
public struct SetupSweeper: Sendable {

    /// Partial downloads are valuable resume state, so they are age-gated
    /// rather than blanket-deleted.
    public static let partialMaxAge: TimeInterval = 7 * 86_400

    private let paths: OpenXEPaths

    public init(paths: OpenXEPaths) { self.paths = paths }

    @discardableResult
    public func sweep(log: SetupLog? = nil) -> SweepReport {
        var report = SweepReport()
        let fm = FileManager.default

        let entries = (try? fm.contentsOfDirectory(
            at: paths.engineVersions,
            includingPropertiesForKeys: [.contentModificationDateKey, .totalFileAllocatedSizeKey]
        )) ?? []

        for entry in entries {
            let name = entry.lastPathComponent

            // Staging dirs: nothing legitimately holds one at startup.
            if name.hasPrefix("staging-") {
                report.bytesReclaimed += Self.size(of: entry)
                try? fm.removeItem(at: entry)
                report.stagingRemoved += 1
                log?.note("swept staging dir \(name)")
                continue
            }

            // Partials: only when clearly abandoned.
            if name.hasSuffix(".partial") {
                let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? Date.distantPast
                if Date().timeIntervalSince(modified) > Self.partialMaxAge {
                    report.bytesReclaimed += Self.size(of: entry)
                    try? fm.removeItem(at: entry)
                    report.partialsRemoved += 1
                    log?.note("swept stale partial \(name)")
                }
            }
        }

        // NWS download dir: transient, cleaned only on success today.
        let nws = paths.nwsDownloadDirectory
        if fm.fileExists(atPath: nws.path) {
            let contents = (try? fm.contentsOfDirectory(atPath: nws.path)) ?? []
            let hasResumable = contents.contains { $0.hasSuffix(".partial") }
            if !hasResumable {
                report.bytesReclaimed += Self.size(of: nws)
                try? fm.removeItem(at: nws)
                report.nwsDownloadRemoved = true
                log?.note("swept nws-download")
            }
        }

        // A journal still marked running means the last run was force-quit.
        if var journal = SetupJournal.load(from: paths.setupJournal), journal.outcome == .running {
            journal.reconcileInterruptedRun()
            try? journal.save(to: paths.setupJournal)
            report.journalReconciled = true
            log?.note("reconciled interrupted journal to cancelled")
        }

        // Orphaned wineserver. Exists already but is reachable only from
        // Runner.ensureWineserverWarm, so a wizard-only session never hits it.
        WineServerHousekeeping.sweepStaleServer(forPrefix: paths.prefix)

        return report
    }

    private static func size(of url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            total += Int64((try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?
                .totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter SetupSweeperTests`
Expected: PASS (5 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenXECore/SetupSweeper.swift Tests/OpenXECoreTests/SetupSweeperTests.swift
git commit -m "feat: add SetupSweeper for orphaned setup artefacts

Staging dirs (up to 666 MB) are leaked forever today. Partials are
age-gated because they are resume state."
```

---

### Task 13: Resumable NWS download

**Files:**
- Modify: `Sources/OpenXECore/NWSInstaller.swift:244-284` (`download(from:expectedSize:fileName:progress:)`), `:218` (use `paths.nwsDownloadDirectory`)
- Test: `Tests/OpenXECoreTests/NWSInstallerTests.swift` (append)

**Interfaces:**
- Consumes: `OpenXEPaths.nwsDownloadDirectory` (Task 1)
- Produces: `NWSInstaller.partialURL(for:) -> URL`; download resumes via HTTP Range

- [ ] **Step 1: Write the failing test**

```swift
    /// Spec §10.2: NWS re-downloaded all ~48 MB on every retry because the
    /// destination was deleted up front.
    func testPartialURLIsDerivedFromTheAssetName() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("openxe-nwspartial-\(UUID().uuidString)")
        let installer = NWSInstaller(paths: OpenXEPaths(root: root))
        let partial = installer.partialURL(for: "NWS-Desktop-Setup_8.2_1460.exe")
        XCTAssertEqual(partial.lastPathComponent, "NWS-Desktop-Setup_8.2_1460.exe.partial")
        XCTAssertEqual(partial.deletingLastPathComponent().lastPathComponent, "nws-download")
    }

    /// The same 200/206/416 handling already proven in EngineManager.download.
    func testResumeDispositionForEachStatusCode() {
        XCTAssertEqual(NWSInstaller.resumeDisposition(status: 206), .appendToPartial)
        XCTAssertEqual(NWSInstaller.resumeDisposition(status: 200), .replacePartial)
        XCTAssertEqual(NWSInstaller.resumeDisposition(status: 416), .partialAlreadyComplete)
        XCTAssertNil(NWSInstaller.resumeDisposition(status: 404))
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter NWSInstallerTests`
Expected: FAIL — `value of type 'NWSInstaller' has no member 'partialURL'`

- [ ] **Step 3: Add the resume disposition and partial path**

Add to `NWSInstaller`:

```swift
    /// How to treat the partial file given the server's response. Pure, so the
    /// three-way resume logic is unit-tested without the network. Mirrors the
    /// handling already proven in EngineManager.download.
    public enum ResumeDisposition: Sendable, Equatable {
        case appendToPartial          // 206: server honoured the range
        case replacePartial           // 200: full body (range ignored or fresh)
        case partialAlreadyComplete   // 416: nothing left to fetch
    }

    public static func resumeDisposition(status: Int) -> ResumeDisposition? {
        switch status {
        case 206: return .appendToPartial
        case 200: return .replacePartial
        case 416: return .partialAlreadyComplete
        default:  return nil
        }
    }

    public func partialURL(for fileName: String) -> URL {
        paths.nwsDownloadDirectory.appendingPathComponent(fileName + ".partial")
    }
```

Replace `downloadDirectory` (currently `:218`) with the shared accessor so the sweeper and installer agree:

```swift
    var downloadDirectory: URL { paths.nwsDownloadDirectory }
```

- [ ] **Step 4: Rewrite `download` to resume**

Replace the body of the private `download(from:expectedSize:fileName:progress:)` (currently `:244-284`):

```swift
    private func download(from url: URL, expectedSize: Int64, fileName: String,
                          progress: @escaping @Sendable (NWSProgress) -> Void) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)
        let destination = downloadDirectory.appendingPathComponent(fileName)
        let partial = partialURL(for: fileName)

        let have = ((try? fm.attributesOfItem(atPath: partial.path)[.size]) as? Int64) ?? 0

        var request = URLRequest(url: url)
        request.setValue("OpenXE", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 600
        if have > 0 { request.setValue("bytes=\(have)-", forHTTPHeaderField: "Range") }

        let delegate = NWSDownloadDelegate(alreadyHave: have, progress: progress)
        let tempURL: URL, response: URLResponse
        do {
            (tempURL, response) = try await URLSession.shared.download(for: request, delegate: delegate)
        } catch {
            throw NWSError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse,
              let disposition = Self.resumeDisposition(status: http.statusCode) else {
            throw NWSError.network("download HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }

        switch disposition {
        case .appendToPartial:
            let dst = try FileHandle(forWritingTo: partial)
            defer { try? dst.close() }
            try dst.seekToEnd()
            let src = try FileHandle(forReadingFrom: tempURL)
            defer { try? src.close() }
            while let chunk = try src.read(upToCount: 1 << 20), !chunk.isEmpty {
                try dst.write(contentsOf: chunk)
            }
            try? fm.removeItem(at: tempURL)
        case .replacePartial:
            try? fm.removeItem(at: partial)
            try fm.moveItem(at: tempURL, to: partial)
        case .partialAlreadyComplete:
            try? fm.removeItem(at: tempURL)
        }

        // Size check against the partial, then promote to the final name.
        let actual = ((try? fm.attributesOfItem(atPath: partial.path)[.size]) as? Int64) ?? 0
        if expectedSize > 0 {
            guard actual == expectedSize else {
                try? fm.removeItem(at: partial)   // poisoned; a retry starts clean
                throw NWSError.sizeMismatch(expected: expectedSize, actual: actual)
            }
        } else {
            guard actual > 1_000_000 else {
                try? fm.removeItem(at: partial)
                throw NWSError.sizeMismatch(expected: 0, actual: actual)
            }
        }
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: partial, to: destination)
        return destination
    }
```

Update `NWSDownloadDelegate` (currently `:367-379`) to account for bytes already on disk:

```swift
private final class NWSDownloadDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let alreadyHave: Int64
    private let progress: @Sendable (NWSProgress) -> Void

    init(alreadyHave: Int64, progress: @escaping @Sendable (NWSProgress) -> Void) {
        self.alreadyHave = alreadyHave
        self.progress = progress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else {
            progress(.downloading(fraction: -1)); return
        }
        let done = Double(alreadyHave + totalBytesWritten)
        let total = Double(alreadyHave + totalBytesExpectedToWrite)
        progress(.downloading(fraction: done / total))
    }
}
```

- [ ] **Step 5: Run tests**

Run: `swift test --filter NWSInstallerTests && swift build`
Expected: PASS, build succeeds

- [ ] **Step 6: Commit**

```bash
git add Sources/OpenXECore/NWSInstaller.swift Tests/OpenXECoreTests/NWSInstallerTests.swift
git commit -m "feat: resume NWS downloads via HTTP Range

Reuses the 200/206/416 handling already proven in EngineManager."
```

---

### Task 14: SetupCoordinator

Assembles everything. **The injectable `StageRunner` seam introduced in Step 1 is what Task 15 and all retry/stall/cancel tests depend on.**

**Files:**
- Create: `Sources/OpenXECore/SetupCoordinator.swift`
- Test: `Tests/OpenXECoreTests/SetupCoordinatorTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 1–13
- Produces: `StageRunner` protocol, `SetupCoordinator(paths:stages:runner:log:)`, `.run() async`, `.cancel()`, `.events: AsyncStream<SetupEvent>`, `.resumeDecision(for:) -> ResumeDecision`

- [ ] **Step 1: Write the failing test (defines the seam)**

```swift
import XCTest
@testable import OpenXECore

/// A fake stage runner. This seam is what makes retry, stall, cancel and
/// resume testable without the network or Wine.
final class FakeStageRunner: StageRunner, @unchecked Sendable {
    var behaviours: [SetupStage.ID: () throws -> Void] = [:]
    var alreadyDone: Set<SetupStage.ID> = []
    private(set) var executed: [SetupStage.ID] = []
    private let lock = NSLock()

    func isAlreadySatisfied(_ stage: SetupStage.ID, journal: SetupJournal) -> Bool {
        alreadyDone.contains(stage)
    }

    func run(_ stage: SetupStage.ID, journal: inout SetupJournal,
             progress: @Sendable (Double?, String) -> Void) throws {
        lock.lock(); executed.append(stage); lock.unlock()
        try behaviours[stage]?()
    }
}

final class SetupCoordinatorTests: XCTestCase {

    private func makePaths() -> OpenXEPaths {
        OpenXEPaths(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("openxe-coord-\(UUID().uuidString)"))
    }

    private func drain(_ coordinator: SetupCoordinator) async -> [SetupEvent] {
        var events: [SetupEvent] = []
        for await e in coordinator.events { events.append(e) }
        return events
    }

    func testHappyPathRunsEveryStageInOrderAndFinishes() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let runner = FakeStageRunner()
        let c = SetupCoordinator(paths: paths, stages: SetupCatalog.all, runner: runner)

        async let collected = drain(c)
        await c.run()
        let events = await collected

        XCTAssertEqual(runner.executed, SetupCatalog.all.map(\.id))
        guard case .finished = events.last else {
            return XCTFail("expected .finished, got \(String(describing: events.last))")
        }
    }

    func testOverallFractionIsMonotonicAndReaches1() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let c = SetupCoordinator(paths: paths, stages: SetupCatalog.all,
                                 runner: FakeStageRunner())
        async let collected = drain(c)
        await c.run()
        let fractions: [Double] = (await collected).compactMap {
            if case .overall(let f, _, _) = $0 { return f } else { return nil }
        }
        XCTAssertFalse(fractions.isEmpty)
        XCTAssertEqual(zip(fractions, fractions.dropFirst()).filter { $0 > $1 }.count, 0,
                       "overall fraction must never run backwards")
        XCTAssertEqual(fractions.last ?? 0, 1.0, accuracy: 0.001)
    }

    /// Spec §9.2: network retries are visible, never silent.
    func testNetworkStageRetriesAndEmitsVisibleAttempts() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let runner = FakeStageRunner()
        var calls = 0
        runner.behaviours[.downloadEngine] = {
            calls += 1
            if calls < 3 { throw NWSError.network("simulated drop") }
        }
        let c = SetupCoordinator(paths: paths, stages: SetupCatalog.all, runner: runner,
                                 retryDelayScale: 0)   // no real sleeping in tests
        async let collected = drain(c)
        await c.run()
        let events = await collected

        XCTAssertEqual(calls, 3, "3 attempts per RetryPolicy.network")
        let attempts = events.filter { if case .attempt = $0 { return true } else { return false } }
        XCTAssertEqual(attempts.count, 2, "attempts 2 and 3 must be reported to the user")
    }

    func testExhaustedRetriesProduceAFailureAndStop() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let runner = FakeStageRunner()
        runner.behaviours[.downloadEngine] = { throw NWSError.network("always down") }
        let c = SetupCoordinator(paths: paths, stages: SetupCatalog.all, runner: runner,
                                 retryDelayScale: 0)
        async let collected = drain(c)
        await c.run()
        let events = await collected

        guard case .failed(let failure) = events.last else {
            return XCTFail("expected .failed, got \(String(describing: events.last))")
        }
        XCTAssertEqual(failure.kind, .network)
        XCTAssertEqual(failure.stage, .downloadEngine)
        XCTAssertFalse(runner.executed.contains(.unpackEngine),
                       "must not continue past a failed stage")
    }

    /// Spec §6.3: satisfied stages are skipped on resume.
    func testSatisfiedStagesAreSkipped() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let runner = FakeStageRunner()
        runner.alreadyDone = [.preflight, .downloadEngine, .unpackEngine]
        let c = SetupCoordinator(paths: paths, stages: SetupCatalog.all, runner: runner)
        async let collected = drain(c)
        await c.run()
        _ = await collected

        XCTAssertEqual(runner.executed, [.preparePrefix, .downloadNWS, .installNWS])
    }

    func testJournalRecordsOutcomeAndSurvivesTheRun() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let c = SetupCoordinator(paths: paths, stages: SetupCatalog.all,
                                 runner: FakeStageRunner())
        async let collected = drain(c)
        await c.run()
        _ = await collected

        let j = try XCTUnwrap(SetupJournal.load(from: paths.setupJournal))
        XCTAssertEqual(j.outcome, .succeeded)
        XCTAssertEqual(j.stages[.installNWS]?.state, .completed)
    }

    /// Spec §7.3 Rule B: an estimate already proven wrong is withdrawn, not
    /// counted down. This is what makes the warm-machine defaults shippable.
    func testEstimateIsWithdrawnWhenTheStageOvershoots() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let runner = FakeStageRunner()
        // Stage 1 completes fast, seeding recalibration; stage 2 then runs far
        // longer than its weight predicts.
        runner.behaviours[.downloadEngine] = { Thread.sleep(forTimeInterval: 1.2) }
        let c = SetupCoordinator(paths: paths, stages: Array(SetupCatalog.all.prefix(2)),
                                 runner: runner)
        async let collected = drain(c)
        await c.run()
        let events = await collected

        let estimates: [TimeInterval?] = events.compactMap {
            if case .overall(_, _, let r) = $0 { return r } else { return nil }
        }
        XCTAssertTrue(estimates.contains { $0 == nil },
                      "an overshooting stage must withdraw the numeric estimate")
    }

    func testCancelStopsTheRunAndMarksTheJournal() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let runner = FakeStageRunner()
        let c = SetupCoordinator(paths: paths, stages: SetupCatalog.all, runner: runner)
        runner.behaviours[.downloadEngine] = { c.cancel() }

        async let collected = drain(c)
        await c.run()
        let events = await collected

        guard case .cancelled = events.last else {
            return XCTFail("expected .cancelled, got \(String(describing: events.last))")
        }
        XCTAssertFalse(runner.executed.contains(.preparePrefix))
        let j = try XCTUnwrap(SetupJournal.load(from: paths.setupJournal))
        XCTAssertEqual(j.outcome, .cancelled)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SetupCoordinatorTests`
Expected: FAIL — `cannot find 'StageRunner' in scope`

- [ ] **Step 3: Implement `SetupCoordinator.swift`**

```swift
import Foundation

/// Executes one stage's real work. The seam that makes the coordinator's
/// retry / stall / cancel / resume logic testable without network or Wine.
public protocol StageRunner: Sendable {
    /// Ground truth: is this stage already satisfied on disk? The journal is
    /// advisory only (spec §6.2) and must never override this.
    func isAlreadySatisfied(_ stage: SetupStage.ID, journal: SetupJournal) -> Bool

    func run(_ stage: SetupStage.ID, journal: inout SetupJournal,
             progress: @Sendable (Double?, String) -> Void) throws
}

/// Owns first-run setup end to end (spec §4). The only object deciding what
/// runs, in what order, and what happens on failure.
public final class SetupCoordinator: @unchecked Sendable {

    private let paths: OpenXEPaths
    private let stages: [SetupStage]
    private let weights: [Int]
    private let runner: StageRunner
    private let log: SetupLog?
    private let registry: ChildRegistry
    private let retryDelayScale: Double

    private var journal: SetupJournal
    private var cancelled = false
    private let lock = NSLock()
    private let continuation: AsyncStream<SetupEvent>.Continuation
    public let events: AsyncStream<SetupEvent>

    private var startTime = Date()
    private var currentStageIndex: Int?
    private var currentStageStart = Date()
    private var completedWeight = 0
    private var secondsPerWeightUnit: Double = 241.0 / 100.0   // spec §7.3
    private var observedSeconds: Double = 0
    private var observedWeight = 0

    public init(paths: OpenXEPaths,
                stages: [SetupStage],
                runner: StageRunner,
                log: SetupLog? = nil,
                registry: ChildRegistry = ChildRegistry(),
                retryDelayScale: Double = 1.0) {
        self.paths = paths
        self.stages = stages
        self.weights = SetupCatalog.renormalisedWeights(for: stages)
        self.runner = runner
        self.log = log
        self.registry = registry
        self.retryDelayScale = retryDelayScale
        self.journal = SetupJournal.load(from: paths.setupJournal) ?? SetupJournal.fresh()

        var cont: AsyncStream<SetupEvent>.Continuation!
        events = AsyncStream { cont = $0 }
        continuation = cont
    }

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    /// Spec §8.3. Killing the children is what unblocks a stage sitting in
    /// Subprocess.run's semaphore wait — the flag alone cannot.
    public func cancel() {
        lock.lock()
        guard !cancelled else { lock.unlock(); return }
        cancelled = true
        lock.unlock()
        log?.note("cancel requested")
        registry.terminateAll()
    }

    public func run() async {
        startTime = Date()
        journal.outcome = .running
        persist()

        for (index, stage) in stages.enumerated() {
            if isCancelled { return finishCancelled(stage.id) }

            if runner.isAlreadySatisfied(stage.id, journal: journal) {
                log?.note("stage \(stage.id.rawValue): already satisfied, skipping")
                journal.record(stage.id, as: .completed)
                completedWeight += weights[index]
                emitOverall()
                continue
            }

            emit(.stageBegan(stage.id, index: index + 1, of: stages.count))
            let stageStart = Date()
            currentStageIndex = index
            currentStageStart = stageStart

            do {
                try await execute(stage, index: index)
            } catch let failure as SetupFailure {
                if isCancelled { return finishCancelled(stage.id) }
                journal.record(stage.id, as: .failed,
                               error: JournalError(kind: failure.kind.rawValue,
                                                   detail: failure.technicalDetail))
                journal.outcome = .failed
                persist()
                log?.note("stage \(stage.id.rawValue) FAILED: \(failure.technicalDetail)")
                emit(.failed(failure))
                continuation.finish()
                return
            } catch {
                emit(.failed(Self.wrap(error, stage: stage.id)))
                continuation.finish()
                return
            }

            let elapsed = Date().timeIntervalSince(stageStart)
            journal.record(stage.id, as: .completed, elapsed: elapsed)
            persist()
            log?.endStage(stage.id, elapsed: elapsed)

            completedWeight += weights[index]
            currentStageIndex = nil
            recalibrate(weight: weights[index], elapsed: elapsed)
            emit(.stageCompleted(stage.id, elapsed: elapsed))
            emitOverall()
        }

        journal.outcome = .succeeded
        persist()
        emit(.finished)
        continuation.finish()
    }

    private func execute(_ stage: SetupStage, index: Int) async throws {
        let policy = stage.retry
        var attempt = 0

        while true {
            attempt += 1
            if attempt > 1 {
                let delay = policy.delay(beforeAttempt: attempt) * retryDelayScale
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
                if isCancelled { throw SetupFailure(stage: stage.id, kind: .internalError,
                                                    userMessage: "", suggestedAction: "",
                                                    technicalDetail: "cancelled",
                                                    isRetryable: false) }
            }

            journal.beginAttempt(stage.id)
            persist()
            log?.beginStage(stage.id, attempt: attempt)

            do {
                var j = journal
                try runner.run(stage.id, journal: &j) { [weak self] fraction, detail in
                    guard let self else { return }
                    self.emit(.stageProgress(stage.id, fraction: fraction, detail: detail))
                    self.emitOverall(stageIndex: index, stageFraction: fraction)
                }
                journal = j
                return
            } catch {
                let failure = Self.wrap(error, stage: stage.id)
                guard attempt < policy.maxAttempts, failure.isRetryable, !isCancelled else {
                    throw failure
                }
                log?.note("stage \(stage.id.rawValue) attempt \(attempt) failed: "
                          + failure.technicalDetail)
                emit(.attempt(stage.id, number: attempt + 1, of: policy.maxAttempts,
                              reason: failure.userMessage))
            }
        }
    }

    // MARK: progress

    private func emitOverall(stageIndex: Int? = nil, stageFraction: Double? = nil) {
        var done = Double(completedWeight)
        if let stageIndex, let f = stageFraction {
            done += Double(weights[stageIndex]) * min(max(f, 0), 1)
        }
        let fraction = min(done / 100.0, 1.0)
        let elapsed = Date().timeIntervalSince(startTime)
        emit(.overall(fraction: fraction, elapsed: elapsed, remaining: remaining(done: done)))
    }

    /// Spec §7.3. Two suppression rules, both returning nil rather than a
    /// number we cannot stand behind.
    ///
    /// Rule A — no estimate before any data exists. An early estimate computed
    /// from nothing is worse than none.
    ///
    /// Rule B — no estimate once the in-flight stage has overshot its
    /// expectation by 1.5x. Every reference figure came from a warm Apple
    /// Silicon Mac, so on slower hardware the initial estimate reads
    /// optimistic; Rule B withdraws it instead of counting down to a number
    /// this machine cannot meet. This is what makes the warm defaults safe to
    /// ship without cold calibration.
    private func remaining(done: Double) -> TimeInterval? {
        guard observedWeight > 0 else { return nil }              // Rule A
        if let stageIndex = currentStageIndex {
            let expected = Double(weights[stageIndex]) * secondsPerWeightUnit
            let elapsed = Date().timeIntervalSince(currentStageStart)
            if expected > 0, elapsed > expected * Self.overshootFactor { return nil }  // Rule B
        }
        let left = max(0, 100.0 - done)
        return left * secondsPerWeightUnit
    }

    /// How far a stage may exceed its expected duration before the estimate is
    /// withdrawn. Named, not inline — it is a calibration output (spec §13.4).
    static let overshootFactor = 1.5

    private func recalibrate(weight: Int, elapsed: TimeInterval) {
        guard weight > 0 else { return }
        observedSeconds += elapsed
        observedWeight += weight
        secondsPerWeightUnit = observedSeconds / Double(observedWeight)
    }

    // MARK: helpers

    private func finishCancelled(_ stage: SetupStage.ID) {
        journal.record(stage, as: .cancelled)
        journal.outcome = .cancelled
        persist()
        log?.note("run cancelled at stage \(stage.rawValue)")
        emit(.cancelled(stage))
        continuation.finish()
    }

    private func emit(_ event: SetupEvent) { continuation.yield(event) }

    private func persist() { try? journal.save(to: paths.setupJournal) }

    /// Maps component errors onto the user-facing taxonomy (spec §9.1).
    /// Deliberately exhaustive per error type: adding a case to any component
    /// error should surface here rather than silently becoming internalError.
    static func wrap(_ error: Error, stage: SetupStage.ID) -> SetupFailure {
        if let f = error as? SetupFailure { return f }

        if let e = error as? NWSError {
            switch e {
            case .network:
                return SetupFailure(stage: stage, kind: .network,
                    userMessage: "OpenXE couldn't reach the download server.",
                    suggestedAction: "Check your internet connection, then try again. "
                        + "Anything already downloaded has been saved.",
                    technicalDetail: e.errorDescription ?? "", isRetryable: true)
            case .rateLimited:
                return SetupFailure(stage: stage, kind: .rateLimited,
                    userMessage: "GitHub is temporarily limiting downloads from this network.",
                    suggestedAction: "OpenXE will try the vendor's own download link.",
                    technicalDetail: e.errorDescription ?? "", isRetryable: true)
            case .sizeMismatch:
                return SetupFailure(stage: stage, kind: .integrity,
                    userMessage: "The download didn't arrive intact.",
                    suggestedAction: "OpenXE will try again.",
                    technicalDetail: e.errorDescription ?? "", isRetryable: true)
            case .noAsset, .parseFailed:
                return SetupFailure(stage: stage, kind: .network,
                    userMessage: "OpenXE couldn't read the release information.",
                    suggestedAction: "Try again in a moment.",
                    technicalDetail: e.errorDescription ?? "", isRetryable: true)
            case .installFailed:
                return SetupFailure(stage: stage, kind: .subprocessFailed,
                    userMessage: "The New World Scheduler installer didn't finish.",
                    suggestedAction: "Try again. If it keeps failing, send us the log.",
                    technicalDetail: e.errorDescription ?? "", isRetryable: true)
            }
        }

        if let e = error as? EngineError {
            switch e {
            case .downloadFailed:
                return SetupFailure(stage: stage, kind: .network,
                    userMessage: "OpenXE couldn't finish downloading the Windows environment.",
                    suggestedAction: "Check your connection, then try again.",
                    technicalDetail: e.errorDescription ?? "", isRetryable: true)
            case .checksumMismatch:
                return SetupFailure(stage: stage, kind: .integrity,
                    userMessage: "The Windows environment download didn't arrive intact.",
                    suggestedAction: "OpenXE will download it again.",
                    technicalDetail: e.errorDescription ?? "", isRetryable: true)
            case .layoutUnexpected, .notInstalled:
                return SetupFailure(stage: stage, kind: .subprocessFailed,
                    userMessage: "OpenXE couldn't unpack the Windows environment.",
                    suggestedAction: "Try again. If it keeps failing, send us the log.",
                    technicalDetail: e.errorDescription ?? "", isRetryable: true)
            }
        }

        if let e = error as? PrefixError {
            switch e {
            case .bootFailed:
                return SetupFailure(stage: stage, kind: .subprocessFailed,
                    userMessage: "The Windows environment couldn't finish setting up.",
                    suggestedAction: "Try again — OpenXE will rebuild it from scratch.",
                    technicalDetail: e.errorDescription ?? "", isRetryable: true)
            case .monoOrGeckoMissing:
                return SetupFailure(stage: stage, kind: .environmentIncomplete,
                    userMessage: "Some Windows support files are missing.",
                    suggestedAction: "Try again — OpenXE will rebuild the environment.",
                    technicalDetail: e.errorDescription ?? "", isRetryable: true)
            }
        }

        if let e = error as? SubprocessError {
            return SetupFailure(stage: stage, kind: .timedOut,
                userMessage: "That step took too long and was stopped.",
                suggestedAction: "Try again.",
                technicalDetail: e.errorDescription ?? "", isRetryable: true)
        }

        return SetupFailure(stage: stage, kind: .internalError,
            userMessage: "Something went wrong during setup.",
            suggestedAction: "Try again. If it keeps failing, send us the log.",
            technicalDetail: String(describing: error), isRetryable: true)
    }
}
```

- [ ] **Step 4: Run tests**

Run: `swift test --filter SetupCoordinatorTests`
Expected: PASS (7 tests)

- [ ] **Step 5: Run the full suite**

Run: `swift test && swift build`
Expected: all green

- [ ] **Step 6: Commit**

```bash
git add Sources/OpenXECore/SetupCoordinator.swift Tests/OpenXECoreTests/SetupCoordinatorTests.swift
git commit -m "feat: add SetupCoordinator

Owns setup end to end: stage ordering, visible retries, resume from
ground truth, cancel that kills children, and one event stream. The
StageRunner protocol is the seam that makes all of it testable."
```

---

### Task 15: Production stage runner and the fault-injection matrix

**Depends on the Task 14 seam.** Wires the real components in behind `StageRunner` and proves each failure mode from spec §13.2.

**Files:**
- Create: `Sources/OpenXECore/ProductionStageRunner.swift`
- Test: `Tests/OpenXECoreTests/SetupFaultInjectionTests.swift`

**Interfaces:**
- Consumes: `StageRunner` (Task 14), `EngineManager`, `PrefixManager`, `NWSInstaller`, `SetupPreflight`
- Produces: `ProductionStageRunner(paths:log:registry:selectedRelease:)`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import OpenXECore

final class SetupFaultInjectionTests: XCTestCase {

    private func makePaths() -> OpenXEPaths {
        OpenXEPaths(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("openxe-fault-\(UUID().uuidString)"))
    }

    /// Spec §6.3: ground truth wins over a journal that disagrees. This is the
    /// load-bearing rule of the whole resume design.
    func testGroundTruthOverridesAJournalClaimingCompletion() throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        var journal = SetupJournal.fresh()
        journal.record(.preparePrefix, as: .completed, elapsed: 59)

        let runner = ProductionStageRunner(paths: paths, log: nil, registry: ChildRegistry())
        // Nothing is installed on disk, so the stage is NOT satisfied.
        XCTAssertFalse(runner.isAlreadySatisfied(.preparePrefix, journal: journal),
                       "journal must not override the filesystem")
        XCTAssertFalse(runner.isAlreadySatisfied(.downloadEngine, journal: journal))
    }

    func testDiskSpaceFailureSurfacesAsPreflightFailure() {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let preflight = SetupPreflight(paths: paths)
        XCTAssertThrowsError(try preflight.check(freeBytesOverride: 100, rosettaOverride: true)) {
            XCTAssertEqual(($0 as? SetupFailure)?.kind, .diskSpace)
        }
    }

    func testEveryComponentErrorMapsToANonEmptyUserMessage() {
        let cases: [Error] = [
            NWSError.network("x"), NWSError.rateLimited, NWSError.noAsset("8.2"),
            NWSError.parseFailed("x"), NWSError.sizeMismatch(expected: 1, actual: 2),
            NWSError.installFailed(status: 1, detail: "x"),
            EngineError.downloadFailed("x"),
            EngineError.checksumMismatch(expected: "a", actual: "b"),
            EngineError.layoutUnexpected("x"), EngineError.notInstalled("x"),
            PrefixError.bootFailed(status: 1, detail: "x"),
            PrefixError.monoOrGeckoMissing("x"),
            SubprocessError.timedOut(command: "wineboot", seconds: 900),
        ]
        for error in cases {
            let f = SetupCoordinator.wrap(error, stage: .preparePrefix)
            XCTAssertFalse(f.userMessage.isEmpty, "empty message for \(error)")
            XCTAssertFalse(f.suggestedAction.isEmpty, "empty action for \(error)")
            XCTAssertNotEqual(f.kind, .internalError,
                              "\(error) fell through to internalError")
        }
    }

    func testCancelDuringAStageLeavesNoLiveChildren() async throws {
        let paths = makePaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let registry = ChildRegistry()

        // A stage that spawns a long-lived child, then gets cancelled.
        final class SleepRunner: StageRunner, @unchecked Sendable {
            let registry: ChildRegistry
            init(registry: ChildRegistry) { self.registry = registry }
            func isAlreadySatisfied(_ s: SetupStage.ID, journal: SetupJournal) -> Bool { false }
            func run(_ s: SetupStage.ID, journal: inout SetupJournal,
                     progress: @Sendable (Double?, String) -> Void) throws {
                _ = try Subprocess.run(URL(fileURLWithPath: "/bin/sleep"),
                                       arguments: ["20"], timeout: 60, registry: registry)
            }
        }

        let c = SetupCoordinator(paths: paths, stages: [SetupCatalog.all[0]],
                                 runner: SleepRunner(registry: registry), registry: registry)
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            c.cancel()
        }
        var events: [SetupEvent] = []
        async let collected: Void = { for await e in c.events { events.append(e) } }()
        await c.run()
        await collected

        XCTAssertEqual(registry.liveCount, 0, "cancel must leave no orphaned children")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SetupFaultInjectionTests`
Expected: FAIL — `cannot find 'ProductionStageRunner' in scope`

- [ ] **Step 3: Implement `ProductionStageRunner.swift`**

```swift
import Foundation

/// The real `StageRunner`: wires EngineManager, PrefixManager and NWSInstaller
/// behind the coordinator's seam. Holds no policy — ordering, retry and cancel
/// all live in SetupCoordinator.
public final class ProductionStageRunner: StageRunner, @unchecked Sendable {

    private let paths: OpenXEPaths
    private let log: SetupLog?
    private let registry: ChildRegistry
    private let engine: EngineManager
    private let prefix: PrefixManager
    private let nws: NWSInstaller

    /// Chosen in the wizard's version step; nil means use the vendor fallback.
    public var selectedRelease: NWSInstaller.Release?

    public init(paths: OpenXEPaths, log: SetupLog?, registry: ChildRegistry,
                selectedRelease: NWSInstaller.Release? = nil) {
        self.paths = paths
        self.log = log
        self.registry = registry
        self.selectedRelease = selectedRelease
        self.engine = EngineManager(paths: paths)
        self.prefix = PrefixManager(paths: paths)
        self.nws = NWSInstaller(paths: paths)
    }

    /// GROUND TRUTH ONLY (spec §6.2, §6.3). The journal is passed in for
    /// context but must never be the reason a stage is skipped.
    public func isAlreadySatisfied(_ stage: SetupStage.ID, journal: SetupJournal) -> Bool {
        switch stage {
        case .preflight:
            return false                       // always cheap, always re-run
        case .downloadEngine, .unpackEngine:
            return engine.isActiveInstalled
        case .preparePrefix:
            return engine.isActiveInstalled && prefix.isReady
        case .downloadNWS, .installNWS:
            return nws.isInstalled
        }
    }

    public func run(_ stage: SetupStage.ID, journal: inout SetupJournal,
                    progress: @Sendable (Double?, String) -> Void) throws {
        switch stage {
        case .preflight:
            progress(nil, "Checking your Mac…")
            try SetupPreflight(paths: paths).check()

        case .downloadEngine:
            progress(0, "Downloading the Windows environment…")
            journal.engineID = EngineCatalog.default.id
            journal.engineSHA256 = EngineCatalog.default.sha256
            try runBlocking {
                try await self.engine.ensureDefaultActive { event in
                    switch event {
                    case .downloading(let f) where f >= 0:
                        progress(f, "Downloading the Windows environment… \(Int(f * 100))%")
                    case .downloading:
                        progress(nil, "Downloading the Windows environment…")
                    case .verifying:
                        progress(nil, "Checking the download…")
                    case .extracting:
                        progress(nil, "Unpacking the Windows environment…")
                    }
                }
            }
            journal.archiveVerified = true

        case .unpackEngine:
            // ensureDefaultActive covers download+unpack in one call; if the
            // engine is already active this is a no-op skip above.
            progress(nil, "Unpacking the Windows environment…")

        case .preparePrefix:
            try prefix.ensurePrefix(log: log) { p in
                guard case .step(let sub, let inner, let detail) = p else { return }
                progress(PrefixProgress.fraction(at: sub, within: inner), detail)
            }

        case .downloadNWS:
            progress(0, "Downloading New World Scheduler…")
            let release = selectedRelease
            try runBlocking {
                let installer: URL
                if let release {
                    installer = try await self.nws.download(release) { p in
                        Self.report(p, progress) }
                } else {
                    installer = try await self.nws.downloadViaFallback { p in
                        Self.report(p, progress) }
                }
                self.pendingInstaller = installer
            }

        case .installNWS:
            guard let installer = pendingInstaller ?? Self.existingInstaller(in: paths) else {
                throw NWSError.installFailed(status: -1, detail: "no downloaded installer found")
            }
            progress(nil, "Installing New World Scheduler…")
            try runBlocking {
                try await self.nws.install(installerAt: installer) { p in
                    Self.report(p, progress) }
            }
            nws.cleanupDownloads()
        }
    }

    private var pendingInstaller: URL?

    private static func existingInstaller(in paths: OpenXEPaths) -> URL? {
        let dir = paths.nwsDownloadDirectory
        let files = (try? FileManager.default.contentsOfDirectory(at: dir,
                                                                  includingPropertiesForKeys: nil)) ?? []
        return files.first { $0.pathExtension.lowercased() == "exe" }
    }

    private static func report(_ p: NWSProgress, _ progress: @Sendable (Double?, String) -> Void) {
        switch p {
        case .downloading(let f) where f >= 0:
            progress(f, "Downloading New World Scheduler… \(Int(f * 100))%")
        case .downloading:
            progress(nil, "Downloading New World Scheduler…")
        case .installing:
            progress(nil, "Installing New World Scheduler…")
        case .verifying:
            progress(nil, "Finishing installation…")
        }
    }

    /// Bridges the async component APIs into the synchronous StageRunner
    /// contract. The coordinator already runs stages off the main actor.
    private func runBlocking(_ body: @escaping @Sendable () async throws -> Void) throws {
        let semaphore = DispatchSemaphore(value: 0)
        var thrown: Error?
        Task.detached(priority: .userInitiated) {
            do { try await body() } catch { thrown = error }
            semaphore.signal()
        }
        semaphore.wait()
        if let thrown { throw thrown }
    }
}
```

> **Settled (decision 1).** `ensureDefaultActive` performs download *and* unpack in one call, so stages 2 and 3 do not report separately. They stay merged: splitting `EngineManager.install` into `fetchArchive` / `installArchive` would buy separate reporting for a ~2 s verify step while touching proven download and checksum code. Stage 3 reports the unpack phase through stage 2's progress callback, and the unpack file counter (Task 7) still gives it a determinate bar of its own.

- [ ] **Step 4: Run tests**

Run: `swift test --filter SetupFaultInjectionTests`
Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenXECore/ProductionStageRunner.swift \
        Tests/OpenXECoreTests/SetupFaultInjectionTests.swift
git commit -m "feat: add ProductionStageRunner and fault-injection tests

Ground truth always wins over the journal; every component error maps to
a non-empty user message; cancel leaves no live children."
```

---

### Task 16: Setup panel UI

**Files:**
- Create: `Sources/OpenXE/SetupPanelView.swift`
- Test: manual (AppKit view; `OpenXECore` tests cannot import AppKit)

**Interfaces:**
- Consumes: `SetupEvent`, `SetupFailure`, `SetupLog` (Tasks 2–3)
- Produces: `SetupPanelView`, `.apply(_ event: SetupEvent)`, `.showFailure(_:)`, `.onCancel`, `.onKeepWaiting`, `.onRetry`, `.onShowLog`

- [ ] **Step 1: Implement `SetupPanelView.swift`**

```swift
import AppKit
import OpenXECore

/// The calm setup panel (spec §7.1): one determinate bar, a plain-English
/// step line, elapsed + remaining, and a disclosure triangle over the
/// technical detail. Renders SetupEvent; holds no orchestration.
@MainActor
final class SetupPanelView: NSStackView {

    var onCancel: (() -> Void)?
    var onKeepWaiting: (() -> Void)?
    var onRetry: (() -> Void)?
    var onShowLog: (() -> Void)?

    private let stepLabel = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let timingLabel = NSTextField(labelWithString: "")
    private let disclosure = NSButton()
    private let technicalLabel = NSTextField(wrappingLabelWithString: "")
    private let showLogButton = NSButton()
    private let cancelButton = NSButton()
    private let keepWaitingButton = NSButton()
    private let retryButton = NSButton()

    private var detailsExpanded: Bool {
        get { UserDefaults.standard.bool(forKey: "OpenXESetupDetailsExpanded") }
        set { UserDefaults.standard.set(newValue, forKey: "OpenXESetupDetailsExpanded") }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        orientation = .vertical
        alignment = .leading
        spacing = 10

        stepLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)

        bar.style = .bar
        bar.minValue = 0
        bar.maxValue = 1
        bar.isIndeterminate = false

        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.textColor = .secondaryLabelColor

        timingLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        timingLabel.textColor = .secondaryLabelColor

        disclosure.setButtonType(.onOff)
        disclosure.bezelStyle = .disclosure
        disclosure.title = ""
        disclosure.target = self
        disclosure.action = #selector(toggleDetails)
        disclosure.state = detailsExpanded ? .on : .off

        technicalLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        technicalLabel.textColor = .tertiaryLabelColor
        technicalLabel.isHidden = !detailsExpanded

        showLogButton.title = "Show Log"
        showLogButton.bezelStyle = .rounded
        showLogButton.target = self
        showLogButton.action = #selector(showLogTapped)
        showLogButton.isHidden = !detailsExpanded

        cancelButton.title = "Cancel"
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)

        keepWaitingButton.title = "Keep Waiting"
        keepWaitingButton.bezelStyle = .rounded
        keepWaitingButton.target = self
        keepWaitingButton.action = #selector(keepWaitingTapped)
        keepWaitingButton.isHidden = true

        retryButton.title = "Try Again"
        retryButton.bezelStyle = .rounded
        retryButton.keyEquivalent = "\r"
        retryButton.target = self
        retryButton.action = #selector(retryTapped)
        retryButton.isHidden = true

        let detailsRow = NSStackView(views: [disclosure,
                                             NSTextField(labelWithString: "Details"),
                                             NSView()])
        detailsRow.orientation = .horizontal
        detailsRow.spacing = 4

        let buttonRow = NSStackView(views: [NSView(), showLogButton, cancelButton,
                                            keepWaitingButton, retryButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        for v in [stepLabel, bar, detailLabel, timingLabel, detailsRow,
                  technicalLabel, buttonRow] {
            addArrangedSubview(v)
        }
        for v in [stepLabel, bar, detailLabel, timingLabel, technicalLabel, buttonRow] {
            v.widthAnchor.constraint(equalToConstant: 492).isActive = true
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: rendering

    func apply(_ event: SetupEvent) {
        switch event {
        case .stageBegan(_, let index, let total):
            setStalled(false)
            stepLabel.stringValue = "Step \(index) of \(total) — "
                + (SetupCatalog.all.first { $0.id == currentID(index) }?.displayName ?? "")

        case .stageProgress(_, _, let detail):
            detailLabel.stringValue = detail

        case .overall(let fraction, let elapsed, let remaining):
            bar.isIndeterminate = false
            bar.doubleValue = fraction
            timingLabel.stringValue = Self.timing(elapsed: elapsed, remaining: remaining)

        case .attempt(_, let number, let total, let reason):
            detailLabel.stringValue = "\(reason) — trying again (\(number) of \(total))…"

        case .stalled:
            setStalled(true)

        case .recovered:
            setStalled(false)

        case .failed(let failure):
            showFailure(failure)

        case .stageCompleted, .cancelled, .finished:
            break
        }
    }

    private func currentID(_ index: Int) -> SetupStage.ID? {
        let all = SetupCatalog.all
        return index >= 1 && index <= all.count ? all[index - 1].id : nil
    }

    func showTechnical(_ line: String) {
        technicalLabel.stringValue = line
    }

    func showFailure(_ failure: SetupFailure) {
        setStalled(false)
        stepLabel.stringValue = "Setup couldn't finish"
        bar.isHidden = true
        detailLabel.stringValue = failure.userMessage + "\n\n" + failure.suggestedAction
        timingLabel.stringValue = ""
        technicalLabel.stringValue = failure.technicalDetail
        cancelButton.isHidden = true
        retryButton.isHidden = !failure.isRetryable
        showLogButton.isHidden = false
    }

    private func setStalled(_ stalled: Bool) {
        keepWaitingButton.isHidden = !stalled
        bar.isIndeterminate = stalled
        if stalled {
            bar.startAnimation(nil)
            detailLabel.stringValue = SetupCopy.takingLongerThanUsual
        } else {
            bar.stopAnimation(nil)
        }
    }

    /// Coarse on purpose (spec §7.3): a second-by-second countdown invites the
    /// user to watch it and distrust it.
    /// Spec §7.3. A withdrawn estimate (nil) is not silence — it says the run
    /// is still working, so the user does not read the missing number as a
    /// stall. The stall watchdog owns the "something is wrong" message.
    static func timing(elapsed: TimeInterval, remaining: TimeInterval?) -> String {
        let base = "\(phrase(elapsed)) elapsed"
        guard let remaining, remaining > 1 else {
            return base + " · still working — this can take longer on some Macs"
        }
        return base + " · about \(phrase(remaining)) remaining"
    }

    static func phrase(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "less than a minute" }
        let minutes = Int((seconds / 60).rounded())
        return minutes == 1 ? "1 min" : "\(minutes) min"
    }

    // MARK: actions

    @objc private func toggleDetails() {
        detailsExpanded = disclosure.state == .on
        technicalLabel.isHidden = !detailsExpanded
        showLogButton.isHidden = !detailsExpanded
    }

    @objc private func cancelTapped() { onCancel?() }
    @objc private func keepWaitingTapped() { onKeepWaiting?() }
    @objc private func retryTapped() { onRetry?() }
    @objc private func showLogTapped() { onShowLog?() }
}
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: succeeds

- [ ] **Step 3: Commit**

```bash
git add Sources/OpenXE/SetupPanelView.swift
git commit -m "feat: add the calm setup panel view

One determinate bar, plain-English step line, elapsed + remaining, and a
disclosure triangle over the technical detail and Show Log."
```

---

### Task 17: Wizard integration, confirm sheet, and ⌘Q

Replaces the wizard's inlined orchestration and makes quitting safe.

**Files:**
- Create: `Sources/OpenXE/AppMenu.swift`
- Modify: `Sources/OpenXE/WizardWindow.swift` (`environmentPrimary` `:263-293`, `nwsPrimary` `:409-455`, add `windowShouldClose`)
- Modify: `Sources/OpenXE/main.swift`, `Sources/OpenXE/AppDelegate.swift`

**Interfaces:**
- Consumes: `SetupCoordinator`, `ProductionStageRunner`, `SetupPanelView`
- Produces: `AppMenu.install()`, `WizardWindowController.confirmQuitIfBusy(completion:)`

- [ ] **Step 1: Implement `AppMenu.swift`**

```swift
import AppKit

/// Minimal main menu. Without one an accessory app has no ⌘Q at all — the
/// only ways out of a running setup were the red dot and Force Quit.
/// Adds no Dock presence and does not affect LSUIElement.
enum AppMenu {
    static func install() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About OpenXE",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit OpenXE",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        // Standard editing, so text fields in the settings windows behave.
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All",
                         action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        NSApp.mainMenu = main
    }
}
```

Then in `main.swift`, after `app.setActivationPolicy(.accessory)`:

```swift
AppMenu.install()
```

- [ ] **Step 2: Add the confirm sheet to `WizardWindow.swift`**

```swift
    /// Spec §8.1. The close button stays live during setup; clicking it asks
    /// first. The wording is stage-dependent and MUST state what is lost —
    /// promising resume and then re-running the prefix build is worse than
    /// saying so plainly.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let coordinator, !coordinator.isCancelled, isRunningSetup else { return true }
        confirmQuitIfBusy { [weak self] shouldQuit in
            guard shouldQuit else { return }
            self?.cancelSetupAndClose()
        }
        return false
    }

    func confirmQuitIfBusy(completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Setup is still running"
        alert.informativeText = quitConsequenceText()
        alert.addButton(withTitle: "Keep Installing")   // default
        alert.addButton(withTitle: "Quit Setup")
        alert.beginSheetModal(for: window) { response in
            completion(response == .alertSecondButtonReturn)
        }
    }

    /// Resumable stages keep their downloaded bytes; the prefix build and the
    /// NWS install do not (spec §6.3).
    private func quitConsequenceText() -> String {
        let resumable = currentStage.map { id in
            SetupCatalog.all.first { $0.id == id }?.resumable ?? false
        } ?? false
        let base = remainingEstimate.map { "About \(SetupPanelView.phrase($0)) left. " } ?? ""
        return base + "If you quit now, OpenXE will stop cleanly. "
            + (resumable
               ? "The parts already downloaded are kept, so setup will pick up where it left off."
               : "This step is not finished, so it will start over next time — but everything "
                 + "downloaded so far is kept.")
    }

    private func cancelSetupAndClose() {
        coordinator?.cancel()
        // The coordinator emits .cancelled once children are reaped; the
        // event handler closes the window.
    }
```

- [ ] **Step 3: Add `applicationShouldTerminate` to `AppDelegate.swift`**

```swift
    /// Covers ⌘Q, the Apple menu, and logout. Force-quit cannot be
    /// intercepted — SetupSweeper is the answer for that (spec §8.2).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let wizard = wizardWindow, wizard.isRunningSetup else { return .terminateNow }
        wizard.confirmQuitIfBusy { shouldQuit in
            if shouldQuit { wizard.cancelSetup() }
            NSApp.reply(toApplicationShouldTerminate: shouldQuit)
        }
        return .terminateLater
    }
```

And run the sweeper before any UI decision, at the top of `applicationDidFinishLaunching` (currently `:35`):

```swift
        // Force-quit and crashes leave orphans no handler can catch. Sweep
        // before deciding what to show (spec §8.4).
        let report = SetupSweeper(paths: paths).sweep()
        if report.stagingRemoved > 0 || report.partialsRemoved > 0 {
            NSLog("OpenXE swept %d staging dir(s), %d stale partial(s), %lld bytes",
                  report.stagingRemoved, report.partialsRemoved, report.bytesReclaimed)
        }
```

- [ ] **Step 4: Replace `environmentPrimary` and `nwsPrimary` with coordinator runs**

Both methods lose their inline `Task { }` orchestration and instead build a `SetupCoordinator` over the appropriate stage subset, install the `SetupPanelView`, and pump `coordinator.events` into `panel.apply(_:)`. The wizard keeps only: which stages to run, and what to do on `.finished` / `.failed` / `.cancelled`.

- [ ] **Step 5: Build and verify the menu exists**

Run: `swift build && make app`
Expected: build succeeds

Manual: launch OpenXE.app, confirm the menu bar shows "OpenXE" with Quit ⌘Q while a window is open.

- [ ] **Step 6: Commit**

```bash
git add Sources/OpenXE/AppMenu.swift Sources/OpenXE/main.swift \
        Sources/OpenXE/WizardWindow.swift Sources/OpenXE/AppDelegate.swift
git commit -m "feat: confirm-then-cancel on close, and add a main menu

The close button was live throughout setup with no confirmation and no
cleanup, and the app had no main menu so no ⌘Q existed at all."
```

---

### Task 18: Launch-path unification and notifications

**Files:**
- Modify: `Sources/OpenXE/ProgressWindow.swift`, `Sources/OpenXE/AppDelegate.swift:75-109`
- Create: `Sources/OpenXE/SetupNotifier.swift`

**Interfaces:**
- Produces: `SetupNotifier.notifySuccess()`, `.notifyFailure(_:)`

- [ ] **Step 1: Replace `runSetupThenLaunch` with a coordinator run**

Delete the inline orchestration at `AppDelegate.swift:75-109` and run `SetupCoordinator` over `SetupCatalog.launchPathSubset`, rendered by `ProgressWindowController`. `ProgressWindow` swaps its `apply(_ update: EngineProgress)` for a `SetupPanelView` and `apply(_ event: SetupEvent)`.

- [ ] **Step 2: Implement `SetupNotifier.swift`**

```swift
import AppKit
import UserNotifications
import OpenXECore

/// Setup is a walk-away operation, so completion and failure both notify
/// (spec §9.4). An ad-hoc-signed LSUIElement app has no guarantee of
/// notification authorization, so the attention fallback is REQUIRED, not
/// decorative.
@MainActor
enum SetupNotifier {

    private static var didRequestAuthorization = false

    /// Spec §9.4. Requested at most once per install, and only once the run has
    /// given a concrete reason to want it:
    ///
    ///   1. a stall (primary) — the user has waited >=60s, which is exactly
    ///      when a background notification becomes useful, and is a calm
    ///      moment rather than a bad one;
    ///   2. a failure while OpenXE is NOT frontmost (secondary).
    ///
    /// The frontmost condition matters: stacking a permission dialog on an
    /// error the user is already reading is the worst available timing. If
    /// OpenXE is in front they can see the failure and need no notification,
    /// so nothing is asked. In most bad runs the stall fires first anyway and
    /// authorization is settled before any error appears.
    ///
    /// Never at launch, never at stage start, never during normal progress —
    /// a clean install asks for nothing.
    static func requestAuthorizationOnStall() {
        requestOnce()
    }

    static func requestAuthorizationOnFailure() {
        guard !NSApp.isActive else { return }
        requestOnce()
    }

    private static func requestOnce() {
        guard !didRequestAuthorization else { return }
        didRequestAuthorization = true
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func notifySuccess() {
        post(title: "New World Scheduler is ready",
             body: "Setup finished. You can open it any time from your Applications folder.")
    }

    static func notifyFailure(_ failure: SetupFailure) {
        post(title: "Setup couldn't finish", body: failure.userMessage)
    }

    private static func post(title: String, body: String) {
        guard !NSApp.isActive else { return }   // only when we're in the background

        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else {
                DispatchQueue.main.async { fallback() }
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            center.add(UNNotificationRequest(identifier: UUID().uuidString,
                                             content: content, trigger: nil)) { error in
                if error != nil { DispatchQueue.main.async { fallback() } }
            }
        }
    }

    private static func fallback() {
        NSApp.requestUserAttention(.criticalRequest)
    }
}
```

- [ ] **Step 3: Wire the triggers into the event stream**

In whichever renderer is pumping `coordinator.events` (wizard and launch path both), add to the event switch:

```swift
case .stalled:
    SetupNotifier.requestAuthorizationOnStall()   // primary trigger, spec §9.4
case .failed(let failure):
    SetupNotifier.requestAuthorizationOnFailure() // secondary; no-op if frontmost
    SetupNotifier.notifyFailure(failure)
case .finished:
    SetupNotifier.notifySuccess()
```

Authorization is never requested anywhere else — not at launch, not at stage start.

- [ ] **Step 4: Build and run the full suite**

Run: `swift build && swift test`
Expected: all green

Manual: run `make fresh`, start setup, and confirm **no notification permission dialog appears** during a clean run.

- [ ] **Step 5: Commit**

```bash
git add Sources/OpenXE/SetupNotifier.swift Sources/OpenXE/ProgressWindow.swift \
        Sources/OpenXE/AppDelegate.swift
git commit -m "feat: route the launch path through SetupCoordinator; notify on finish

Removes the duplicated orchestration that let the engine size strings
drift apart, and notifies on success/failure with a required fallback."
```

---

### Task 19: Manual smoke matrix

**Files:**
- Modify: `docs/smoke-checklist.md`

- [ ] **Step 1: Add the cancel matrix from spec §13.3**

Append a "Setup resilience" section covering: cancel at each of the six stages, verifying for each that no `wine`/`wineserver`/`tar` survives, no `engine/staging-*` remains, partials are preserved or removed per §6.3, the journal reads `cancelled`, the next launch resumes at the documented stage, and `setup.log` contains both runs. Plus ⌘Q during each stage and the stage-dependent confirm wording.

- [ ] **Step 2: Verify the checklist is runnable**

Run: `make fresh ARGS=--dry-run`
Expected: prints what it would delete, exits 0

- [ ] **Step 3: Commit**

```bash
git add docs/smoke-checklist.md
git commit -m "docs: add setup-resilience smoke matrix"
```

---

## Self-Review

**Spec coverage.** Walked §3–§14: §3 copy → Task 1; §4.1–4.2 → Task 3; §4.3 → Task 9; §4.4 → Task 2; §5.1 → Task 5; §5.2 + §10.1 → Task 7; **§5.3 → Task 6**; §6 → Tasks 8, 14, 15; §7.1–7.3 → Task 16; §7.4 → Task 18; §8.1–8.2 → Task 17; §8.3 → Task 14; §8.4 → Tasks 12, 17; §9.1–9.2 → Tasks 3, 14; §9.3 → Task 16; §9.4 → Task 18; §9.5 → Task 10; §10.2 → Task 13; §13 → Tasks 15, 19; §13.4 calibration → deferred by decision, procedure retained in the spec. No gaps found.

**Placeholder scan.** Task 17 Step 4 and Task 18 Step 1 describe rewiring in prose rather than full code, because both are mechanical replacements of existing `Task { }` blocks whose surrounding code the implementer will have open; the interfaces they consume are fully specified in Tasks 14–16. Every other step carries real code. No TBDs.

**Type consistency.** Checked `SetupStage.ID` raw values, `PrefixProgress.fraction(at:within:)`, `SetupCatalog.renormalisedWeights(for:)`, `SetupLog.handle`, `ChildRegistry.terminateAll()`, `StageRunner.isAlreadySatisfied(_:journal:)` and `run(_:journal:progress:)` across all consumers — consistent. `SetupCoordinator.wrap` is `static` and tested directly in Task 15.

**No remaining estimates in shipped constants.** The earlier draft carried `expectedArchiveEntries = 5_600` as a guess; Task 7 Step 4 now measures it with `tar -tf` and the constant ships as `0` until that step replaces it, so an unmeasured value cannot slip through unnoticed — the test asserts it exceeds the installed tree's 5,324.

**One accepted approximation:** `expectedPrefixEntries = 2027` (Task 5) is a warm-machine measurement of one engine build. It drives only 4a's advisory bar, which is clamped and monotonic, so a wrong denominator yields a lazy bar rather than a wrong one. Deliberate, per decision 7.

**Weight coupling checked.** Task 3's stage weights and Task 5's sub-step weights both assume Task 6 landed. Both are asserted to sum to 100 by tests, so a partial application fails loudly rather than silently skewing the bar — but the *ratios* would be wrong if Task 6 were reverted without recomputing. Recorded in Global Constraints and in the §4.2 spec note.

---

## Decisions taken

All seven open questions were resolved before implementation. Recorded here so the reasoning survives the conversation.

| # | Decision | Consequence in this plan |
|---|---|---|
| 1 | **`EngineManager.install` stays merged.** Splitting it would buy separate reporting for a ~2 s verify step. | Stages 2 and 3 blend in the UI; Task 15 keeps the single `ensureDefaultActive` call. |
| 2 | **Cold calibration deferred; ship warm-M2 defaults.** | Weights become data (`StageWeightTable`, Task 3) correctable via `defaults write`. §7.3 **Rule B** withdraws the estimate on 1.5× overshoot (Task 14). Spec states plainly the ETA reads optimistic on slower hardware. §13.4 kept as a runnable procedure. |
| 3 | **Measure `expectedArchiveEntries`.** | Task 7 Step 4 lists the pinned archive with `tar -tf`; the `5,600` estimate is not shipped. |
| 4 | **Ask for notification permission only on first stall, or on failure while backgrounded.** | Task 18 Step 3. A clean run never shows a permission dialog, and one can never stack on an error the user is reading. |
| 5 | **Stall threshold stays 60 s.** | Task 11 unchanged. Rationale and the rejected 30 s alternative recorded in spec §11 R4; listed as a §13.4 calibration output. |
| 6 | **`useBatchedImport` is removed after one cold run + one real install.** | Removal condition written into the flag's own doc comment (Task 6 Step 3) so it cannot become permanent by default. |
| 7 | **Add the coarse determinate signal to 4a.** | `BootProgressPoller` (Task 5 Step 3b): prefix file count against ~2,027, advisory, clamped, monotonic. Closes R3a — stage 4 has two independent mechanisms again. |

### Deferred, with an owner

- **Cold-machine calibration (spec §13.4).** Needs hardware with no Rosetta AOT cache. Blocked on availability, not on a decision. It is also condition (a) for removing `useBatchedImport`.
- **Rule B's 1.5× overshoot factor** and the 60 s stall threshold are both warm-machine guesses. Neither is load-bearing for correctness — each only affects when a message appears — but both should be checked when §13.4 runs.
