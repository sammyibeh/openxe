import XCTest
@testable import OpenXECore

/// Spec §6, §9.1. Remediation is judged against one user: a person who will
/// never open Terminal, cannot read a shell error, and needs a way forward from
/// every failure — including one they caused by clicking Cancel.
final class RosettaRemediationTests: XCTestCase {

    /// Recorded installer calls, so escalation order is assertable.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var log: [String] = []
        func record(_ step: String) { lock.lock(); log.append(step); lock.unlock() }
        var calls: [String] { lock.lock(); defer { lock.unlock() }; return log }
    }

    private final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [Bool]
        init(_ answers: [Bool]) { self.answers = answers }
        func next() -> Bool {
            lock.lock(); defer { lock.unlock() }
            return answers.count > 1 ? answers.removeFirst() : (answers.first ?? false)
        }
    }

    /// Anything that would only make sense to someone at a shell prompt.
    private static let shellLeaks = ["softwareupdate", "osascript", "sudo", "--install",
                                     "--agree-to-license", "/usr/", "do shell script",
                                     "exit status", "stderr"]

    private func assertNoShellCommand(_ text: String, _ label: String,
                                      file: StaticString = #filePath, line: UInt = #line) {
        for leak in Self.shellLeaks {
            XCTAssertFalse(text.lowercased().contains(leak.lowercased()),
                           "\(label) shows the user a shell command ('\(leak)'): \(text)",
                           file: file, line: line)
        }
    }

    // MARK: no password prompt unless one is needed

    func testDirectInstallNeverAsksForAPassword() {
        let recorder = Recorder()
        // attemptInstall probes once per attempt; the direct attempt works.
        let probe = Probe([true])
        let gate = RosettaGate(
            probe: { probe.next() },
            installer: { recorder.record("direct"); return (0, "Install of Rosetta 2 finished") },
            authorizedInstaller: { recorder.record("authorized"); return (0, "") },
            offersInstall: true)
        guard case .installed = gate.attemptInstall() else {
            return XCTFail("expected .installed")
        }
        XCTAssertEqual(recorder.calls, ["direct"],
                       "escalating to an admin password prompt that was not needed is a regression")
    }

    /// `softwareupdate --install-rosetta` authorizes through the Security
    /// framework and can refuse a standard user outright. Without escalation
    /// that is a dead end for someone who cannot open Terminal.
    func testAuthorizationIsEscalatedOnlyAfterTheDirectAttemptFails() {
        let recorder = Recorder()
        // Probed after the direct attempt (still no), then after the authorized
        // one (yes).
        let probe = Probe([false, true])
        let gate = RosettaGate(
            probe: { probe.next() },
            installer: {
                recorder.record("direct")
                return (1, "Error: failed to authorize for installation.")
            },
            authorizedInstaller: {
                recorder.record("authorized")
                return (0, "Install of Rosetta 2 finished successfully")
            },
            offersInstall: true)
        guard case .installed = gate.attemptInstall() else {
            return XCTFail("expected .installed after escalating")
        }
        XCTAssertEqual(recorder.calls, ["direct", "authorized"])
    }

    // MARK: every failure leaves a way forward

    /// Clicking Cancel on the password dialog must not brick the wizard.
    func testDeclinedAuthorizationIsRecoverableAndPlainLanguage() {
        let gate = RosettaGate(
            probe: { false },
            installer: { (1, "Error: failed to authorize for installation.") },
            authorizedInstaller: { (1, "execution error: User canceled. (-128)") },
            offersInstall: true)
        guard case .failed(let failure) = gate.attemptInstall() else {
            return XCTFail("expected .failed")
        }
        XCTAssertEqual(RosettaGate.classify(status: 1,
                                            output: "execution error: User canceled. (-128)"),
                       .authorizationDeclined)
        XCTAssertTrue(failure.isRetryable, "the user must be able to try again")
        assertNoShellCommand(failure.userMessage, "userMessage")
        assertNoShellCommand(failure.suggestedAction, "suggestedAction")
        XCTAssertTrue(failure.userMessage.localizedCaseInsensitiveContains("permission")
                        || failure.userMessage.localizedCaseInsensitiveContains("password"),
                      "declining must be named for what it was: \(failure.userMessage)")
    }

    /// A password prompt cannot fix a missing network, so it must not appear.
    func testNetworkFailureIsExplainedWithoutAPasswordPrompt() {
        let recorder = Recorder()
        let gate = RosettaGate(
            probe: { false },
            installer: {
                recorder.record("direct")
                return (1, "Failed to install Rosetta 2: The Internet connection appears to be offline.")
            },
            authorizedInstaller: { recorder.record("authorized"); return (0, "") },
            offersInstall: true)
        guard case .failed(let failure) = gate.attemptInstall() else {
            return XCTFail("expected .failed")
        }
        XCTAssertEqual(recorder.calls, ["direct"], "no password prompt for a network failure")
        XCTAssertEqual(failure.kind, .network)
        XCTAssertTrue(failure.isRetryable)
        assertNoShellCommand(failure.userMessage, "userMessage")
        XCTAssertTrue(failure.suggestedAction.localizedCaseInsensitiveContains("internet")
                        || failure.suggestedAction.localizedCaseInsensitiveContains("wi-fi"),
                      "tell them what to check: \(failure.suggestedAction)")
    }

    /// The one honest dead end. It must still be stated in plain language, and
    /// must not invite a pointless retry loop.
    func testRosettaUnavailableIsStatedPlainlyAndNotMarkedRetryable() {
        let recorder = Recorder()
        let gate = RosettaGate(
            probe: { false },
            installer: {
                recorder.record("direct")
                return (1, "Rosetta 2 update is not available")
            },
            authorizedInstaller: { recorder.record("authorized"); return (0, "") },
            offersInstall: true)
        guard case .failed(let failure) = gate.attemptInstall() else {
            return XCTFail("expected .failed")
        }
        XCTAssertEqual(recorder.calls, ["direct"])
        XCTAssertFalse(failure.isRetryable, "retrying cannot make Rosetta appear")
        assertNoShellCommand(failure.userMessage, "userMessage")
    }

    /// A partial install that reports success is caught by the re-probe; the
    /// user gets a retry rather than a broken environment.
    func testInstallThatChangesNothingIsReportedAsIncompleteAndRetryable() {
        let gate = RosettaGate(
            probe: { false },
            installer: { (0, "No updates are available.") },
            authorizedInstaller: { (0, "No updates are available.") },
            offersInstall: true)
        guard case .failed(let failure) = gate.attemptInstall() else {
            return XCTFail("expected .failed")
        }
        XCTAssertTrue(failure.isRetryable)
        assertNoShellCommand(failure.userMessage, "userMessage")
        assertNoShellCommand(failure.suggestedAction, "suggestedAction")
    }

    // MARK: the user can see it working

    /// The install is minutes, not milliseconds. Silence reads as a hang.
    func testProgressIsReportedBeforeAndDuringEachInstallAttempt() {
        let recorder = Recorder()
        let gate = RosettaGate(
            probe: { false },
            installer: { (1, "Error: failed to authorize for installation.") },
            authorizedInstaller: { (1, "execution error: User canceled. (-128)") },
            offersInstall: true)
        _ = gate.attemptInstall(onStatus: { recorder.record($0.statusMessage) })
        XCTAssertGreaterThanOrEqual(recorder.calls.count, 2,
                                    "the UI needs a status for the install and for the password step")
        for message in recorder.calls {
            assertNoShellCommand(message, "status message")
            XCTAssertFalse(message.isEmpty)
        }
    }

    // MARK: copy

    /// macOS 26.4+ shows Apple's own "Rosetta is being discontinued" warning on
    /// every translated launch. Unexplained, it reads as OpenXE breaking.
    func testCopyPreEmptsApplesDeprecationWarning() {
        let combined = SetupCopy.rosettaExplanation + SetupCopy.rosettaDeprecationNote
        XCTAssertTrue(combined.localizedCaseInsensitiveContains("discontinu")
                        || combined.localizedCaseInsensitiveContains("retir"),
                      "the copy must name Apple's warning before macOS shows it")
        XCTAssertTrue(SetupCopy.rosettaDeprecationNote.localizedCaseInsensitiveContains("openxe")
                        || SetupCopy.rosettaDeprecationNote
                            .localizedCaseInsensitiveContains("keep working"),
                      "and reassure that OpenXE is not the thing that is broken")
        assertNoShellCommand(SetupCopy.rosettaDeprecationNote, "rosettaDeprecationNote")
    }

    /// A blanket sweep: no user-facing Rosetta string may contain a command.
    func testNoUserFacingRosettaCopyContainsAShellCommand() {
        let strings: [(String, String)] = [
            ("rosettaTitle", SetupCopy.rosettaTitle),
            ("rosettaExplanation", SetupCopy.rosettaExplanation),
            ("rosettaDeprecationNote", SetupCopy.rosettaDeprecationNote),
            ("rosettaInstallOffer", SetupCopy.rosettaInstallOffer),
            ("rosettaInstallManually", SetupCopy.rosettaInstallManually),
            ("rosettaInstallButton", SetupCopy.rosettaInstallButton),
            ("rosettaNotNowButton", SetupCopy.rosettaNotNowButton),
            ("rosettaDismissButton", SetupCopy.rosettaDismissButton),
            ("rosettaChecking", SetupCopy.rosettaChecking),
            ("rosettaInstalling", SetupCopy.rosettaInstalling),
            ("rosettaAuthorizationPrompt", SetupCopy.rosettaAuthorizationPrompt),
            ("rosettaAwaitingAuthorization", SetupCopy.rosettaAwaitingAuthorization),
            ("rosettaAuthorizationDeclined", SetupCopy.rosettaAuthorizationDeclined),
            ("rosettaAuthorizationDeclinedAdvice", SetupCopy.rosettaAuthorizationDeclinedAdvice),
            ("rosettaNetworkFailure", SetupCopy.rosettaNetworkFailure),
            ("rosettaNetworkFailureAdvice", SetupCopy.rosettaNetworkFailureAdvice),
            ("rosettaUnavailable", SetupCopy.rosettaUnavailable),
            ("rosettaUnavailableAdvice", SetupCopy.rosettaUnavailableAdvice),
            ("rosettaInstallDidNotComplete", SetupCopy.rosettaInstallDidNotComplete),
            ("rosettaInstallRetryAdvice", SetupCopy.rosettaInstallRetryAdvice),
            ("rosettaBlockedStatus", SetupCopy.rosettaBlockedStatus),
        ]
        for (label, text) in strings {
            XCTAssertFalse(text.isEmpty, "\(label) is empty")
            assertNoShellCommand(text, label)
        }
    }

    /// The command belongs in the log, not the window.
    func testTechnicalDetailKeepsTheCommandAndOutputForTheLog() {
        let gate = RosettaGate(
            probe: { false },
            installer: { (1, "Error: failed to authorize for installation.") },
            authorizedInstaller: { (1, "execution error: User canceled. (-128)") },
            offersInstall: true)
        guard case .failed(let failure) = gate.attemptInstall() else {
            return XCTFail("expected .failed")
        }
        XCTAssertTrue(failure.technicalDetail.contains("User canceled"),
                      "raw output must survive for diagnosis: \(failure.technicalDetail)")
        XCTAssertTrue(failure.technicalDetail.contains("failed to authorize"),
                      "the first attempt's output must survive too: \(failure.technicalDetail)")
    }

    // MARK: elapsed-time formatting for the "it is working" status

    func testElapsedStatusReadsAsProgressNotAsAHang() {
        XCTAssertEqual(SetupCopy.rosettaInstalling(elapsed: 0), SetupCopy.rosettaInstalling)
        let later = SetupCopy.rosettaInstalling(elapsed: 95)
        XCTAssertNotEqual(later, SetupCopy.rosettaInstalling)
        XCTAssertTrue(later.contains("1:35"), "elapsed time should be visible: \(later)")
        assertNoShellCommand(later, "elapsed status")
    }
}
