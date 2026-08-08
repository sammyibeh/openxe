import Foundation

/// Every user-facing string the setup flow shows. Single source of truth:
/// three separate copies of the engine size had drifted to "1.7 GB",
/// "~200 MB" and "~1 GB" against a measured 177 MB (spec §3).
public enum SetupCopy {
    /// Exact size of the pinned engine asset, verified against the live
    /// release Content-Length.
    public static let engineDownloadBytes: Int64 = 185_303_032

    /// The canonical phrasing. Used by the wizard, the launch-path progress
    /// window, and anywhere else the download is described.
    public static let engineSizeSummary =
        "a one-time download of about 177 MB, which expands to about 700 MB on your Mac"

    public static let preparingEnvironment = "Preparing the Windows environment"
    public static let takingLongerThanUsual =
        "This is taking longer than usual. It may still be working."

    // MARK: Rosetta gate (spec §6)
    //
    // The Windows environment is an Intel build, so on an Apple-silicon Mac
    // nothing works without Rosetta. Wording here explains the situation; it
    // deliberately never promises that Apple's installer will succeed, because
    // whether `softwareupdate --install-rosetta` still works on the newest Macs
    // is unsettled. If it stops working, only `rosettaInstallOffer` becomes
    // wrong, and it is switched off at runtime — see RosettaGate.

    public static let rosettaTitle = "This Mac needs one more Apple component"

    public static let rosettaExplanation =
        "OpenXE runs New World Scheduler inside a small Windows environment that was built "
        + "for Intel Macs. To use it on a Mac with an Apple chip, macOS first needs Apple's "
        + "Rosetta component installed."

    /// Shown only while the install offer is enabled.
    public static let rosettaInstallOffer =
        "OpenXE can ask macOS to install Rosetta now. It is an official Apple download and "
        + "usually takes a minute or two."

    /// Shown when the offer is switched off, or as the honest fallback.
    public static let rosettaInstallManually =
        "Rosetta has to be installed by macOS before OpenXE can continue. If this Mac does "
        + "not offer Rosetta, OpenXE cannot run New World Scheduler on it."

    public static let rosettaInstallButton = "Install Rosetta"
    public static let rosettaNotNowButton = "Not Now"
    public static let rosettaDismissButton = "OK"

    /// Apple began showing its own "Rosetta is being discontinued" notice in
    /// macOS 26.4, on every translated launch. Unexplained, a user reads that as
    /// OpenXE being broken and stops. Named here, before macOS says it.
    public static let rosettaDeprecationNote =
        "macOS may show its own notice saying Rosetta is being discontinued in a future "
        + "version of macOS. That is Apple's message, not a problem with OpenXE, and New "
        + "World Scheduler will keep working for now."

    public static let rosettaChecking = "Checking what this Mac needs…"
    public static let rosettaInstalling =
        "Asking macOS to install Rosetta… this can take a few minutes."

    /// Elapsed time turns a frozen-looking window into visible progress.
    public static func rosettaInstalling(elapsed: TimeInterval) -> String {
        guard elapsed >= 1 else { return rosettaInstalling }
        let total = Int(elapsed)
        let clock = String(format: "%d:%02d", total / 60, total % 60)
        return "Asking macOS to install Rosetta… this can take a few minutes. (\(clock))"
    }

    // MARK: administrator authorization
    //
    // Installing Rosetta authorizes through macOS's security system and can be
    // refused outright for a standard (non-administrator) user. When that
    // happens OpenXE asks macOS for authorization explicitly, which puts up the
    // familiar password panel. This is the prompt text shown inside it.

    public static let rosettaAuthorizationPrompt =
        "OpenXE needs your permission for macOS to install Apple's Rosetta component."

    public static let rosettaAwaitingAuthorization =
        "Waiting for your permission… macOS will ask for your password."

    public static let rosettaAuthorizationDeclined =
        "OpenXE did not get permission to install Rosetta, so it stopped and changed nothing."

    public static let rosettaAuthorizationDeclinedAdvice =
        "Nothing was installed and nothing was harmed. Press the button again and enter the "
        + "password you use to unlock this Mac when macOS asks."

    public static let rosettaNetworkFailure =
        "macOS could not download Rosetta from Apple."

    public static let rosettaNetworkFailureAdvice =
        "Check that this Mac is connected to the internet, then try again. If you are on "
        + "Wi-Fi, reconnecting often fixes it."

    public static let rosettaUnavailable =
        "This Mac cannot install Rosetta — Apple is not offering it here."

    public static let rosettaUnavailableAdvice =
        "Without Rosetta, OpenXE cannot run New World Scheduler on this Mac. Nothing was "
        + "installed and nothing was changed."

    public static let rosettaInstallDidNotComplete =
        "macOS did not finish installing Rosetta, so OpenXE cannot continue."

    public static let rosettaInstallRetryAdvice =
        "Nothing was left half-installed. You can try again. If this Mac no longer offers "
        + "Rosetta, OpenXE will not be able to run New World Scheduler on it."

    public static let rosettaBlockedStatus =
        "OpenXE can't set up the Windows environment until Rosetta is installed."
}
