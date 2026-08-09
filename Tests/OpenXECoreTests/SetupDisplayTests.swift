import XCTest
@testable import OpenXECore

/// Covers the mapping that used to be private to `WizardWindowController`,
/// where `.unpacking` was wired to an indeterminate bar for the whole of stage
/// 3 and nothing could catch it.
///
/// The shape of these tests is deliberate: they replay a realistic event
/// sequence for a stage and assert the bar *advances*. A test that only checks
/// one event in isolation cannot tell a moving bar from a frozen one.
final class SetupDisplayTests: XCTestCase {

    private func positions(_ displays: [StageDisplay]) -> [Double] {
        displays.compactMap { if case .determinate(let f) = $0.bar { return f } else { return nil } }
    }

    // MARK: stage 2 — engine download

    func testDownloadStageBarAdvancesAcrossATransfer() {
        let events: [EngineProgress] = stride(from: 0.0, through: 1.0, by: 0.1)
            .map { .downloading(fraction: $0) }
        let bars = positions(events.map { SetupDisplay.engine($0) })
        XCTAssertEqual(bars.count, events.count,
                       "every known fraction must produce a determinate bar")
        XCTAssertEqual(bars, bars.sorted())
        XCTAssertGreaterThan(Set(bars).count, 1, "the download bar never moved")
    }

    func testDownloadLabelShowsThePercentage() {
        XCTAssertEqual(SetupDisplay.engine(.downloading(fraction: 0.42)).label,
                       "Downloading the Windows environment… 42%")
    }

    func testUnknownDownloadTotalIsIndeterminateNotZero() {
        let display = SetupDisplay.engine(.downloading(fraction: -1))
        XCTAssertEqual(display.bar, .indeterminate)
        XCTAssertFalse(display.label.contains("%"),
                       "an unknown total must not be dressed up as a percentage")
    }

    // MARK: stage 3 — unpack (the defect)

    /// The regression: `.unpacking` mapped to an indeterminate bar, so stage 3
    /// could not move no matter how many entries arrived.
    func testUnpackStageBarAdvancesWhenTheTotalIsKnown() {
        let total = 5400
        let displays = stride(from: 25, through: 5000, by: 25).map {
            SetupDisplay.engine(.unpacking(entries: $0), unpackTotal: total)
        }
        let bars = positions(displays)
        XCTAssertEqual(bars.count, displays.count,
                       "Stage 3's bar is indeterminate again — it cannot move.")
        XCTAssertEqual(bars, bars.sorted())
        XCTAssertGreaterThan(Set(bars).count, 1, "the unpack bar never moved")
        XCTAssertLessThan(bars.last ?? 1, 1.0,
                          "the bar must not claim the unpack is done while tar runs")
    }

    func testUnpackLabelCarriesTheEntryCount() {
        XCTAssertEqual(SetupDisplay.engine(.unpacking(entries: 1200), unpackTotal: 5400).label,
                       "Unpacking the Windows environment… 1200 files")
    }

    /// No measurement for this engine ⇒ honest indeterminate, count still moves.
    func testUnpackWithoutAMeasurementStaysIndeterminate() {
        let display = SetupDisplay.engine(.unpacking(entries: 900), unpackTotal: nil)
        XCTAssertEqual(display.bar, .indeterminate)
        XCTAssertTrue(display.label.contains("900"))
    }

    /// A wrong measurement degrades to indeterminate rather than to a lie.
    func testUnpackBeyondTheMeasuredTotalDegradesToIndeterminate() {
        XCTAssertNil(SetupDisplay.unpackFraction(entries: 5401, of: 5400))
        XCTAssertEqual(SetupDisplay.engine(.unpacking(entries: 9999), unpackTotal: 5400).bar,
                       .indeterminate)
    }

    func testUnpackFractionIsCappedBelowCompletion() {
        XCTAssertEqual(SetupDisplay.unpackFraction(entries: 5400, of: 5400) ?? 1, 0.99,
                       accuracy: 0.0001)
    }

    func testStockEngineCarriesAnUnpackMeasurement() {
        XCTAssertNotNil(EngineCatalog.stock.expectedUnpackEntries,
                        "Without a denominator the unpack bar falls back to indeterminate.")
    }

    /// Descriptors written before the field existed must still load.
    func testDescriptorDecodesWithoutTheUnpackMeasurement() throws {
        let json = """
        {"id":"legacy","displayName":"Legacy","version":"1","wineBinaryName":"wine",
         "url":"https://example.invalid/a.tar.xz","sha256":"abc"}
        """
        let decoded = try JSONDecoder().decode(EngineDescriptor.self, from: Data(json.utf8))
        XCTAssertNil(decoded.expectedUnpackEntries)
    }

    // MARK: stage 4 — prefix

    /// Every sub-step must produce a label, and the bar must advance overall
    /// without ever going backwards.
    func testPrefixStageAdvancesAndNeverRewinds() {
        var tracker = PrefixProgressTracker()
        var events: [PrefixProgress] = []
        for step in PrefixProgress.SubStep.allCases {
            for inner in [0.0, 0.5, 1.0] {
                events.append(.step(step, fraction: inner, detail: step.detail))
            }
        }
        let displays = events.map { SetupDisplay.prefix($0, tracker: &tracker) }

        XCTAssertTrue(displays.allSatisfy { !$0.label.isEmpty },
                      "every stage-4 event must say what is happening")
        let bars = positions(displays)
        XCTAssertEqual(bars, bars.sorted(), "stage 4 must never rewind")
        XCTAssertGreaterThan(Set(bars).count, 1, "the prefix bar never moved")
        XCTAssertGreaterThan(bars.last ?? 0, 0.9, "stage 4 must approach completion")
    }

    /// A backwards event holds the bar rather than moving it — and still
    /// updates the label, so the screen is never stale.
    func testPrefixRewindEventHoldsTheBarButKeepsTheLabel() {
        var tracker = PrefixProgressTracker()
        _ = SetupDisplay.prefix(.step(.registry, fraction: 1, detail: "Configuring…"),
                                tracker: &tracker)
        let backwards = SetupDisplay.prefix(
            .step(.boot, fraction: 0.1, detail: "Setting up Windows for the first time…"),
            tracker: &tracker)
        XCTAssertEqual(backwards.bar, .unchanged)
        XCTAssertEqual(backwards.label, "Setting up Windows for the first time…")
    }

    // MARK: stage 5 + 6 — NWS

    func testNWSDownloadBarAdvances() {
        let bars = positions(stride(from: 0.0, through: 1.0, by: 0.25)
            .map { SetupDisplay.nws(.downloading(fraction: $0)) })
        XCTAssertEqual(bars, [0, 0.25, 0.5, 0.75, 1.0])
    }

    /// Stage 6 is genuinely opaque; it must say so with an animated bar rather
    /// than inventing a fraction.
    func testInstallStageIsIndeterminateAndSaysWhatItIsDoing() {
        let display = SetupDisplay.nws(.installing)
        XCTAssertEqual(display.bar, .indeterminate)
        XCTAssertEqual(display.label, "Installing New World Scheduler…")
        XCTAssertFalse(display.label.contains("%"))
    }

    // MARK: every stage says something

    /// Guards the second half of the user-visible defect: the label never
    /// changed either. Any event that reaches the screen must carry text.
    func testEveryEventProducesANonEmptyLabel() {
        var tracker = PrefixProgressTracker()
        var labels: [String] = [
            SetupDisplay.engine(.downloading(fraction: 0.5)).label,
            SetupDisplay.engine(.downloading(fraction: -1)).label,
            SetupDisplay.engine(.verifying).label,
            SetupDisplay.engine(.extracting).label,
            SetupDisplay.engine(.unpacking(entries: 100), unpackTotal: 5400).label,
            SetupDisplay.nws(.downloading(fraction: 0.5)).label,
            SetupDisplay.nws(.downloading(fraction: -1)).label,
            SetupDisplay.nws(.installing).label,
            SetupDisplay.nws(.verifying).label,
        ]
        for step in PrefixProgress.SubStep.allCases {
            labels.append(SetupDisplay.prefix(.step(step, fraction: 0, detail: step.detail),
                                              tracker: &tracker).label)
        }
        XCTAssertTrue(labels.allSatisfy { !$0.isEmpty })
    }
}
