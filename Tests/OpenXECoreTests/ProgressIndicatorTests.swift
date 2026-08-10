#if canImport(AppKit)
import AppKit
import XCTest
@testable import OpenXECore

/// The last link in the chain: `BarState` → the control's own state.
///
/// ## What this covers, and what it cannot
///
/// It asserts the *state* `NSProgressIndicator` is left in — `isIndeterminate`
/// and `doubleValue`. That is enough to catch the shipped defect class:
/// forgetting `isIndeterminate = false` leaves the bar animating forever and
/// silently ignoring every position it is handed, which is precisely a frozen
/// bar from the user's side.
///
/// It does **not** and cannot assert what is drawn. An off-screen readback of
/// `NSProgressIndicator` (`cacheDisplay(in:to:)`, `CALayer.render(in:)`)
/// reports no fill even for a control known to be at 75 %, so the instrument
/// is blind and any pixel assertion built on it would be a fake that passes
/// regardless. Whether the bar visibly moves on screen is verifiable only by a
/// human watching a real run; it is on the manual smoke checklist for that
/// reason and is deliberately not simulated here.
final class ProgressIndicatorTests: XCTestCase {

    @MainActor
    private func makeBar() -> NSProgressIndicator {
        let bar = NSProgressIndicator()
        bar.style = .bar
        bar.minValue = 0
        bar.maxValue = 1
        bar.isIndeterminate = true     // how both windows start
        return bar
    }

    /// The defect, directly: a determinate state must switch the control out of
    /// indeterminate mode. An indeterminate bar ignores `doubleValue` entirely.
    @MainActor
    func testDeterminateLeavesIndeterminateModeAndTakesThePosition() {
        let bar = makeBar()
        bar.apply(.determinate(0.42))
        XCTAssertFalse(bar.isIndeterminate,
                       "The bar is still indeterminate, so it will ignore every position "
                       + "it is given and animate forever — the frozen bar, again.")
        XCTAssertEqual(bar.doubleValue, 0.42, accuracy: 0.0001)
    }

    /// A realistic event sequence must leave the control at a visibly different
    /// position each time. One-shot assertions cannot tell moving from stuck.
    @MainActor
    func testBarAdvancesAcrossASequenceOfStates() {
        let bar = makeBar()
        var positions: [Double] = []
        for fraction in stride(from: 0.0, through: 1.0, by: 0.1) {
            bar.apply(.determinate(fraction))
            positions.append(bar.doubleValue)
        }
        XCTAssertEqual(positions, positions.sorted())
        XCTAssertGreaterThan(Set(positions).count, 1, "the control never moved")
        XCTAssertEqual(positions.last ?? 0, 1.0, accuracy: 0.0001)
    }

    /// Stage 4's hold must leave the bar exactly where it was — not reset it to
    /// zero, which would look like the bar restarting mid-stage.
    @MainActor
    func testUnchangedHoldsThePosition() {
        let bar = makeBar()
        bar.apply(.determinate(0.6))
        bar.apply(.unchanged)
        XCTAssertFalse(bar.isIndeterminate)
        XCTAssertEqual(bar.doubleValue, 0.6, accuracy: 0.0001)
    }

    /// Going back to indeterminate (stage 6, or a lost Content-Length) has to
    /// re-enter indeterminate mode after a determinate stage.
    @MainActor
    func testIndeterminateReturnsToAnimatedMode() {
        let bar = makeBar()
        bar.apply(.determinate(0.5))
        bar.apply(.indeterminate)
        XCTAssertTrue(bar.isIndeterminate)
    }

    /// A fraction outside 0...1 must clamp rather than push the control past
    /// its own bounds.
    @MainActor
    func testOutOfRangeFractionsClampToTheControlBounds() {
        let bar = makeBar()
        bar.apply(.determinate(1.7))
        XCTAssertEqual(bar.doubleValue, 1.0, accuracy: 0.0001)
        bar.apply(.determinate(-0.5))
        XCTAssertEqual(bar.doubleValue, 0.0, accuracy: 0.0001)
    }

    // MARK: end to end, Core event → control state

    /// The whole visible chain in one test: the engine events a real unpack
    /// emits, through `SetupDisplay`, onto the control. This is what the wizard
    /// and the progress window each do, minus the window.
    @MainActor
    func testUnpackEventsDriveTheControlForward() {
        let bar = makeBar()
        var positions: [Double] = []
        for entries in stride(from: 25, through: 5000, by: 25) {
            let display = SetupDisplay.engine(.unpacking(entries: entries), unpackTotal: 5400)
            bar.apply(display.bar)
            positions.append(bar.doubleValue)
        }
        XCTAssertEqual(positions, positions.sorted())
        XCTAssertGreaterThan(Set(positions).count, 1,
                             "Stage 3's control never moved across 200 unpack events.")
        XCTAssertFalse(bar.isIndeterminate)
    }

    /// Stage 4 through the tracker: sub-steps advance the control and never
    /// drag it backwards, even when an event reports a lower inner fraction.
    @MainActor
    func testPrefixEventsDriveTheControlForwardWithoutRewinding() {
        let bar = makeBar()
        var tracker = PrefixProgressTracker()
        var positions: [Double] = []
        for step in PrefixProgress.SubStep.allCases {
            for inner in [0.0, 0.5, 1.0] {
                let display = SetupDisplay.prefix(
                    .step(step, fraction: inner, detail: step.detail), tracker: &tracker)
                bar.apply(display.bar)
                positions.append(bar.doubleValue)
            }
        }
        XCTAssertEqual(positions, positions.sorted(), "stage 4 rewound on screen")
        XCTAssertGreaterThan(Set(positions).count, 1, "stage 4's control never moved")
        XCTAssertGreaterThan(positions.last ?? 0, 0.9)
    }
}
#endif
