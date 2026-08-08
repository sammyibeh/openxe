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

    /// The poller's reported fraction is a running maximum: a transient dip in
    /// the on-disk entry count must not rewind the bar (spec §5.1, R3a).
    func testBootPollerNeverReportsARegression() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("openxe-poller-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let lock = NSLock()
        nonisolated(unsafe) var seen: [Double] = []
        let poller = BootProgressPoller(prefix: dir) { f in
            lock.lock(); seen.append(f); lock.unlock()
        }

        for i in 1...20 {
            fm.createFile(atPath: dir.appendingPathComponent("f\(i)").path, contents: nil)
        }
        poller.pollOnce()
        for i in 1...20 {
            try fm.removeItem(at: dir.appendingPathComponent("f\(i)"))
        }
        poller.pollOnce()

        lock.lock(); let got = seen; lock.unlock()
        XCTAssertEqual(got.count, 1, "a shrinking count must emit nothing, not a lower fraction")
        XCTAssertEqual(got.first ?? -1, PrefixProgress.bootFraction(filesSeen: 20), accuracy: 0.0001)
    }
}
