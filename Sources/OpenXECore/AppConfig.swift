import Foundation

/// Per-app "bottle-lean" configuration (spec §4.6). CrossOver-style per-app
/// Windows version and DLL overrides, delivered WITHOUT separate prefixes by
/// leaning on Wine's native per-application settings (`AppDefaults\<exe>`) plus
/// a per-launch `WINEDLLOVERRIDES`. See spec §4.6 for the single-prefix tradeoff.
public struct AppConfig: Codable, Sendable, Equatable {

    /// Windows version reported to the app. Maps to the string Wine stores in
    /// `HKCU\Software\Wine\AppDefaults\<exe>\Version` (winecfg's mechanism).
    public enum WindowsVersion: String, Codable, CaseIterable, Sendable {
        case `default`   // inherit the prefix-global version; write nothing
        case winxp
        case win7
        case win10
        case win11

        /// The value Wine expects, or nil to leave the app on the prefix default.
        public var wineValue: String? {
            self == .default ? nil : rawValue
        }

        public var displayName: String {
            switch self {
            case .default: return "Default (prefix)"
            case .winxp:   return "Windows XP"
            case .win7:    return "Windows 7"
            case .win10:   return "Windows 10"
            case .win11:   return "Windows 11"
            }
        }
    }

    /// A single DLL load-order override (Wine's WINEDLLOVERRIDES semantics).
    public struct DLLOverride: Codable, Sendable, Equatable {
        public enum Mode: String, Codable, CaseIterable, Sendable {
            case native          // n     — the Windows-provided DLL only
            case builtin         // b     — Wine's built-in only
            case nativeBuiltin   // n,b   — native first, then built-in
            case builtinNative   // b,n   — built-in first, then native
            case disabled        // ""    — do not load at all

            /// The right-hand side of `dll=<...>` in WINEDLLOVERRIDES.
            public var token: String {
                switch self {
                case .native: return "n"
                case .builtin: return "b"
                case .nativeBuiltin: return "n,b"
                case .builtinNative: return "b,n"
                case .disabled: return ""
                }
            }
        }

        public var dll: String   // base name, e.g. "d3d11" (no extension)
        public var mode: Mode

        public init(dll: String, mode: Mode) {
            self.dll = dll
            self.mode = mode
        }

        /// The `Mode` for a WINEDLLOVERRIDES right-hand token, or nil if unknown.
        static func mode(fromToken token: String) -> Mode? {
            switch token.replacingOccurrences(of: " ", with: "") {
            case "n": return .native
            case "b": return .builtin
            case "n,b": return .nativeBuiltin
            case "b,n": return .builtinNative
            case "": return .disabled
            default: return nil
            }
        }
    }

    /// Parses a `WINEDLLOVERRIDES`-style string (`dll1=n,b;dll2=b;dll3=`) into
    /// overrides, tolerating commas or semicolons between entries and stray
    /// whitespace. Unknown modes are skipped. Round-trips with
    /// `dllOverridesString`. Kept in Core so it is unit-tested.
    public static func parseDLLOverrides(_ text: String) -> [DLLOverride] {
        // Split entries on ';' — but a mode can itself contain ',' (n,b), so we
        // only treat ',' as an entry separator when it is NOT inside a mode.
        // Simplest robust rule: split on ';' first; if no ';' present, split on
        // top-level ',' that are followed by a token containing '='.
        let rawEntries: [String]
        if text.contains(";") {
            rawEntries = text.split(separator: ";").map(String.init)
        } else {
            rawEntries = text.split(separator: ",").map(String.init)
                .reduce(into: [String]()) { acc, part in
                    if part.contains("=") { acc.append(part) }
                    else if !acc.isEmpty { acc[acc.count - 1] += "," + part }
                    else { acc.append(part) }
                }
        }
        var result: [DLLOverride] = []
        for entry in rawEntries {
            let trimmed = entry.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains("=") else { continue }
            let halves = trimmed.split(separator: "=", maxSplits: 1,
                                       omittingEmptySubsequences: false).map(String.init)
            let dll = halves[0].trimmingCharacters(in: .whitespaces)
            let token = halves.count > 1 ? halves[1] : ""
            guard !dll.isEmpty, let mode = DLLOverride.mode(fromToken: token) else { continue }
            result.append(DLLOverride(dll: dll, mode: mode))
        }
        return result
    }

    /// Absolute path of the .exe this config applies to (the identity key).
    public var exePath: String
    public var windowsVersion: WindowsVersion
    public var dllOverrides: [DLLOverride]
    /// Extra environment variables applied to the launch (rarely needed).
    public var environment: [String: String]

    public init(exePath: String,
                windowsVersion: WindowsVersion = .default,
                dllOverrides: [DLLOverride] = [],
                environment: [String: String] = [:]) {
        self.exePath = exePath
        self.windowsVersion = windowsVersion
        self.dllOverrides = dllOverrides
        self.environment = environment
    }

    /// True when this config asks for nothing beyond the prefix defaults.
    public var isDefault: Bool {
        windowsVersion == .default && dllOverrides.isEmpty && environment.isEmpty
    }

    /// The `WINEDLLOVERRIDES` string for this config, or nil when there are no
    /// overrides. Format: `dll1=n,b;dll2=b;dll3=` (semicolon-separated).
    public var dllOverridesString: String? {
        guard !dllOverrides.isEmpty else { return nil }
        return dllOverrides
            .map { "\($0.dll)=\($0.mode.token)" }
            .joined(separator: ";")
    }

    /// The Wine AppDefaults sub-key name for this exe — Wine keys per-app
    /// settings by the executable's file name.
    public var appDefaultsName: String {
        URL(fileURLWithPath: exePath).lastPathComponent
    }
}

/// Persists per-app configs as a single JSON dictionary (keyed by exe path)
/// under `…/OpenXE/appconfigs.json`. Nothing else writes that file. Spec §4.6.
public final class AppConfigStore: Sendable {
    private let fileURL: URL

    public init(paths: OpenXEPaths) {
        self.fileURL = paths.root.appendingPathComponent("appconfigs.json")
    }

    /// Test seam.
    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    private func loadAll() -> [String: AppConfig] {
        guard let data = try? Data(contentsOf: fileURL),
              let map = try? JSONDecoder().decode([String: AppConfig].self, from: data)
        else { return [:] }
        return map
    }

    private func writeAll(_ map: [String: AppConfig]) {
        let fm = FileManager.default
        try? fm.createDirectory(at: fileURL.deletingLastPathComponent(),
                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(map) {
            try? data.write(to: fileURL)
        }
    }

    /// The config for an exe, or nil when none is stored.
    public func config(forExePath path: String) -> AppConfig? {
        loadAll()[path]
    }

    public func config(for exe: URL) -> AppConfig? {
        config(forExePath: exe.path)
    }

    /// Every stored config, sorted by exe path for stable UI ordering.
    public func allConfigs() -> [AppConfig] {
        loadAll().values.sorted { $0.exePath < $1.exePath }
    }

    /// Saves (or, when the config is back to all-defaults, removes) the config.
    public func save(_ config: AppConfig) {
        var map = loadAll()
        if config.isDefault {
            map.removeValue(forKey: config.exePath)
        } else {
            map[config.exePath] = config
        }
        writeAll(map)
    }

    public func remove(exePath: String) {
        var map = loadAll()
        map.removeValue(forKey: exePath)
        writeAll(map)
    }
}
