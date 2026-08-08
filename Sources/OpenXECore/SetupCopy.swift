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
}
