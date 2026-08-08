import Foundation

/// The preflight gate for the Intel-only Windows environment on Apple silicon
/// (spec §6, §9.1).
///
/// Detection and explanation are kept strictly separate from remediation:
///
/// - **Detection** (`RosettaCheck.canRunX86_64`) is a direct experiment — run an
///   x86_64 binary and see. It is correct regardless of macOS version.
/// - **Explanation** is `SetupCopy` text plus a `SetupFailure(kind: .rosettaMissing)`,
///   so the user never sees the raw `EBADARCH` that the first Wine subprocess
///   would otherwise throw.
/// - **Remediation** is the only part that assumes anything about Apple. Whether
///   `softwareupdate --install-rosetta` still works on the newest Macs is an open
///   question, so the offer can be switched off with no rebuild:
///   `defaults write dev.openxe.OpenXE OpenXEOfferRosettaInstall -bool false`
///   and `attemptInstall()` never trusts the installer's exit status — it
///   re-tests the machine and reports an actionable failure if nothing changed.
public struct RosettaGate: Sendable {

    public enum Outcome: Sendable {
        case satisfied
        case missing(SetupFailure)
    }

    public enum InstallOutcome: Sendable {
        case installed
        case failed(SetupFailure)
    }

    public static let installOfferDefaultsKey = "OpenXEOfferRosettaInstall"

    /// Defaults to offering. Absent key means "offer"; only an explicit `false`
    /// withholds it.
    public static func installOfferEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: installOfferDefaultsKey) as? Bool ?? true
    }

    private let probe: @Sendable () -> Bool
    private let installer: @Sendable () -> (status: Int32, output: String)

    /// Whether the UI should offer to run Apple's installer at all.
    public let offersInstall: Bool

    public init(probe: @escaping @Sendable () -> Bool = { RosettaCheck.canRunX86_64 },
                installer: @escaping @Sendable () -> (status: Int32, output: String)
                    = { RosettaCheck.install() },
                offersInstall: Bool = RosettaGate.installOfferEnabled()) {
        self.probe = probe
        self.installer = installer
        self.offersInstall = offersInstall
    }

    /// Runs the x86_64 experiment. Blocking (a few milliseconds normally); call
    /// it off the main thread.
    public func check() -> Outcome {
        guard !probe() else { return .satisfied }
        return .missing(SetupFailure(
            stage: .preflight,
            kind: .rosettaMissing,
            userMessage: SetupCopy.rosettaExplanation,
            suggestedAction: offersInstall ? SetupCopy.rosettaInstallOffer
                                           : SetupCopy.rosettaInstallManually,
            technicalDetail: "x86_64 translation unavailable: /usr/bin/arch -x86_64 failed",
            isRetryable: true))
    }

    /// Asks macOS to install Rosetta, then re-tests. Blocking for as long as the
    /// installer runs; call it off the main thread.
    public func attemptInstall() -> InstallOutcome {
        let result = installer()
        // Exit status is not evidence. Only the machine's own answer counts.
        guard !probe() else { return .installed }
        return .failed(SetupFailure(
            stage: .preflight,
            kind: .rosettaMissing,
            userMessage: SetupCopy.rosettaInstallDidNotComplete,
            suggestedAction: SetupCopy.rosettaInstallRetryAdvice,
            technicalDetail: "softwareupdate --install-rosetta exited \(result.status): "
                + String(result.output.suffix(500)),
            isRetryable: true))
    }
}
