import XCTest
@testable import OpenXECore

/// App Translocation broke removal in a way nothing noticed: `lsregister -u` was
/// handed the translocated path, exited 0, and left `/Applications/OpenXE.app`
/// registered as the `.exe` handler.
///
/// The translocated case cannot be staged from a test — Gatekeeper decides when
/// it happens — so the two system primitives are injected and every branch is
/// pinned here, including the two where the real path is NOT knowable.
final class BundleLocationTests: XCTestCase {

    private let installed = URL(fileURLWithPath: "/Applications/OpenXE.app")
    /// The shape macOS actually produced on this Mac (observed 2026-08-09).
    private let translocated = URL(fileURLWithPath:
        "/private/var/folders/z4/whkmmwj52_9f4_nc475zjnxh0000gn/T/AppTranslocation/"
        + "10B744D2-AFEE-4F8C-BBE2-53D11B6AC59C/d/OpenXE.app")

    private func resolver(isTranslocated: Bool?, original: URL?) -> BundleLocationResolver {
        BundleLocationResolver(isTranslocated: { _ in isTranslocated },
                               originalPath: { _ in original })
    }

    // MARK: resolution

    func testANormalBundleResolvesToItself() {
        let location = resolver(isTranslocated: false, original: nil).resolve(installed)
        XCTAssertEqual(location, .real(installed))
        XCTAssertEqual(location.realURL, installed)
        XCTAssertFalse(location.isTranslocated)
    }

    /// The defect, in one assertion: the real path, not the mount it is running
    /// from.
    func testATranslocatedBundleResolvesToTheInstalledCopy() {
        let location = resolver(isTranslocated: true, original: installed).resolve(translocated)
        XCTAssertEqual(location, .translocated(real: installed, translocated: translocated))
        XCTAssertEqual(location.realURL, installed)
        XCTAssertTrue(location.isTranslocated)
    }

    func testAnUnresolvableOriginalIsReportedRatherThanGuessed() {
        let location = resolver(isTranslocated: true, original: nil).resolve(translocated)
        XCTAssertEqual(location, .unresolvedTranslocation(translocated))
        XCTAssertNil(location.realURL, "a path that could not be resolved must not be offered")
    }

    /// `SecTranslocateCreateOriginalPathForURL` hands back a copy of the input
    /// when it has nothing better. That is not a resolution.
    func testAnEchoedInputIsNotTreatedAsAResolution() {
        let location = resolver(isTranslocated: true, original: translocated).resolve(translocated)
        XCTAssertEqual(location, .unresolvedTranslocation(translocated))
    }

    /// If the query itself fails, the path's own shape is the last signal — and
    /// it is only ever used to withhold trust, never to invent an original.
    func testAFailedQueryOnATranslocationPathRefusesToTrustIt() {
        let location = resolver(isTranslocated: nil, original: installed).resolve(translocated)
        XCTAssertEqual(location, .unresolvedTranslocation(translocated))
    }

    func testAFailedQueryOnAnOrdinaryPathIsTreatedAsReal() {
        let location = resolver(isTranslocated: nil, original: nil).resolve(installed)
        XCTAssertEqual(location, .real(installed))
    }

    /// The shipped resolver, against this test bundle. Read-only, and true on any
    /// Mac: a bundle running from the build directory is not translocated, so the
    /// system primitives must agree that it is where it says it is. This is what
    /// catches the symbols disappearing from Security.framework.
    func testTheSystemResolverAgreesWithTheRunningBundle() {
        let url = Bundle.main.bundleURL
        let location = BundleLocationResolver.system.resolve(url)
        XCTAssertEqual(location, .real(url))
        XCTAssertEqual(SecTranslocateShim.isTranslocated(url), false,
                       "SecTranslocateIsTranslocatedURL could not be called")
        XCTAssertEqual(SecTranslocateShim.originalPath(url)?.standardizedFileURL.path,
                       url.standardizedFileURL.path)
    }

    // MARK: the decision that follows from it

    func testAnOrdinaryBundleIsUnregisteredAtItsOwnPath() {
        let decision = LaunchServicesUnregistration.decide(for: .real(installed))
        XCTAssertEqual(decision.pathToUnregister, installed.path)
        XCTAssertTrue(decision.logLine.contains(installed.path))
    }

    func testATranslocatedBundleIsUnregisteredAtTheInstalledPath() {
        let decision = LaunchServicesUnregistration.decide(
            for: .translocated(real: installed, translocated: translocated))
        XCTAssertEqual(decision.pathToUnregister, installed.path,
                       "unregistering the translocated path leaves the .exe handler in place")
        XCTAssertTrue(decision.logLine.contains(translocated.path),
                      "the log must show that translocation was in play")
    }

    func testAnUnresolvedTranslocationUnregistersNothingAndSaysSo() {
        let decision = LaunchServicesUnregistration.decide(
            for: .unresolvedTranslocation(translocated))
        XCTAssertNil(decision.pathToUnregister, "a wrong path must never be unregistered")
        XCTAssertTrue(decision.logLine.contains("DID NOT unregister"))
        XCTAssertTrue(decision.logLine.contains(translocated.path))
    }

    func testNoBundleUnregistersNothingAndSaysSo() {
        let decision = LaunchServicesUnregistration.decide(for: nil)
        XCTAssertNil(decision.pathToUnregister)
        XCTAssertTrue(decision.logLine.contains("DID NOT unregister"))
    }
}
