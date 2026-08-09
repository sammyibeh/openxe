import Foundation

// MARK: - Safety

/// The guardrails for removal. Spec §5.
///
/// This file deletes a lot on purpose, so every rule that keeps it from deleting
/// the wrong thing lives here, in one place, and is unit-tested directly.
///
/// Two hazards drive the design:
///
///  - The prefix is full of symlinks that leave it. `users/<profile>/Documents`,
///    `Downloads` and `Desktop` point at the real home folders, and
///    `dosdevices/z:` points at `/`. Traversing any of them while sizing or
///    copying would reach the user's actual files.
///  - A test bundle must never be able to reach a live path. `RosettaGate`
///    learned this the expensive way; the same discipline is applied here.
public enum CleanupSafety {

    /// `FileManager.attributesOfItem` uses `lstat`, so a symlink reports
    /// `.typeSymbolicLink` rather than the type of whatever it points at. That
    /// documented behaviour is the whole basis of the no-traversal guarantee —
    /// nothing here relies on `FileManager.enumerator`'s traversal semantics.
    public static func isSymbolicLink(atPath path: String) -> Bool {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return attrs?[.type] as? FileAttributeType == .typeSymbolicLink
    }

    /// Paths that must never be deleted no matter what a plan says.
    public static func forbidden(home: URL) -> [URL] {
        [
            URL(fileURLWithPath: "/"),
            home,
            home.appendingPathComponent("Documents"),
            home.appendingPathComponent("Downloads"),
            home.appendingPathComponent("Desktop"),
            home.appendingPathComponent("Library"),
            home.appendingPathComponent("Applications"),
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/tmp"),
        ]
    }

    /// Component-wise containment. A string prefix test would accept
    /// `/Applications/OpenXE Appsomething` as being inside
    /// `/Applications/OpenXE Apps`; this does not.
    public static func isContained(_ url: URL, in root: URL) -> Bool {
        let child = url.standardizedFileURL.pathComponents
        let parent = root.standardizedFileURL.pathComponents
        guard child.count > parent.count else { return false }
        return Array(child.prefix(parent.count)) == parent
    }

    /// A path may be deleted only if it is one of the enumerated roots, or lies
    /// under one, and is not forbidden, and contains no `..` escape.
    public static func isDeletable(_ url: URL, allowedRoots: [URL], home: URL) -> Bool {
        let target = url.standardizedFileURL
        guard !target.pathComponents.contains("..") else { return false }
        guard target.path != "/" else { return false }
        for bad in forbidden(home: home) where bad.standardizedFileURL.path == target.path {
            return false
        }
        for root in allowedRoots {
            let r = root.standardizedFileURL
            if r.path == target.path || isContained(target, in: r) { return true }
        }
        return false
    }

    /// Bytes used by `url`, never following a symlink and never counting one.
    ///
    /// Hand-rolled rather than `FileManager.enumerator` so the no-traversal rule
    /// is visible in the code that depends on it. A symlink contributes zero and
    /// is not descended into — which is why sizing the prefix does not report
    /// the size of the user's entire home folder.
    public static func size(of url: URL) -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        var stack = [url]
        while let current = stack.popLast() {
            guard let attrs = try? fm.attributesOfItem(atPath: current.path) else { continue }
            let type = attrs[.type] as? FileAttributeType
            if type == .typeSymbolicLink { continue }
            if type == .typeDirectory {
                let names = (try? fm.contentsOfDirectory(atPath: current.path)) ?? []
                for name in names {
                    stack.append(current.appendingPathComponent(name))
                }
            } else {
                total += (attrs[.size] as? NSNumber)?.int64Value ?? 0
            }
        }
        return total
    }

    /// Recursive copy that skips symlinks outright instead of copying or
    /// following them. Used for preservation, where the source sits inside the
    /// prefix and a stray link must not drag the host filesystem along.
    /// Returns the number of files copied.
    @discardableResult
    public static func copySkippingSymlinks(from source: URL, to destination: URL) throws -> Int {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: source.path) else { return 0 }
        let type = attrs[.type] as? FileAttributeType
        if type == .typeSymbolicLink { return 0 }
        if type == .typeDirectory {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            var copied = 0
            for name in (try? fm.contentsOfDirectory(atPath: source.path)) ?? [] {
                copied += try copySkippingSymlinks(
                    from: source.appendingPathComponent(name),
                    to: destination.appendingPathComponent(name))
            }
            return copied
        }
        try fm.createDirectory(at: destination.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try? fm.removeItem(at: destination)
        try fm.copyItem(at: source, to: destination)
        return 1
    }

    /// Shared with `RosettaCheck` so there is one definition of "under test".
    static var isRunningUnderTest: Bool { RosettaCheck.isRunningUnderTest }
}

// MARK: - Registry capture

/// Reads the one registry value the NWS installer writes and OpenXE does not.
///
/// `system.reg` is a text file; by the time cleanup runs, wineserver has been
/// terminated and `reg query` is not an option, so this parses directly. Pure,
/// so it is tested against the real file's shape without a prefix. Spec §4.1.
public enum NWSRegistryCapture {
    /// The value name written under
    /// `…\Control\Session Manager\Environment`.
    public static let valueName = "NWScheduler"

    /// A live section header is
    /// `[System\\ControlSet001\\Control\\Session Manager\\Environment] 1783699422`
    /// — note the trailing modification timestamp, and that the control-set
    /// number is not fixed. So: cut the header at its closing bracket, then
    /// match on the suffix rather than the whole path.
    static let sectionSuffix = #"Control\\Session Manager\\Environment]"#

    static func isEnvironmentSectionHeader<S: StringProtocol>(_ line: S) -> Bool {
        guard let close = line.firstIndex(of: "]") else { return false }
        return line[...close].hasSuffix(sectionSuffix)
    }

    public static func environmentValue(named name: String,
                                        inSystemReg text: String) -> String? {
        var inSection = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("[") {
                inSection = isEnvironmentSectionHeader(line)
                continue
            }
            guard inSection else { continue }
            let prefix = "\"\(name)\"=\""
            guard line.hasPrefix(prefix), line.hasSuffix("\"") else { continue }
            let body = line.dropFirst(prefix.count).dropLast()
            return String(body)
        }
        return nil
    }

    public static func environmentValue(named name: String, inSystemRegAt url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return environmentValue(named: name, inSystemReg: text)
    }

    /// A `.reg` file that restores the captured value into a rebuilt prefix.
    public static func regFileContents(name: String, value: String) -> String {
        """
        Windows Registry Editor Version 5.00

        [HKEY_LOCAL_MACHINE\\System\\CurrentControlSet\\Control\\Session Manager\\Environment]
        "\(name)"="\(value)"

        """
    }
}

// MARK: - Plan

public struct CleanupTarget: Sendable, Equatable {
    public let url: URL
    /// Non-technical description shown to the user. Spec §6.
    public let label: String
    public let sizeBytes: Int64

    public init(url: URL, label: String, sizeBytes: Int64) {
        self.url = url
        self.label = label
        self.sizeBytes = sizeBytes
    }
}

public struct CleanupPlan: Sendable, Equatable {
    /// Everything that will be deleted, in the order it will be deleted.
    public let targets: [CleanupTarget]
    /// The New World Scheduler data directory, if present. It sits *inside* the
    /// prefix, so its bytes are already counted in the Application Support
    /// target — it is surfaced separately only so the user can be told what is
    /// at stake, never added to the total.
    public let nwsDataDirectory: URL?
    public let nwsDataBytes: Int64
    /// Bytes of the four preserve targets — what a "keep my information" copy
    /// will actually write into Documents.
    public let preservableBytes: Int64
    /// Generated launcher bundles that will be removed.
    public let launcherCount: Int

    public var totalBytes: Int64 { targets.reduce(0) { $0 + $1.sizeBytes } }
    public var isEmpty: Bool { targets.isEmpty && launcherCount == 0 }

    public init(targets: [CleanupTarget], nwsDataDirectory: URL?, nwsDataBytes: Int64,
                preservableBytes: Int64, launcherCount: Int) {
        self.targets = targets
        self.nwsDataDirectory = nwsDataDirectory
        self.nwsDataBytes = nwsDataBytes
        self.preservableBytes = preservableBytes
        self.launcherCount = launcherCount
    }
}

/// Enumerates what OpenXE has actually left on this Mac. Spec §3.
///
/// Every path is injected. There is deliberately no initialiser that resolves to
/// the live machine: the defaulted-dependency mistake that re-pointed a whole
/// test suite at the real Rosetta installer must not be repeatable here.
public struct CleanupPlanner: Sendable {
    /// The four things worth keeping out of a 116 MB directory. Spec §4.1.
    public static let preserveNames = ["MyData", "Backups", "Settings1.json",
                                       "RegistrationKey.json"]

    let paths: OpenXEPaths
    let home: URL
    let library: URL
    let bundleIdentifier: String
    let launcherDirectories: [URL]

    public init(paths: OpenXEPaths, home: URL, library: URL,
                bundleIdentifier: String, launcherDirectories: [URL]) {
        self.paths = paths
        self.home = home
        self.library = library
        self.bundleIdentifier = bundleIdentifier
        self.launcherDirectories = launcherDirectories
    }

    /// The production wiring. Planning is read-only, so unlike the runner this
    /// is safe to construct anywhere — including under test, where
    /// `CleanupBoundaryTests` uses it to prove the allowlist holds on a real Mac.
    public static func live(paths: OpenXEPaths) -> CleanupPlanner {
        let fm = FileManager.default
        return CleanupPlanner(
            paths: paths,
            home: fm.homeDirectoryForCurrentUser,
            library: fm.urls(for: .libraryDirectory, in: .userDomainMask)[0],
            bundleIdentifier: Bundle.main.bundleIdentifier ?? "dev.openxe.OpenXE",
            launcherDirectories: LauncherManager.candidateDirectories)
    }

    /// Every root the runner is permitted to delete under. Anything not covered
    /// by this list is rejected by `CleanupSafety.isDeletable`.
    public var allowedRoots: [URL] {
        [paths.root, library.appendingPathComponent("Logs/OpenXE")]
            + systemManagedPaths
            + launcherDirectories
    }

    /// Directories macOS creates on our behalf, keyed on the bundle identifier.
    var systemManagedPaths: [URL] {
        [
            library.appendingPathComponent("Preferences/\(bundleIdentifier).plist"),
            library.appendingPathComponent("Caches/\(bundleIdentifier)"),
            library.appendingPathComponent("HTTPStorages/\(bundleIdentifier)"),
            library.appendingPathComponent("Saved Application State/\(bundleIdentifier).savedState"),
        ]
    }

    /// The NWS data directory inside whichever Windows profile wineboot made.
    /// The profile name is engine-dependent (`sammyibeh` under Gcenx,
    /// `crossover` under a CrossOver-derived build), so it is discovered rather
    /// than assumed — the same reason `PrefixManager` scans for profiles.
    public func nwsDataDirectory() -> URL? {
        let fm = FileManager.default
        let users = paths.prefix.appendingPathComponent("drive_c/users")
        let profiles = ((try? fm.contentsOfDirectory(atPath: users.path)) ?? [])
            .filter { $0 != "Public" && !$0.hasPrefix(".") }
            .sorted()
        for profile in profiles {
            let candidate = users.appendingPathComponent(profile)
                .appendingPathComponent("AppData/Local/NW Scheduler")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                return candidate
            }
        }
        return nil
    }

    public func existingLauncherBundles() -> [URL] {
        let fm = FileManager.default
        var found: [URL] = []
        for dir in launcherDirectories {
            // Names rather than URLs: `contentsOfDirectory(at:)` hands back
            // URLs that have been through path normalisation, so the strings no
            // longer compare equal to a caller-built path. Every identity check
            // downstream (the allowlist, the launcher tally) is by path.
            let names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
            for name in names where (name as NSString).pathExtension == "app" {
                let bundle = dir.appendingPathComponent(name, isDirectory: true)
                let plist = bundle.appendingPathComponent("Contents/Info.plist")
                guard let data = try? Data(contentsOf: plist),
                      let dict = try? PropertyListSerialization.propertyList(from: data, format: nil)
                        as? [String: Any],
                      dict[LauncherManager.targetPathKey] != nil
                else { continue }
                found.append(bundle)
            }
        }
        return found
    }

    public func plan() -> CleanupPlan {
        let fm = FileManager.default
        var targets: [CleanupTarget] = []

        func add(_ url: URL, _ label: String) {
            guard fm.fileExists(atPath: url.path) else { return }
            targets.append(CleanupTarget(url: url, label: label,
                                         sizeBytes: CleanupSafety.size(of: url)))
        }

        add(paths.root, SetupCopy.cleanupItemSupport)
        add(library.appendingPathComponent("Logs/OpenXE"), SetupCopy.cleanupItemLogs)
        add(systemManagedPaths[0], SetupCopy.cleanupItemPreferences)
        add(systemManagedPaths[1], SetupCopy.cleanupItemCaches)
        add(systemManagedPaths[2], SetupCopy.cleanupItemCaches)
        add(systemManagedPaths[3], SetupCopy.cleanupItemWindowState)

        let launchers = existingLauncherBundles()
        for bundle in launchers {
            targets.append(CleanupTarget(
                url: bundle,
                label: SetupCopy.cleanupItemLauncher(bundle.deletingPathExtension().lastPathComponent),
                sizeBytes: CleanupSafety.size(of: bundle)))
        }

        let dataDir = nwsDataDirectory()
        var dataBytes: Int64 = 0
        var preservable: Int64 = 0
        if let dataDir {
            dataBytes = CleanupSafety.size(of: dataDir)
            for name in Self.preserveNames {
                preservable += CleanupSafety.size(of: dataDir.appendingPathComponent(name))
            }
        }

        return CleanupPlan(targets: targets, nwsDataDirectory: dataDir,
                           nwsDataBytes: dataBytes, preservableBytes: preservable,
                           launcherCount: launchers.count)
    }
}

// MARK: - Preservation

public struct PreservedData: Sendable, Equatable {
    public let destination: URL
    public let itemsCopied: [String]
    public let filesCopied: Int
    public let registryValue: String?
    public let bytes: Int64
}

public enum CleanupError: Error, LocalizedError {
    case refusedUnderTest(String)
    case preserveFailed(String)

    public var errorDescription: String? {
        switch self {
        case .refusedUnderTest(let detail):
            return "refused: cleanup is disabled under test (\(detail))"
        case .preserveFailed(let detail):
            return SetupCopy.cleanupPreserveFailed + " (\(detail))"
        }
    }
}

// MARK: - Runner

public struct CleanupOutcome: Sendable {
    public let removed: [CleanupTarget]
    /// Targets the allowlist rejected, or that the filesystem refused. Reported,
    /// never silently swallowed.
    public let skipped: [String]
    public let reclaimedBytes: Int64
    public let preserved: PreservedData?
    public let launchersRemoved: Int
}

/// Executes a `CleanupPlan`. Spec §6.
///
/// Like `CleanupPlanner`, nothing is defaulted — and unlike the planner, this
/// type deletes, so it additionally refuses to run under test unless every
/// allowed root sits inside the caller-declared sandbox.
public struct CleanupRunner: Sendable {
    let planner: CleanupPlanner
    let paths: OpenXEPaths
    let home: URL
    /// When non-nil, every deletion must fall inside this directory. Tests pass
    /// their own temporary directory; production passes nil.
    let sandbox: URL?
    /// Injected so tests never shell out. Production passes a closure that
    /// terminates the real wineserver.
    let shutdownWineserver: @Sendable () -> Void
    /// Injected for the same reason; production unregisters the app bundle.
    let unregisterFromLaunchServices: @Sendable () -> Void

    public init(planner: CleanupPlanner, paths: OpenXEPaths, home: URL, sandbox: URL?,
                shutdownWineserver: @escaping @Sendable () -> Void,
                unregisterFromLaunchServices: @escaping @Sendable () -> Void) {
        self.planner = planner
        self.paths = paths
        self.home = home
        self.sandbox = sandbox
        self.shutdownWineserver = shutdownWineserver
        self.unregisterFromLaunchServices = unregisterFromLaunchServices
    }

    /// The boundary that makes a destructive suite survivable. A test bundle may
    /// only run cleanup against roots inside its own temporary sandbox; without
    /// one, the call throws rather than touching anything.
    func assertBoundary() throws {
        guard CleanupSafety.isRunningUnderTest else { return }
        guard let sandbox else {
            throw CleanupError.refusedUnderTest("no sandbox declared")
        }
        for root in planner.allowedRoots {
            guard CleanupSafety.isContained(root, in: sandbox) else {
                throw CleanupError.refusedUnderTest("root outside sandbox: \(root.path)")
            }
        }
        guard CleanupSafety.isContained(home, in: sandbox) || home == sandbox else {
            throw CleanupError.refusedUnderTest("home outside sandbox: \(home.path)")
        }
    }

    /// `keepNWSData == true` (the default the UI presents) copies the four
    /// preserve targets and the registry value out *before* anything is deleted.
    /// A preservation failure aborts with nothing removed — spec §6 step 5.
    public func run(plan: CleanupPlan, keepNWSData: Bool,
                    documentsDirectory: URL, now: Date) throws -> CleanupOutcome {
        try assertBoundary()

        // 1. Nothing may hold prefix files open.
        shutdownWineserver()

        // 2. Preserve before deleting. Ordering is the whole point.
        var preserved: PreservedData?
        if keepNWSData, let dataDir = plan.nwsDataDirectory {
            do {
                preserved = try preserve(from: dataDir,
                                         documentsDirectory: documentsDirectory, now: now)
            } catch {
                throw CleanupError.preserveFailed(error.localizedDescription)
            }
        }

        // 3. Delete, allowlist-checking every single target.
        let roots = planner.allowedRoots
        var removed: [CleanupTarget] = []
        var skipped: [String] = []
        var reclaimed: Int64 = 0
        var launchersRemoved = 0
        let launcherSet = Set(planner.existingLauncherBundles().map(\.path))

        for target in plan.targets {
            guard CleanupSafety.isDeletable(target.url, allowedRoots: roots, home: home) else {
                skipped.append("\(target.label) — outside the area OpenXE is allowed to remove")
                continue
            }
            do {
                try FileManager.default.removeItem(at: target.url)
                removed.append(target)
                reclaimed += target.sizeBytes
                if launcherSet.contains(target.url.path) { launchersRemoved += 1 }
            } catch {
                skipped.append("\(target.label) — \(error.localizedDescription)")
            }
        }

        // 4. Drop the .exe handler registration.
        unregisterFromLaunchServices()

        return CleanupOutcome(removed: removed, skipped: skipped, reclaimedBytes: reclaimed,
                              preserved: preserved, launchersRemoved: launchersRemoved)
    }

    /// Copies the preserve set into a plainly-named folder in Documents, along
    /// with the registry value and a README. Spec §4.2.
    func preserve(from dataDir: URL, documentsDirectory: URL, now: Date) throws -> PreservedData {
        let fm = FileManager.default
        let destination = Self.uniqueDestination(in: documentsDirectory, now: now)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        var copiedItems: [String] = []
        var files = 0
        for name in CleanupPlanner.preserveNames {
            let source = dataDir.appendingPathComponent(name)
            guard fm.fileExists(atPath: source.path) else { continue }
            // A symlink standing where a preserve target should be is not data
            // we can rescue, and following it would leave the prefix entirely.
            // This is the only case where "present but nothing copied" is
            // correct, so it is excluded here rather than inferred below.
            guard !CleanupSafety.isSymbolicLink(atPath: source.path) else { continue }
            let n = try CleanupSafety.copySkippingSymlinks(
                from: source, to: destination.appendingPathComponent(name))
            files += n
            // Recorded because the source was *there*, not because it had
            // content. `Attachments` and `MyTemplates` are legitimately empty
            // until the user creates something, and an empty folder that is
            // silently dropped tells the user their data was missing when it
            // was not. `copySkippingSymlinks` has already recreated the
            // directory — including any empty subdirectories inside it.
            copiedItems.append(name)
        }

        let registryValue = NWSRegistryCapture.environmentValue(
            named: NWSRegistryCapture.valueName,
            inSystemRegAt: paths.prefix.appendingPathComponent("system.reg"))
        if let registryValue {
            let reg = NWSRegistryCapture.regFileContents(
                name: NWSRegistryCapture.valueName, value: registryValue)
            try? Data(reg.utf8).write(
                to: destination.appendingPathComponent("Windows Registry Setting.reg"))
        }

        let readme = SetupCopy.cleanupSavedReadme(items: copiedItems, registryValue: registryValue)
        try Data(readme.utf8).write(to: destination.appendingPathComponent("README.txt"))

        return PreservedData(destination: destination, itemsCopied: copiedItems,
                             filesCopied: files, registryValue: registryValue,
                             bytes: CleanupSafety.size(of: destination))
    }

    /// The production wiring, in one place so the Shell holds no path logic.
    ///
    /// `sandbox` is nil here by design: this is the live configuration, and a
    /// test that reaches it is refused outright by `assertBoundary`.
    public static func live(paths: OpenXEPaths, bundleURL: URL?) -> CleanupRunner {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let planner = CleanupPlanner.live(paths: paths)
        let prefix = paths.prefix
        let wineserver = paths.wineserverBinary
        let engineCurrent = paths.engineCurrent
        return CleanupRunner(
            planner: planner, paths: paths, home: home, sandbox: nil,
            shutdownWineserver: {
                // Ask politely first — a clean shutdown flushes the registry —
                // then reap by prefix-scoped PID, which also catches a server
                // whose socket has been reaped (see WineServerHousekeeping).
                let env = WineEnvironment.build(engineCurrent: engineCurrent, prefix: prefix)
                _ = try? Subprocess.run(wineserver, arguments: ["-k"], environment: env,
                                        timeout: 30, captureOutput: false)
                WineServerHousekeeping.reapAllServers(forPrefix: prefix)
            },
            unregisterFromLaunchServices: {
                guard let bundleURL else { return }
                _ = try? Subprocess.run(
                    URL(fileURLWithPath: "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"),
                    arguments: ["-u", bundleURL.path], timeout: 60, captureOutput: false)
            })
    }

    /// `New World Scheduler Data (saved by OpenXE 2026-08-09)`, with a numeric
    /// suffix on collision. Never overwrites an earlier rescue.
    static func uniqueDestination(in documents: URL, now: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let base = "New World Scheduler Data (saved by OpenXE \(formatter.string(from: now)))"
        let fm = FileManager.default
        var candidate = documents.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = documents.appendingPathComponent("\(base) \(n)", isDirectory: true)
            n += 1
        }
        return candidate
    }
}
