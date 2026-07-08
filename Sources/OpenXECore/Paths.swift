import Foundation

/// Filesystem contract for OpenXE. Spec §3. All components resolve
/// Wine paths through `engineCurrent` — that symlink is the engine swap point.
public struct OpenXEPaths: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// ~/Library/Application Support/OpenXE + ~/Library/Logs/OpenXE
    public static var standard: OpenXEPaths {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return OpenXEPaths(root: appSupport.appendingPathComponent("OpenXE", isDirectory: true))
    }

    /// engine/ — one subdirectory per engine version.
    public var engineVersions: URL { root.appendingPathComponent("engine", isDirectory: true) }

    /// engine/current — symlink to the active engine version.
    public var engineCurrent: URL { engineVersions.appendingPathComponent("current", isDirectory: true) }

    public var wineBinary: URL {
        engineCurrent.appendingPathComponent("wine/bin/wine")
    }

    public var wineserverBinary: URL {
        engineCurrent.appendingPathComponent("wine/bin/wineserver")
    }

    /// The unix-side wine loader (the actual process image, not the `bin/wine`
    /// front-end). A per-exe `.app` symlinks this as its CFBundleExecutable so
    /// the Windows program presents its own icon and name in the Dock (spec §9.5).
    public var unixWineLoader: URL {
        engineCurrent.appendingPathComponent("wine/lib/wine/x86_64-unix/wine")
    }

    /// Per-exe icon-wrapper `.app` bundles that give running Windows programs a
    /// real Dock identity. Internal; not user-facing. Spec §9.5.
    public var appBundles: URL { root.appendingPathComponent("AppBundles", isDirectory: true) }

    /// The single persistent Wine prefix — the durable memory. Spec §4.2.
    public var prefix: URL { root.appendingPathComponent("prefix", isDirectory: true) }

    /// ~/Library/Logs/OpenXE/wine.log (session-appended).
    public var wineLog: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/OpenXE/wine.log")
    }
}

/// Environment construction for wine/wineserver subprocesses. Spec §4.3.
/// Pure function: WINEPREFIX + minimal PATH + WINEDEBUG + the engine's dyld
/// fallback path. The dyld path is load-bearing, not cosmetic: win32u dlopens
/// the bare soname "libfreetype.6.dylib", which the engine ships in
/// `<engine>/wine/lib`. Without that directory on the dyld search path the
/// bundled freetype is not found at load time, and WPF/.NET apps FailFast at
/// startup (TypefaceMap -> NullFontFamily). Verified 2026-07-07: the exact
/// prior env (no DYLD) fails freetype 6/6; adding this path fixes single-process
/// apps 0/6. `DYLD_FALLBACK_LIBRARY_PATH` is only consulted when a library is
/// not otherwise found, so it cannot shadow system libs.
public enum WineEnvironment {
    public static func build(engineCurrent: URL, prefix: URL) -> [String: String] {
        [
            "WINEPREFIX": prefix.path,
            "PATH": "\(engineCurrent.path)/wine/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "WINEDEBUG": "fixme-all",
            "DYLD_FALLBACK_LIBRARY_PATH": "\(engineCurrent.path)/wine/lib:/usr/lib:/usr/local/lib",
        ]
    }

    /// The launch environment for a specific app: the base env overlaid with the
    /// per-app config's `WINEDLLOVERRIDES` and extra environment (spec §4.6). The
    /// app's Windows version is applied separately as a registry key (Wine has no
    /// env var for it). With a nil/all-default config this equals `build`.
    public static func buildLaunch(engineCurrent: URL, prefix: URL,
                                   config: AppConfig?) -> [String: String] {
        var env = build(engineCurrent: engineCurrent, prefix: prefix)
        guard let config else { return env }
        if let overrides = config.dllOverridesString {
            env["WINEDLLOVERRIDES"] = overrides
        }
        // Per-app env wins, but never let it clobber the load-bearing keys that
        // make Wine resolve the engine at all (WINEPREFIX/PATH/DYLD path).
        let locked: Set<String> = ["WINEPREFIX", "PATH", "DYLD_FALLBACK_LIBRARY_PATH"]
        for (key, value) in config.environment where !locked.contains(key) {
            env[key] = value
        }
        return env
    }
}
