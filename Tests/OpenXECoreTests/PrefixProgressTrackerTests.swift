import XCTest
@testable import OpenXECore

/// Stage 4 published into a nil closure because the wizard called
/// `ensurePrefix(log:)` with no `progress:` argument — the boot poller, the
/// font counter and every sub-step marker all reported to nobody. Now that the
/// stream reaches the surface, these pin the two properties that make it
/// honest: it never rewinds, and it never invents a position.
final class PrefixProgressTrackerTests: XCTestCase {

    func testAdvancesThroughEverySubStepInOrder() {
        var tracker = PrefixProgressTracker()
        var shown: [Double] = []
        for step in PrefixProgress.SubStep.allCases {
            for inner in [0.0, 0.5, 1.0] {
                if let p = tracker.position(for: .step(step, fraction: inner, detail: step.detail)) {
                    shown.append(p)
                }
            }
        }
        XCTAssertEqual(shown, shown.sorted(), "the bar must never rewind")
        XCTAssertEqual(shown.last ?? 0, 1.0, accuracy: 0.0001, "stage 4 must finish at 100%")
        XCTAssertFalse(shown.isEmpty)
    }

    /// The boot poller's file count is advisory: a poll that transiently sees
    /// fewer entries must hold the bar, not drag it back.
    func testTransientDipHoldsTheBar() {
        var tracker = PrefixProgressTracker()
        let up = tracker.position(for: .step(.boot, fraction: 0.60, detail: "x"))
        XCTAssertNotNil(up)
        XCTAssertNil(tracker.position(for: .step(.boot, fraction: 0.40, detail: "x")),
                     "a dip must yield no new position")
        XCTAssertNil(tracker.position(for: .step(.boot, fraction: 0.60, detail: "x")),
                     "repeating the high-water mark is not forward movement")
        XCTAssertNotNil(tracker.position(for: .step(.boot, fraction: 0.61, detail: "x")))
    }

    /// A later sub-step must not be dragged back by boot's own reporting.
    func testLaterSubStepNeverRewoundByAStaleBootEvent() {
        var tracker = PrefixProgressTracker()
        _ = tracker.position(for: .step(.registry, fraction: 1.0, detail: "x"))
        XCTAssertNil(tracker.position(for: .step(.boot, fraction: 1.0, detail: "x")),
                     "a late poller event must not rewind past registry")
    }

    /// Boot is 82% of stage 4; its midpoint is a real measured position, not a
    /// placeholder. Guards against reintroducing a hardcoded fraction.
    func testBootMidpointIsTheMeasuredWeightedPosition() {
        var tracker = PrefixProgressTracker()
        let p = tracker.position(for: .step(.boot, fraction: 0.5, detail: "x"))
        XCTAssertEqual(p ?? -1, 0.41, accuracy: 0.0001)
    }

    func testDetailIsAlwaysReportedEvenWhenTheBarHolds() {
        var tracker = PrefixProgressTracker()
        _ = tracker.position(for: .step(.boot, fraction: 0.9, detail: "x"))
        let held = PrefixProgress.step(.boot, fraction: 0.1, detail: "Setting up Windows…")
        XCTAssertNil(tracker.position(for: held))
        XCTAssertEqual(PrefixProgressTracker.detail(for: held), "Setting up Windows…")
    }

    func testStartsAtZeroAndFirstEventIsForwardMovement() {
        var tracker = PrefixProgressTracker()
        XCTAssertNil(tracker.position(for: .step(.boot, fraction: 0, detail: "x")),
                     "zero is where the bar already is")
        XCTAssertNotNil(tracker.position(for: .step(.boot, fraction: 0.01, detail: "x")))
    }
}
