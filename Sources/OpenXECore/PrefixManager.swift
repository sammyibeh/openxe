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

        // 3a. Font provisioning (spec §4.2). Best-effort — font issues must never
        //     block a launch. Generalized from the NWS-specific fix into a base
        //     applied to every prefix: install the one font macOS lacks
        //     (FontAwesome) and register broad fallback substitutions so any
        //     Windows font we cannot supply degrades to a close available face
        //     instead of NULL-derefing wine-mono's WPF text layout. See
        //     FontProvisioning for the base-fonts-from-macOS rationale.
        provisionFonts(env: env)

        // 3b. Software rendering default (spec §4.2, §8). OpenXE ships no GPU
        //     stack (no MoltenVK/DXVK), so WPF's hardware render tier hits the
        //     Mac GL/Vulkan path and logs GL_INVALID_FRAMEBUFFER_OPERATION /
        //     failed vulkan_init. Forcing WPF onto its software render tier
        //     (Avalon.Graphics\DisableHWAcceleration=1) keeps GPU-leaning apps on
        //     a path that actually works here. The map/3D view degrades; the main
        //     UI renders. Best-effort; a per-app override can re-enable it later.
        regBestEffort([#"HKCU\Software\Microsoft\Avalon.Graphics"#,
                       "/v", "DisableHWAcceleration", "/t", "REG_DWORD", "/d", "1", "/f"], env: env)

        // 4. Link the Mac's real folders into the Windows user profile.
        //    Best-effort: folder linking must NEVER abort ensurePrefix, or the
        //    ready-marker (step 5) is never written, `isReady` stays false, and
        //    the *next* open wipes and rebuilds the prefix — destroying installed
        //    apps on every launch. The Windows profile directory name is
        //    engine-dependent (CrossOver's wineboot creates `users/crossover`,
        //    Gcenx uses the unix user name), so link into whatever real profiles
        //    wineboot created rather than assuming `NSUserName()`.
        let home = fm.homeDirectoryForCurrentUser
        let usersDir = driveC.appendingPathComponent("users")
        let profiles = ((try? fm.contentsOfDirectory(atPath: usersDir.path)) ?? [])
            .filter { $0 != "Public" && !$0.hasPrefix(".") }
        for profile in profiles {
            let winUser = usersDir.appendingPathComponent(profile)
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
                    try? fm.removeItem(at: winFolder)
                }
                try? fm.createSymbolicLink(atPath: winFolder.path, withDestinationPath: target.path)
            }
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

    /// Font provisioning (spec §4.2 step 3a): install the one bundled font macOS
    /// lacks and register the broad fallback substitution table from
    /// `FontProvisioning`. Idempotent and best-effort: any failure is swallowed
    /// so it can never block prefix readiness.
    private func provisionFonts(env: [String: String]) {
        let fm = FileManager.default
        let fontsDir = paths.prefix.appendingPathComponent("drive_c/windows/Fonts")
        try? fm.createDirectory(at: fontsDir, withIntermediateDirectories: true)

        // Install the bundled FontAwesome so family-name fallback resolves it
        // when wine-mono cannot load an app's embedded copy. Every other common
        // font (the Microsoft corefonts) is already provided by the Mac driver
        // from macOS — see FontProvisioning for why we do not bundle those.
        if let src = Bundle.main.url(forResource: FontProvisioning.bundledFontResource,
                                     withExtension: "ttf") {
            let dst = fontsDir.appendingPathComponent(FontProvisioning.bundledFontFileName)
            try? fm.removeItem(at: dst)
            if (try? fm.copyItem(at: src, to: dst)) != nil {
                regBestEffort([#"HKLM\Software\Microsoft\Windows NT\CurrentVersion\Fonts"#,
                               "/v", "FontAwesome (TrueType)", "/t", "REG_SZ",
                               "/d", FontProvisioning.bundledFontFileName, "/f"], env: env)
            }
        }

        // Broad fallback substitutions. Set both the GDI table (which wine-mono
        // reads for WPF) and wine's own Replacements table so a missing font
        // degrades to a close available face rather than crashing.
        for (from, to) in FontProvisioning.substitutions {
            regBestEffort([#"HKLM\Software\Microsoft\Windows NT\CurrentVersion\FontSubstitutes"#,
                           "/v", from, "/t", "REG_SZ", "/d", to, "/f"], env: env)
            regBestEffort([#"HKCU\Software\Wine\Fonts\Replacements"#,
                           "/v", from, "/t", "REG_SZ", "/d", to, "/f"], env: env)
        }
    }

    private func regBestEffort(_ args: [String], env: [String: String]) {
        _ = try? Subprocess.run(engine.activeWineBinary, arguments: ["reg", "add"] + args,
                                environment: env, timeout: 60, captureOutput: false)
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
