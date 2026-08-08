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

    /// Why an install attempt did not leave the machine able to run x86_64.
    /// Each maps to its own plain-language copy and its own way forward — a
    /// single "it failed" message is a dead end for a non-technical user.
    public enum InstallFailureReason: String, Sendable {
        /// The user dismissed the macOS password panel. Nothing was installed.
        case authorizationDeclined
        /// Apple's servers could not be reached.
        case network
        /// This Mac is not offered Rosetta at all. The one honest dead end.
        case unavailable
        /// Anything else: ran, claimed something, changed nothing.
        case didNotComplete
    }

    public static let installOfferDefaultsKey = "OpenXEOfferRosettaInstall"

    /// Defaults to offering. Absent key means "offer"; only an explicit `false`
    /// withholds it.
    public static func installOfferEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: installOfferDefaultsKey) as? Bool ?? true
    }

    private let probe: @Sendable () -> Bool
    private let installer: @Sendable () -> (status: Int32, output: String)
    private let authorizedInstaller: @Sendable () -> (status: Int32, output: String)

    /// Whether the UI should offer to run Apple's installer at all.
    public let offersInstall: Bool

    /// Every dependency is required. There is deliberately no defaulted
    /// initialiser: when the installers had live defaults, adding a third
    /// dependency silently re-pointed every existing test at the real
    /// `softwareupdate`, which reinstalled Apple's Rosetta package as root and
    /// raised a password panel on the developer's Mac. A test cannot forget to
    /// inject something it is forced to pass.
    public init(probe: @escaping @Sendable () -> Bool,
                installer: @escaping @Sendable () -> (status: Int32, output: String),
                authorizedInstaller: @escaping @Sendable () -> (status: Int32, output: String),
                offersInstall: Bool) {
        self.probe = probe
        self.installer = installer
        self.authorizedInstaller = authorizedInstaller
        self.offersInstall = offersInstall
    }

    /// The production wiring: the real machine, the real installers. The single
    /// place in the codebase that touches them.
    public static func live(offersInstall: Bool = RosettaGate.installOfferEnabled())
        -> RosettaGate {
        RosettaGate(probe: { RosettaCheck.canRunX86_64 },
                    installer: { RosettaCheck.install() },
                    authorizedInstaller: { RosettaCheck.installWithAdministratorAuthorization() },
                    offersInstall: offersInstall)
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
    /// installer runs — minutes, potentially — so call it off the main thread
    /// and render `onStatus` somewhere the user can see it.
    ///
    /// Two attempts, in this order:
    ///
    /// 1. The direct `softwareupdate` run. If the user is an administrator and
    ///    macOS is willing, this needs no password at all.
    /// 2. Only if that fails for a reason a password could fix, an explicitly
    ///    authorized run, which raises the standard macOS password panel.
    ///
    /// Trade-off: a failure we cannot classify escalates to a password panel
    /// that may not have helped. That is one dismissible system dialog against
    /// the alternative — a standard (non-admin) user hitting a refusal with no
    /// way past it and no shell to reach for.
    ///
    /// Neither attempt's exit status is trusted; only the machine's own answer
    /// counts, so a partial or falsely-successful install is caught here rather
    /// than at the first Wine subprocess.
    public func attemptInstall(onStatus: @Sendable (String) -> Void = { _ in })
        -> InstallOutcome {
        onStatus(SetupCopy.rosettaInstalling)
        let direct = installer()
        guard !probe() else { return .installed }

        var transcript = "direct install exited \(direct.status): "
            + String(direct.output.suffix(500))

        let firstReason = Self.classify(status: direct.status, output: direct.output)
        guard Self.escalatesToAdministrator(firstReason) else {
            return .failed(Self.failure(for: firstReason, technicalDetail: transcript))
        }

        onStatus(SetupCopy.rosettaAwaitingAuthorization)
        let authorized = authorizedInstaller()
        guard !probe() else { return .installed }
        transcript += "\nauthorized install exited \(authorized.status): "
            + String(authorized.output.suffix(500))

        let reason = Self.classify(status: authorized.status, output: authorized.output)
        return .failed(Self.failure(for: reason, technicalDetail: transcript))
    }

    /// Reads Apple's own tool output. Matching is deliberately narrow: a broad
    /// "not available" would swallow the ordinary "No updates are available"
    /// case, which IS worth retrying.
    static func classify(status: Int32, output: String) -> InstallFailureReason {
        let text = output.lowercased()
        if status == -128 || text.contains("user canceled") || text.contains("user cancelled")
            || text.contains("(-128)") {
            return .authorizationDeclined
        }
        if text.contains("rosetta 2 update is not available")
            || text.contains("rosetta 2 is not available")
            || text.contains("rosetta is not available") {
            return .unavailable
        }
        for marker in ["internet connection", "offline", "network is", "network connection",
                       "could not connect", "unable to reach", "nsurlerror", "timed out",
                       "no internet"] where text.contains(marker) {
            return .network
        }
        return .didNotComplete
    }

    /// A password cannot conjure a network or a product Apple does not offer,
    /// and a user who just cancelled does not want to be asked twice.
    static func escalatesToAdministrator(_ reason: InstallFailureReason) -> Bool {
        reason == .didNotComplete
    }

    static func failure(for reason: InstallFailureReason,
                        technicalDetail: String) -> SetupFailure {
        let message: String, action: String, kind: SetupFailure.Kind, retryable: Bool
        switch reason {
        case .authorizationDeclined:
            message = SetupCopy.rosettaAuthorizationDeclined
            action = SetupCopy.rosettaAuthorizationDeclinedAdvice
            kind = .rosettaMissing
            retryable = true
        case .network:
            message = SetupCopy.rosettaNetworkFailure
            action = SetupCopy.rosettaNetworkFailureAdvice
            kind = .network
            retryable = true
        case .unavailable:
            message = SetupCopy.rosettaUnavailable
            action = SetupCopy.rosettaUnavailableAdvice
            kind = .rosettaMissing
            retryable = false
        case .didNotComplete:
            message = SetupCopy.rosettaInstallDidNotComplete
            action = SetupCopy.rosettaInstallRetryAdvice
            kind = .rosettaMissing
            retryable = true
        }
        return SetupFailure(stage: .preflight, kind: kind, userMessage: message,
                            suggestedAction: action, technicalDetail: technicalDetail,
                            isRetryable: retryable)
    }
}
