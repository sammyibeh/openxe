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
}
