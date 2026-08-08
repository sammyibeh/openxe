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
