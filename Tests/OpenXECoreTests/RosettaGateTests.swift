import XCTest
@testable import OpenXECore

/// Spec §6 / §9.1. The gate must explain the Intel-engine-on-Apple-Silicon
/// problem in plain language BEFORE any Wine subprocess runs, and must not
/// assume Apple's installer succeeds.
final class RosettaGateTests: XCTestCase {

    /// Scripted answers for `canRunX86_64`, so "install then re-test" is testable.
    private final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [Bool]
        private(set) var calls = 0
        init(_ answers: [Bool]) { self.answers = answers }
        func next() -> Bool {
            lock.lock(); defer { lock.unlock() }
            calls += 1
            return answers.count > 1 ? answers.removeFirst() : (answers.first ?? false)
        }
    }

    /// Reaching this means a test is talking to something it did not inject —
    /// which, for an installer, means the real system installer.
    private static let forbidden: @Sendable () -> (status: Int32, output: String) = {
        XCTFail("a test invoked an installer it did not inject")
        return (-1, "forbidden")
    }

    private static let jargon = ["EBADARCH", "posix_spawn", "Errno", "wineboot",
                                 "wineserver", "Wine", "prefix", "exec format"]

    private func assertPlainLanguage(_ text: String, _ label: String,
                                     file: StaticString = #filePath, line: UInt = #line) {
        for term in Self.jargon {
            XCTAssertFalse(text.contains(term),
                           "\(label) leaks implementation jargon '\(term)': \(text)",
                           file: file, line: line)
        }
        XCTAssertFalse(text.isEmpty, "\(label) is empty", file: file, line: line)
    }

    func testSatisfiedWhenX86BinariesCanRun() {
        let gate = RosettaGate(probe: { true }, installer: { (0, "") }, authorizedInstaller: Self.forbidden, offersInstall: true)
        guard case .satisfied = gate.check() else {
            return XCTFail("expected .satisfied")
        }
    }

    func testMissingProducesRosettaMissingFailureInPlainLanguage() {
        let gate = RosettaGate(probe: { false }, installer: { (0, "") }, authorizedInstaller: Self.forbidden, offersInstall: true)
        guard case .missing(let failure) = gate.check() else {
            return XCTFail("expected .missing")
        }
        XCTAssertEqual(failure.kind, .rosettaMissing)
        XCTAssertEqual(failure.stage, .preflight)
        XCTAssertTrue(failure.isRetryable)
        assertPlainLanguage(failure.userMessage, "userMessage")
        assertPlainLanguage(failure.suggestedAction, "suggestedAction")
        XCTAssertFalse(failure.technicalDetail.isEmpty)
    }

    /// The explanation must be identical whether or not remediation is offered —
    /// only the suggested action changes. Detection and explanation stay correct
    /// even if `softwareupdate --install-rosetta` stops working.
    func testExplanationSurvivesTheInstallOfferBeingDisabled() {
        let offered = RosettaGate(probe: { false }, installer: { (0, "") }, authorizedInstaller: Self.forbidden, offersInstall: true)
        let withheld = RosettaGate(probe: { false }, installer: { (0, "") }, authorizedInstaller: Self.forbidden, offersInstall: false)
        guard case .missing(let a) = offered.check(),
              case .missing(let b) = withheld.check() else {
            return XCTFail("expected .missing from both")
        }
        XCTAssertEqual(a.userMessage, b.userMessage)
        XCTAssertNotEqual(a.suggestedAction, b.suggestedAction)
        assertPlainLanguage(b.suggestedAction, "withheld suggestedAction")
        XCTAssertFalse(withheld.offersInstall)
    }

    /// The offer is switchable with no rebuild, so it can be turned off if
    /// Rosetta turns out to be unavailable on newer hardware.
    func testInstallOfferIsRuntimeSwitchable() {
        let suite = UserDefaults(suiteName: "dev.openxe.tests.rosetta")!
        suite.removePersistentDomain(forName: "dev.openxe.tests.rosetta")
        XCTAssertTrue(RosettaGate.installOfferEnabled(in: suite), "default is to offer")
        suite.set(false, forKey: RosettaGate.installOfferDefaultsKey)
        XCTAssertFalse(RosettaGate.installOfferEnabled(in: suite))
        suite.removePersistentDomain(forName: "dev.openxe.tests.rosetta")
    }

    func testInstallSucceedsOnlyWhenTheMachineAgrees() {
        let probe = Probe([false, true])
        let gate = RosettaGate(probe: { probe.next() }, installer: { (0, "installed") },
                               authorizedInstaller: Self.forbidden, offersInstall: true)
        guard case .missing = gate.check() else { return XCTFail("expected .missing") }
        guard case .installed = gate.attemptInstall() else {
            return XCTFail("expected .installed")
        }
    }

    /// A zero exit status is not evidence: the gate re-tests the machine. This is
    /// the path taken if Apple's installer reports success but Rosetta is not
    /// actually available.
    func testZeroExitStatusIsNotTrustedWithoutRetesting() {
        let probe = Probe([false])
        // An unclassifiable failure escalates to an authorized retry, so this
        // one is injected too — it must never be the real installer.
        let gate = RosettaGate(probe: { probe.next() }, installer: { (0, "No updates available") },
                               authorizedInstaller: { (0, "No updates available") },
                               offersInstall: true)
        guard case .missing = gate.check() else { return XCTFail("expected .missing") }
        guard case .failed(let failure) = gate.attemptInstall() else {
            return XCTFail("expected .failed when the machine still cannot run x86_64")
        }
        XCTAssertEqual(failure.kind, .rosettaMissing)
        XCTAssertTrue(failure.isRetryable)
        assertPlainLanguage(failure.userMessage, "userMessage")
        assertPlainLanguage(failure.suggestedAction, "suggestedAction")
        XCTAssertTrue(failure.technicalDetail.contains("No updates available"),
                      "installer output must be retained for the log: \(failure.technicalDetail)")
        XCTAssertGreaterThan(probe.calls, 1, "gate must re-test after installing")
    }

    func testInstallerFailureIsReportedWithItsOutput() {
        let gate = RosettaGate(probe: { false },
                               installer: { (1, "softwareupdate: command not found") },
                               authorizedInstaller: { (1, "osascript: command not found") },
                               offersInstall: true)
        guard case .failed(let failure) = gate.attemptInstall() else {
            return XCTFail("expected .failed")
        }
        XCTAssertTrue(failure.technicalDetail.contains("softwareupdate: command not found"))
        XCTAssertTrue(failure.technicalDetail.contains("1"), "exit status should be recorded")
        assertPlainLanguage(failure.userMessage, "userMessage")
    }
}
