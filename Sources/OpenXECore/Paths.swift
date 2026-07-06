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

    /// The single persistent Wine prefix — the durable memory. Spec §4.2.
    public var prefix: URL { root.appendingPathComponent("prefix", isDirectory: true) }

    /// ~/Library/Logs/OpenXE/wine.log (session-appended).
    public var wineLog: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/OpenXE/wine.log")
    }
}

/// Environment construction for wine/wineserver subprocesses. Spec §4.3.
/// Pure function: exactly WINEPREFIX + minimal PATH + WINEDEBUG, nothing else.
public enum WineEnvironment {
    public static func build(engineCurrent: URL, prefix: URL) -> [String: String] {
        [
            "WINEPREFIX": prefix.path,
            "PATH": "\(engineCurrent.path)/wine/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "WINEDEBUG": "fixme-all",
        ]
    }
}
