import XCTest
@testable import OpenXECore

/// A test run must never modify the machine it runs on.
///
/// This file exists because it already happened. `RosettaGate` had defaulted
/// initialiser arguments pointing at the real installers; adding a third
/// dependency (`authorizedInstaller`) silently re-pointed every existing test
/// at the live path, which reinstalled Apple's Rosetta package as root and put
/// a password panel on the developer's screen mid-suite. On a Mac WITHOUT
/// Rosetta it would have installed system software without anyone asking.
///
/// Two independent defences, both pinned here:
///
/// 1. `RosettaGate` has no defaulted dependencies — a test is forced to inject.
/// 2. The live installers refuse outright when a test bundle is loaded.
final class SystemInstallerBoundaryTests: XCTestCase {

    /// The backstop. If defence 1 is ever undone, this keeps the machine safe.
    func testLiveInstallersRefuseToRunUnderTest() {
        XCTAssertTrue(RosettaCheck.isRunningUnderTest,
                      "the suite must be able to recognise itself")

        let direct = RosettaCheck.install()
        XCTAssertEqual(direct.status, RosettaCheck.refusedUnderTest.status)
        XCTAssertEqual(direct.output, RosettaCheck.refusedUnderTest.output)

        let authorized = RosettaCheck.installWithAdministratorAuthorization()
        XCTAssertEqual(authorized.status, RosettaCheck.refusedUnderTest.status)
        XCTAssertEqual(authorized.output, RosettaCheck.refusedUnderTest.output)
    }

    /// Even the production wiring is inert here, so a stray `RosettaGate.live()`
    /// in a future test cannot install anything either.
    func testLiveGateCannotInstallAnythingDuringATestRun() {
        let gate = RosettaGate.live(offersInstall: true)
        switch gate.attemptInstall() {
        case .installed:
            // Legitimate only when this machine could already run x86_64 before
            // the call — the refusal guarantees nothing was installed to make it
            // so. On a Mac without Rosetta this branch must not be reachable.
            XCTAssertTrue(RosettaCheck.canRunX86_64,
                          "reported installed on a machine that cannot run x86_64")
        case .failed(let failure):
            XCTAssertTrue(failure.technicalDetail.contains("refused"),
                          "expected the refusal in the log detail: \(failure.technicalDetail)")
        }
    }
}
