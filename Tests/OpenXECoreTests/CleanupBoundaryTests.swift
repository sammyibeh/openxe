import XCTest
@testable import OpenXECore

/// A test suite that can delete a congregation database is unacceptable.
///
/// This is the sibling of `SystemInstallerBoundaryTests`, written for the same
/// reason and before the equivalent accident could happen. That file exists
/// because a defaulted initialiser argument silently re-pointed every existing
/// test at a live system installer. `CleanupRunner` deletes entire directory
/// trees, so the same mistake here would be worse.
///
/// Three independent defences, all pinned here:
///
/// 1. `CleanupPlanner` and `CleanupRunner` have no defaulted dependencies — a
///    test cannot accidentally construct one aimed at the real machine.
/// 2. `CleanupRunner` refuses outright when a test bundle is loaded and its
///    roots are not inside a caller-declared sandbox.
/// 3. The allowlist rejects the real user's folders even if a plan names them.
final class CleanupBoundaryTests: XCTestCase {

    private func liveSharpEdges() -> (planner: CleanupPlanner, home: URL) {
        // Deliberately constructed the way a careless future test might: aimed
        // squarely at the real machine. It must never be able to delete.
        let home = FileManager.default.homeDirectoryForCurrentUser
        let library = home.appendingPathComponent("Library")
        let planner = CleanupPlanner(
            paths: OpenXEPaths(root: library.appendingPathComponent("Application Support/OpenXE")),
            home: home, library: library, bundleIdentifier: "dev.openxe.OpenXE",
            launcherDirectories: LauncherManager.candidateDirectories)
        return (planner, home)
    }

    func testTheSuiteCanRecogniseItself() {
        XCTAssertTrue(CleanupSafety.isRunningUnderTest,
                      "the refusal below is worthless if this is false")
    }

    /// The backstop: a runner aimed at the real machine, with no sandbox.
    func testRunnerRefusesWithoutASandbox() {
        let (planner, home) = liveSharpEdges()
        let runner = CleanupRunner(
            planner: planner, paths: planner.paths, home: home, sandbox: nil,
            shutdownWineserver: { XCTFail("must not shut down the real wineserver") },
            unregisterFromLaunchServices: { XCTFail("must not touch LaunchServices") })

        XCTAssertThrowsError(
            try runner.run(plan: planner.plan(), keepNWSData: true,
                           documentsDirectory: home.appendingPathComponent("Documents"),
                           now: Date())
        ) { error in
            guard case CleanupError.refusedUnderTest = error else {
                return XCTFail("expected refusedUnderTest, got \(error)")
            }
        }
    }

    /// A sandbox that does not actually contain the roots is not a sandbox.
    func testRunnerRefusesWhenRootsEscapeTheDeclaredSandbox() {
        let (planner, home) = liveSharpEdges()
        let fakeSandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("openxe-not-really-\(UUID().uuidString)", isDirectory: true)
        let runner = CleanupRunner(
            planner: planner, paths: planner.paths, home: home, sandbox: fakeSandbox,
            shutdownWineserver: { XCTFail("must not shut down the real wineserver") },
            unregisterFromLaunchServices: { XCTFail("must not touch LaunchServices") })

        XCTAssertThrowsError(
            try runner.run(plan: planner.plan(), keepNWSData: true,
                           documentsDirectory: home.appendingPathComponent("Documents"),
                           now: Date())
        ) { error in
            guard case CleanupError.refusedUnderTest(let detail) = error else {
                return XCTFail("expected refusedUnderTest, got \(error)")
            }
            XCTAssertTrue(detail.contains("outside sandbox"), detail)
        }
    }

    /// Even the real machine's live footprint, handed straight to the allowlist,
    /// cannot reach anything of the user's.
    func testTheAllowlistRejectsTheRealUsersFoldersOnThisMachine() {
        let (planner, home) = liveSharpEdges()
        let roots = planner.allowedRoots
        for sacred in ["Documents", "Downloads", "Desktop", "Pictures", "Library"] {
            let url = home.appendingPathComponent(sacred)
            XCTAssertFalse(CleanupSafety.isDeletable(url, allowedRoots: roots, home: home),
                           "~/\(sacred) is reachable by cleanup on this machine")
        }
        XCTAssertFalse(CleanupSafety.isDeletable(home, allowedRoots: roots, home: home))
        XCTAssertFalse(CleanupSafety.isDeletable(URL(fileURLWithPath: "/"),
                                                 allowedRoots: roots, home: home))
        XCTAssertFalse(CleanupSafety.isDeletable(URL(fileURLWithPath: "/Applications"),
                                                 allowedRoots: roots, home: home))
    }

    /// Planning is read-only, so it is allowed to look at the real machine — but
    /// it must not have changed it. This runs whatever state this Mac is in.
    func testPlanningTheRealMachineChangesNothing() throws {
        let (planner, _) = liveSharpEdges()
        let fm = FileManager.default
        let root = planner.paths.root
        let before = fm.fileExists(atPath: root.path)
        _ = planner.plan()
        XCTAssertEqual(fm.fileExists(atPath: root.path), before,
                       "planning must be read-only")
    }
}
