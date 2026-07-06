import Foundation

public enum PrefixError: Error, LocalizedError {
    case bootFailed(status: Int32, detail: String)
    case monoOrGeckoMissing(String)

    public var errorDescription: String? {
        switch self {
        case .bootFailed(let status, let detail):
            return "Windows environment setup failed (wineboot exited \(status)): \(detail)"
        case .monoOrGeckoMissing(let detail):
            return "Windows environment is incomplete — \(detail). "
                + ".NET and embedded-browser support are required; the environment was not marked ready."
        }
    }
}

/// Owns the single persistent prefix — the durable memory (registry, C: drive,
/// user profile). Spec §4.2. Idempotent via a ready-marker file.
public final class PrefixManager: Sendable {
    private let paths: OpenXEPaths
    private static let readyMarker = ".openxe-ready"

    public init(paths: OpenXEPaths) {
        self.paths = paths
    }

    public var isReady: Bool {
        FileManager.default.fileExists(
            atPath: paths.prefix.appendingPathComponent(Self.readyMarker).path)
    }

    public func ensurePrefix() throws {
        guard !isReady else { return }
        let fm = FileManager.default
        try fm.createDirectory(at: paths.prefix, withIntermediateDirectories: true)
        let env = WineEnvironment.build(engineCurrent: paths.engineCurrent, prefix: paths.prefix)

        // 1. Boot. Bundled shared Mono/Gecko auto-install here (spec §4.1);
        //    allow generous time for that one-time work.
        let boot = try Subprocess.run(paths.wineBinary,
                                      arguments: ["wineboot", "--init"],
                                      environment: env, timeout: 900)
        guard boot.status == 0 else {
            throw PrefixError.bootFailed(status: boot.status, detail: String(boot.output.suffix(400)))
        }
        // Wait for background services (mono/gecko installers) to finish.
        _ = try? Subprocess.run(paths.wineserverBinary, arguments: ["-w"],
                                environment: env, timeout: 900)

        // 2. Verify Mono + Gecko — hard requirement; fail loudly, never degrade.
        let driveC = paths.prefix.appendingPathComponent("drive_c")
        try verifyNonEmptyDirectory(driveC.appendingPathComponent("windows/mono"), name: "Wine Mono (.NET)")
        try verifyNonEmptyDirectory(driveC.appendingPathComponent("windows/system32/gecko"), name: "Wine Gecko (embedded browser)")

        // 3. Retina rendering.
        try registryAdd(key: #"HKCU\Software\Wine\Mac Driver"#, value: "RetinaMode",
                        type: "REG_SZ", data: "y", env: env)
        try registryAdd(key: #"HKCU\Control Panel\Desktop"#, value: "LogPixels",
                        type: "REG_DWORD", data: "192", env: env)

        // 4. Link the Mac's real folders into the Windows user profile.
        let home = fm.homeDirectoryForCurrentUser
        let winUser = driveC.appendingPathComponent("users/\(NSUserName())")
        for folder in ["Documents", "Downloads", "Desktop"] {
            let winFolder = winUser.appendingPathComponent(folder)
            let target = home.appendingPathComponent(folder)
            guard fm.fileExists(atPath: target.path) else { continue }
            // Only replace what wineboot freshly created: an empty real directory.
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: winFolder.path, isDirectory: &isDir) {
                let isSymlink = (try? fm.destinationOfSymbolicLink(atPath: winFolder.path)) != nil
                if isSymlink { continue } // already linked
                guard isDir.boolValue,
                      let contents = try? fm.contentsOfDirectory(atPath: winFolder.path),
                      contents.isEmpty
                else { continue } // never delete user data
                try fm.removeItem(at: winFolder)
            }
            try fm.createSymbolicLink(atPath: winFolder.path, withDestinationPath: target.path)
        }

        // 5. Ready marker records the creating engine version.
        let engineVersion = EngineManager(paths: paths).installedVersion ?? "unknown"
        try Data("engine=\(engineVersion)\n".utf8)
            .write(to: paths.prefix.appendingPathComponent(Self.readyMarker))
    }

    /// Destructive: shuts the environment down and deletes the prefix.
    /// The Shell confirms with the user before calling this (spec §4.2).
    public func reset() throws {
        let env = WineEnvironment.build(engineCurrent: paths.engineCurrent, prefix: paths.prefix)
        _ = try? Subprocess.run(paths.wineserverBinary, arguments: ["-k"],
                                environment: env, timeout: 30)
        _ = try? Subprocess.run(paths.wineserverBinary, arguments: ["-w"],
                                environment: env, timeout: 60)
        try FileManager.default.removeItem(at: paths.prefix)
    }

    // MARK: helpers

    private func verifyNonEmptyDirectory(_ url: URL, name: String) throws {
        let contents = try? FileManager.default.contentsOfDirectory(atPath: url.path)
        guard let contents, !contents.isEmpty else {
            throw PrefixError.monoOrGeckoMissing("\(name) is missing at \(url.path)")
        }
    }

    private func registryAdd(key: String, value: String, type: String, data: String,
                             env: [String: String]) throws {
        let result = try Subprocess.run(
            paths.wineBinary,
            arguments: ["reg", "add", key, "/v", value, "/t", type, "/d", data, "/f"],
            environment: env, timeout: 120)
        guard result.status == 0 else {
            throw PrefixError.bootFailed(status: result.status,
                                         detail: "reg add \(key)\\\(value): \(result.output.suffix(200))")
        }
    }
}
