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

    // MARK: removal (spec 2026-08-09 §6)
    //
    // Deliberately worded to be unmistakable against "Reset Environment…".
    // Reset keeps OpenXE working; this ends it. Every string here avoids
    // filesystem paths, shell commands and the word "uninstall", which
    // non-technical users read as jargon.

    public static let cleanupMenuTitle = "Remove OpenXE from this Mac…"
    public static let cleanupWindowTitle = "Remove OpenXE"

    public static let cleanupHeadline = "Remove OpenXE from this Mac"

    public static let cleanupExplanation =
        "This removes the Windows environment OpenXE created, the programs installed "
        + "inside it, and the settings OpenXE saved. It cannot be undone."

    /// The distinction from Reset, said once, plainly.
    public static let cleanupNotAReset =
        "This is not the same as Reset Environment. Reset rebuilds the Windows "
        + "environment so you can keep using OpenXE; this removes it for good."

    public static let cleanupItemsHeading = "What will be removed"
    public static let cleanupItemSupport = "The Windows environment and everything installed in it"
    public static let cleanupItemLogs = "OpenXE's activity logs"
    public static let cleanupItemPreferences = "OpenXE's own settings"
    public static let cleanupItemCaches = "Temporary files OpenXE downloaded"
    public static let cleanupItemWindowState = "Saved window positions"

    public static func cleanupItemLauncher(_ name: String) -> String {
        "The \"\(name)\" shortcut OpenXE created"
    }

    /// The keep/delete choice. Off by default: the safe answer is the default.
    public static let cleanupKeepDataCheckbox =
        "Also delete my New World Scheduler information"

    public static let cleanupKeepDataDefaultNote =
        "Your congregation information, schedules and licence will be copied to your "
        + "Documents folder before anything is removed."

    public static let cleanupDeleteDataWarning =
        "Your congregation information, schedules and licence will be permanently "
        + "deleted. Nothing will be copied out."

    public static let cleanupConfirmButton = "Remove OpenXE"
    public static let cleanupCancelButton = "Cancel"
    public static let cleanupWorking = "Removing OpenXE…"

    /// Sizes are stated with the same vocabulary everywhere.
    public static func cleanupSpaceSummary(bytes: Int64) -> String {
        "This frees about \(humanBytes(bytes)) of space."
    }

    public static func cleanupDataSummary(bytes: Int64) -> String {
        "Your New World Scheduler information is about \(humanBytes(bytes))."
    }

    public static func cleanupSavedTo(_ folderName: String) -> String {
        "Your New World Scheduler information was saved to \"\(folderName)\" in your "
        + "Documents folder."
    }

    public static let cleanupShowSavedButton = "Show in Finder"

    public static func cleanupDone(reclaimed: Int64) -> String {
        "OpenXE has been removed. About \(humanBytes(reclaimed)) was freed."
    }

    /// The honest last step. A running app cannot delete its own bundle, and
    /// pretending otherwise leaves the user with a mystery icon.
    public static let cleanupDragToTrash =
        "One last step: OpenXE itself is still in your Applications folder. Quit OpenXE, "
        + "then drag it to the Trash to finish."

    public static let cleanupQuitButton = "Quit OpenXE"

    public static let cleanupPreserveFailed =
        "OpenXE could not save a copy of your New World Scheduler information, so it "
        + "stopped and removed nothing."

    public static func cleanupPartial(_ problems: [String]) -> String {
        "OpenXE removed what it could. These were left behind:\n• "
            + problems.joined(separator: "\n• ")
    }

    /// One plain-language line per preserved item, keyed on the name as it
    /// appears on disk. Anything in `CleanupPlanner.preserveNames` without an
    /// entry here would land in the user's Documents folder as an unexplained
    /// folder, so the pairing is covered by a test rather than left to care.
    static let cleanupSavedItemDescriptions: [String: String] = [
        "MyData": "your congregation information and schedules",
        "Backups": "New World Scheduler's own backup files",
        "Settings1.json": "your New World Scheduler settings",
        "RegistrationKey.json": "your New World Scheduler licence",
        "DataTimestamps.json": "a small file New World Scheduler keeps alongside MyData",
        "Attachments": "files you attached to records, if you added any",
        "MyTemplates": "the printing templates and categories you set up",
    ]

    /// Written into the saved folder. This is the one place the DPAPI caveat is
    /// recorded for whoever finds the folder later — see the 2026-08-09 spec
    /// §4.3: the licence file only decrypts under the same Windows user name.
    public static func cleanupSavedReadme(items: [String], registryValue: String?) -> String {
        var text = """
        New World Scheduler information saved by OpenXE
        ===============================================

        This folder was created when OpenXE was removed from this Mac. It holds the
        New World Scheduler information that was stored inside OpenXE's Windows
        environment, which has now been deleted.

        What is here:

        """
        let width = items.map(\.count).max() ?? 0
        for item in items {
            let name = item.padding(toLength: max(width, item.count), withPad: " ", startingAt: 0)
            if let detail = cleanupSavedItemDescriptions[item] {
                text += "  \(name) - \(detail)\n"
            } else {
                text += "  \(item)\n"
            }
        }
        if let registryValue {
            text += """

            Windows Registry Setting.reg
                A setting the New World Scheduler installer put into the Windows
                environment. Nothing else records it, so it is saved here too:

                    \(NWSRegistryCapture.valueName) = \(registryValue)

            """
        }
        text += """

        Some of these folders may be empty. That is normal — it means you had not
        put anything in them yet. They are kept anyway so that nothing is lost.

        If you install OpenXE and New World Scheduler again on this Mac, copying
        everything in this folder back into New World Scheduler's data folder
        restores your information.

        One thing to know about the settings and licence files: they were encrypted
        by the Windows environment using your Mac account name. They will work again
        on this Mac under the same account. If they are ever opened under a different
        account name, they cannot be decrypted and New World Scheduler will need to be
        registered again. Your congregation information in MyData is not affected by
        this — it is not encrypted.

        """
        return text
    }

    /// Shared size vocabulary. MB below a gigabyte, one decimal above.
    public static func humanBytes(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb < 1 { return "less than 1 MB" }
        if mb < 1024 { return String(format: "%.0f MB", mb) }
        return String(format: "%.1f GB", mb / 1024)
    }
}
