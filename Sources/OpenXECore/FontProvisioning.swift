import Foundation

/// Reusable font provisioning applied as PRE-SETUP the first time any app runs
/// in the prefix (called from `PrefixManager.ensurePrefix`). Spec §4.2 step 3a.
///
/// Goal: a font an app requests that we cannot supply NEVER causes a crash — it
/// degrades to a close available font. Generalizes the earlier NWS-specific fix.
///
/// **Base fonts layer — provided by macOS, not bundled (lean decision).** The
/// Wine Mac driver auto-registers macOS's own copies of the Microsoft "core"
/// fonts into every prefix: Arial, Times New Roman, Courier New, Verdana,
/// Georgia, Trebuchet MS, Comic Sans MS, Impact, Tahoma, Webdings, Wingdings —
/// they live in `/System/Library/Fonts/Supplemental` and appear in the prefix
/// registry as `Z:\System\Library\Fonts\Supplemental\*.ttf` (verified 2026-07-08:
/// 394 font entries registered, every corefont among them). Bundling or
/// winetricks-fetching corefonts would therefore duplicate ~10 MB already
/// present and add a dependency OpenXE does not have (no winetricks on the host).
/// So OpenXE installs exactly ONE font file — the bundled `FontAwesome.ttf`
/// (OFL-1.1), an icon font macOS does not ship and wine-mono fails to load from
/// app-embedded resources — and otherwise relies on the Mac driver's corefonts.
///
/// **Fallback substitution layer — the generalization.** Every common Windows
/// font family that macOS does NOT provide (Segoe UI and its weight/symbol
/// variants, the Office ClearType families Calibri/Cambria/Consolas/etc., the
/// Win8+ icon fonts) is mapped to a close face that the Mac driver DOES
/// register, in BOTH the GDI `FontSubstitutes` table (which wine-mono reads for
/// WPF) and wine's own `Software\Wine\Fonts\Replacements`. This is what keeps a
/// missing default font from NULL-dereferencing wine-mono's WPF text layout
/// (the crash class fixed for NWS, generalized here to any app).
public enum FontProvisioning {

    /// The one font file OpenXE installs into the prefix (bundled resource name,
    /// without extension). macOS does not ship an icon font and wine-mono cannot
    /// load app-embedded FontAwesome, so a system-installed copy resolves it by
    /// family-name fallback.
    public static let bundledFontResource = "FontAwesome"
    public static let bundledFontFileName = "FontAwesome.ttf"

    /// Broad fallback substitutions: `requested family -> close face macOS
    /// registers`. Targets (Arial, Verdana, Georgia, Courier New, Webdings,
    /// Tahoma, Times New Roman) are all macOS Supplemental fonts the Mac driver
    /// auto-registers, so every target always resolves. Applied to both the GDI
    /// FontSubstitutes table and wine's Replacements table.
    public static let substitutions: [(from: String, to: String)] = [
        // WPF / shell default UI family + its weight & symbol variants. macOS
        // has no "Segoe UI"; without a substitute wine-mono NULL-derefs.
        ("Segoe UI", "Verdana"),
        ("Segoe UI Semibold", "Verdana"),
        ("Segoe UI Semilight", "Verdana"),
        ("Segoe UI Light", "Verdana"),
        ("Segoe UI Black", "Verdana"),
        ("Segoe UI Historic", "Verdana"),
        ("Segoe UI Variable", "Verdana"),
        ("Segoe UI Symbol", "Arial"),
        ("Segoe UI Emoji", "Arial"),
        ("Segoe UI Adjusted", "Verdana"),

        // Office / ClearType families — none exist on macOS.
        ("Calibri", "Arial"),
        ("Calibri Light", "Arial"),
        ("Cambria", "Georgia"),
        ("Cambria Math", "Georgia"),
        ("Candara", "Verdana"),
        ("Consolas", "Courier New"),
        ("Constantia", "Georgia"),
        ("Corbel", "Verdana"),
        ("Sitka", "Georgia"),
        ("Selawik", "Verdana"),

        // Icon / symbol fonts → an available symbol face (Webdings). Broad
        // catch so an app requesting a Win8+ icon font degrades, not crashes.
        ("Segoe MDL2 Assets", "Webdings"),
        ("Segoe Fluent Icons", "Webdings"),
        ("Marlett", "Webdings"),

        // Common legacy UI faces some apps request by name.
        ("MS UI Gothic", "Tahoma"),
        ("Microsoft YaHei", "Verdana"),
        ("Microsoft Sans Serif", "Arial"),
        ("Franklin Gothic", "Arial"),
        ("Bahnschrift", "Verdana"),
    ]

    /// Spec §5.3. When true, the 28x2+1 font registry values are written by a
    /// single `wine regedit` import instead of 57 spawned `wine reg add`
    /// processes — measured 24.38 s -> 1.54 s.
    ///
    /// The per-write path is retained as a fallback. If the import ever proves
    /// unreliable on a machine we cannot inspect, flip this to false to restore
    /// the proven behaviour with no code revert.
    ///
    /// REMOVAL CONDITION (spec §5.3) — this flag is not permanent. Delete it
    /// and `provisionFontsPerWrite` in one commit once BOTH have happened:
    ///   (a) one cold-machine run (spec §13.4) with the batched path, and
    ///   (b) one real end-to-end install with the batched path.
    /// `scripts/verify-font-batching.sh` stays afterwards as the regression
    /// guard. A fallback that is never exercised is not a safety net — it is a
    /// second code path that rots.
    public static let useBatchedImport = true

    /// The `.reg` file body, generated from `substitutions` so that table stays
    /// the single source of truth.
    ///
    /// REGEDIT4 / ASCII rather than "Windows Registry Editor Version 5.00":
    /// that format expects UTF-16LE and buys nothing here, because every family
    /// name above is ASCII. CRLF line endings are what the format specifies.
    public static func regFileContents() -> String {
        var lines: [String] = ["REGEDIT4", ""]

        lines.append(#"[HKEY_LOCAL_MACHINE\Software\Microsoft\Windows NT\CurrentVersion\Fonts]"#)
        lines.append("\"FontAwesome (TrueType)\"=\"\(bundledFontFileName)\"")
        lines.append("")

        lines.append(#"[HKEY_LOCAL_MACHINE\Software\Microsoft\Windows NT\CurrentVersion\FontSubstitutes]"#)
        for (from, to) in substitutions { lines.append("\"\(from)\"=\"\(to)\"") }
        lines.append("")

        lines.append(#"[HKEY_CURRENT_USER\Software\Wine\Fonts\Replacements]"#)
        for (from, to) in substitutions { lines.append("\"\(from)\"=\"\(to)\"") }
        lines.append("")

        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// Fixtures for `scripts/verify-font-batching.sh`, written from the live
    /// table above so the script can never drift from the app's own data.
    public static func writeVerificationFixtures(to directory: URL) throws {
        let subs = substitutions.map { "\($0.from)|\($0.to)" }.joined(separator: "\n") + "\n"
        try Data(subs.utf8).write(to: directory.appendingPathComponent("substitutions.txt"))
        try Data(regFileContents().utf8).write(to: directory.appendingPathComponent("fonts.reg"))
    }
}
