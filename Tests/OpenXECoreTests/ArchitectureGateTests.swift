import XCTest
@testable import OpenXECore

/// Spec §6. OpenXE ships as a universal binary and must behave correctly on
/// both kinds of Mac. The asymmetry is the whole point:
///
/// - **Apple silicon** runs the x86_64 Wine engine through Rosetta, so the gate
///   has to check, explain and remediate.
/// - **Intel** runs that same engine *natively*. Rosetta is irrelevant there,
///   and the user must never see a word about it.
///
/// These tests exist because the Intel path cannot be exercised on the machine
/// OpenXE is developed on. `swift test` builds host-arch-only, so a compile-time
/// `#if arch(...)` check would silently never run for the other architecture —
/// hence the injected-architecture tests below, which run everywhere.
final class ArchitectureGateTests: XCTestCase {

    // MARK: the Intel path — silent no-op

    /// On an Intel Mac the answer is known without asking: x86_64 binaries run.
    /// The probe spawns `/usr/bin/arch`, so this also pins that OpenXE does not
    /// pay for a subprocess on every launch on hardware that cannot need it.
    func testIntelMacAnswersWithoutProbing() {
        var probed = false
        let result = RosettaCheck.canRunX86_64(isAppleSilicon: false,
                                               probe: { probed = true; return false })
        XCTAssertTrue(result, "an Intel Mac runs the x86_64 engine natively")
        XCTAssertFalse(probed, "no translation probe should be spawned on Intel")
    }

    /// The gate as the UI actually consumes it: on Intel it is satisfied, so no
    /// explanation and no install offer are ever produced — even with the offer
    /// switched on and an installer wired up that would report success.
    func testIntelMacNeverSeesAnExplanationOrAnOffer() {
        let installerRan = Flag()
        let gate = RosettaGate(
            probe: { RosettaCheck.canRunX86_64(isAppleSilicon: false, probe: { false }) },
            installer: { installerRan.set(); return (0, "") },
            offersInstall: true)
        guard case .satisfied = gate.check() else {
            return XCTFail("the Rosetta gate must be a no-op on Intel")
        }
        XCTAssertFalse(installerRan.value)
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        func set() { lock.lock(); flag = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    }

    // MARK: the Apple silicon path — defer to the machine

    func testAppleSiliconDefersEntirelyToTheProbe() {
        XCTAssertTrue(RosettaCheck.canRunX86_64(isAppleSilicon: true, probe: { true }))
        XCTAssertFalse(RosettaCheck.canRunX86_64(isAppleSilicon: true, probe: { false }))
    }

    // MARK: this host

    /// Whichever machine runs the suite, `isNeeded` must agree with the
    /// architecture the tests were compiled for.
    func testDetectionAgreesWithTheHostArchitecture() {
        #if arch(arm64)
        XCTAssertTrue(RosettaCheck.isNeeded, "Apple silicon needs Rosetta for the engine")
        #elseif arch(x86_64)
        XCTAssertFalse(RosettaCheck.isNeeded, "Intel runs the engine natively")
        XCTAssertTrue(RosettaCheck.canRunX86_64)
        #endif
    }
}
