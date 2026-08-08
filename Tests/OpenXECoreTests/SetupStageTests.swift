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
        // Spec §9.2: re-running a failed wineboot automatically wastes the
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
