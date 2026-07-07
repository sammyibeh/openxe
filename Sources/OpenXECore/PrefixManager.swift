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
    private let engine: EngineManager
    private static let readyMarker = ".openxe-ready"

    public init(paths: OpenXEPaths) {
        self.paths = paths
        self.engine = EngineManager(paths: paths)
    }

    /// The engine id recorded when the prefix was last built, if any.
    private var markerEngineID: String? {
        let marker = paths.prefix.appendingPathComponent(Self.readyMarker)
        guard let text = try? String(contentsOf: marker, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.hasPrefix("engine=") {
            return String(line.dropFirst("engine=".count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// The prefix is ready only when it was built for the *currently active*
    /// engine. A Wine prefix is bound to its engine (Wine does not support
    /// downgrades), so switching engines invalidates it and forces a rebuild
    /// (spec §4.2, §8).
    public var isReady: Bool {
        guard let built = markerEngineID else { return false }
        return built == (engine.activeEngineID ?? "")
    }

    public func ensurePrefix() throws {
        guard !isReady else { return }
        let fm = FileManager.default

        // A prefix left over from a different engine must be wiped first —
        // never reuse a mismatched prefix.
        if fm.fileExists(atPath: paths.prefix.path), markerEngineID != engine.activeEngineID {
            shutdownServer()
            try? fm.removeItem(at: paths.prefix)
        }
        try fm.createDirectory(at: paths.prefix, withIntermediateDirectories: true)
        let env = WineEnvironment.build(engineCurrent: paths.engineCurrent, prefix: paths.prefix)

        // 1. Boot. Bundled shared Mono/Gecko auto-install here (spec §4.1);
        //    allow generous time for that one-time work.
        let boot = try Subprocess.run(engine.activeWineBinary,
                                      arguments: ["wineboot", "--init"],
                                      environment: env, timeout: 900)
        guard boot.status == 0 else {
            throw PrefixError.bootFailed(status: boot.status, detail: String(boot.output.suffix(400)))
        }
        // Wait for background services (mono/gecko installers) to finish.
        _ = try? Subprocess.run(engine.activeWineserverBinary, arguments: ["-w"],
                                environment: env, timeout: 900, captureOutput: false)

        // 2. Verify Mono + Gecko — hard requirement; fail loudly, never degrade.
        //    The bundled builds install both as *shared* (used in place from the
        //    engine's share/wine/, registered into the prefix) — so Mono is
        //    verified via its registry registration, not drive_c/windows/mono.
        let driveC = paths.prefix.appendingPathComponent("drive_c")
        let systemReg = (try? String(contentsOf: paths.prefix.appendingPathComponent("system.reg"),
                                     encoding: .utf8)) ?? ""
        guard systemReg.contains("Wine Mono") else {
            throw PrefixError.monoOrGeckoMissing("Wine Mono (.NET) is not registered in the prefix")
        }
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

        // 5. Ready marker records the creating engine id (the rebuild key).
        let engineID = engine.activeEngineID ?? "unknown"
        try Data("engine=\(engineID)\n".utf8)
            .write(to: paths.prefix.appendingPathComponent(Self.readyMarker))
    }

    /// Destructive: shuts the environment down and deletes the prefix.
    /// The Shell confirms with the user before calling this (spec §4.2).
    public func reset() throws {
        shutdownServer()
        try FileManager.default.removeItem(at: paths.prefix)
    }

    private func shutdownServer() {
        let env = WineEnvironment.build(engineCurrent: paths.engineCurrent, prefix: paths.prefix)
        _ = try? Subprocess.run(engine.activeWineserverBinary, arguments: ["-k"],
                                environment: env, timeout: 30, captureOutput: false)
        _ = try? Subprocess.run(engine.activeWineserverBinary, arguments: ["-w"],
                                environment: env, timeout: 60, captureOutput: false)
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
            engine.activeWineBinary,
            arguments: ["reg", "add", key, "/v", value, "/t", type, "/d", data, "/f"],
            environment: env, timeout: 120)
        guard result.status == 0 else {
            throw PrefixError.bootFailed(status: result.status,
                                         detail: "reg add \(key)\\\(value): \(result.output.suffix(200))")
        }
    }
}
