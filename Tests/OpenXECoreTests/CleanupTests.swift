import XCTest
@testable import OpenXECore

/// Cleanup is the one feature in OpenXE whose job is to delete a lot, so its
/// tests are mostly about what it must *not* delete.
///
/// Every fixture here is built inside the test's own temporary directory. No
/// test in this file can name a path on the real machine — see also
/// `CleanupBoundaryTests`, which asserts that property rather than relying on it.
final class CleanupTests: XCTestCase {

    // MARK: fixture

    /// A miniature OpenXE installation: sandbox/home/Library/... plus a prefix
    /// with the real symlink hazards in it.
    struct Fixture {
        let sandbox: URL
        let home: URL
        let library: URL
        let paths: OpenXEPaths
        let documents: URL
        let launcherDir: URL
        /// Real host files the prefix symlinks reach. Nothing may ever touch these.
        let realDocuments: URL
        let planner: CleanupPlanner

        var nwsData: URL {
            paths.prefix.appendingPathComponent("drive_c/users/testuser/AppData/Local/NW Scheduler")
        }
    }

    private var fixtures: [URL] = []

    override func tearDownWithError() throws {
        for url in fixtures { try? FileManager.default.removeItem(at: url) }
        fixtures = []
    }

    private func makeFixture(bytesPerFile: Int = 1024) throws -> Fixture {
        let fm = FileManager.default
        let sandbox = fm.temporaryDirectory
            .appendingPathComponent("openxe-cleanup-\(UUID().uuidString)", isDirectory: true)
        fixtures.append(sandbox)

        let home = sandbox.appendingPathComponent("home", isDirectory: true)
        let library = home.appendingPathComponent("Library", isDirectory: true)
        let documents = home.appendingPathComponent("Documents", isDirectory: true)
        let root = library.appendingPathComponent("Application Support/OpenXE", isDirectory: true)
        let paths = OpenXEPaths(root: root)
        let launcherDir = home.appendingPathComponent("Applications/OpenXE Apps", isDirectory: true)

        let blob = Data(repeating: 0x41, count: bytesPerFile)
        func write(_ url: URL) throws {
            try fm.createDirectory(at: url.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try blob.write(to: url)
        }

        // Host-side files the prefix links to. The whole safety story is that
        // these survive.
        try write(documents.appendingPathComponent("congregation-notes.txt"))
        try write(documents.appendingPathComponent("Family/photo.jpg"))
        try write(home.appendingPathComponent("Downloads/installer.dmg"))

        // OpenXE's own footprint.
        try write(root.appendingPathComponent("engine/gcenx-11/wine/bin/wine"))
        try write(root.appendingPathComponent("appconfigs.json"))
        try write(root.appendingPathComponent("setup-journal.json"))
        try write(root.appendingPathComponent("AppBundles/abc/Thing.app/Contents/Info.plist"))
        try write(library.appendingPathComponent("Logs/OpenXE/wine.log"))
        try write(library.appendingPathComponent("Preferences/dev.openxe.Test.plist"))
        try write(library.appendingPathComponent("Caches/dev.openxe.Test/cache.bin"))
        try write(library.appendingPathComponent("HTTPStorages/dev.openxe.Test/cookies.bin"))

        // The prefix, with the two escape routes that exist on a real machine.
        let prefix = paths.prefix
        try write(prefix.appendingPathComponent("drive_c/windows/system32/kernel32.dll"))
        try fm.createDirectory(at: prefix.appendingPathComponent("dosdevices"),
                               withIntermediateDirectories: true)
        try fm.createSymbolicLink(
            atPath: prefix.appendingPathComponent("dosdevices/z:").path,
            withDestinationPath: sandbox.path)
        let profile = prefix.appendingPathComponent("drive_c/users/testuser", isDirectory: true)
        try fm.createDirectory(at: profile, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: profile.appendingPathComponent("Documents").path,
                                  withDestinationPath: documents.path)
        try fm.createSymbolicLink(atPath: profile.appendingPathComponent("Downloads").path,
                                  withDestinationPath: home.appendingPathComponent("Downloads").path)

        // Somebody else's profile that has no NWS data, so discovery is exercised.
        try fm.createDirectory(at: prefix.appendingPathComponent("drive_c/users/Public"),
                               withIntermediateDirectories: true)

        // NWS data: seven keepers, six discards — the shape of the real
        // directory, including the two keepers that are empty on a live Mac.
        let data = profile.appendingPathComponent("AppData/Local/NW Scheduler", isDirectory: true)
        try write(data.appendingPathComponent("MyData/congregation.json"))
        try write(data.appendingPathComponent("MyData/schedule.json"))
        try write(data.appendingPathComponent("Backups/2026-08-01.NWSchedulerBackup"))
        try write(data.appendingPathComponent("Settings1.json"))
        try write(data.appendingPathComponent("RegistrationKey.json"))
        try write(data.appendingPathComponent("DataTimestamps.json"))
        // Empty today, and filled the moment the user attaches a file.
        try fm.createDirectory(at: data.appendingPathComponent("Attachments"),
                               withIntermediateDirectories: true)
        // Present as a tree of empty category folders, exactly as NWS ships it.
        for category in ["Assignment Slips", "Meeting Schedule", "Territory Cards"] {
            try fm.createDirectory(at: data.appendingPathComponent("MyTemplates/\(category)"),
                                   withIntermediateDirectories: true)
        }
        try write(data.appendingPathComponent("MeetingData/week1.json"))
        try write(data.appendingPathComponent("MinorUpdates/setup.exe"))
        try write(data.appendingPathComponent("Logs/nws.log"))
        try write(data.appendingPathComponent("MapCache/tiles.dat"))
        try write(data.appendingPathComponent("Temp/scratch.tmp"))
        try write(data.appendingPathComponent("Updates/update.zip"))

        // system.reg carrying the value nothing else records.
        let reg = """
        WINE REGISTRY Version 2

        [System\\\\ControlSet001\\\\Control\\\\Session Manager] 1783699305
        "GlobalFlag"=dword:00000000

        [System\\\\ControlSet001\\\\Control\\\\Session Manager\\\\Environment] 1783699422
        #time=1dd1085adcbd942
        "ComSpec"=str(2):"%SystemRoot%\\\\system32\\\\cmd.exe"
        "NWScheduler"="SECRET-REGISTRY-VALUE-64"
        "OS"="Windows_NT"

        [System\\\\ControlSet001\\\\Control\\\\Session Manager\\\\KnownDLLs] 1783699305
        "NWScheduler"="WRONG-SECTION"
        """
        try fm.createDirectory(at: prefix, withIntermediateDirectories: true)
        try Data(reg.utf8).write(to: prefix.appendingPathComponent("system.reg"))

        // A generated launcher, and a foreign .app that must be left alone.
        let launcher = launcherDir.appendingPathComponent("New World Scheduler.app")
        try fm.createDirectory(at: launcher.appendingPathComponent("Contents"),
                               withIntermediateDirectories: true)
        let plist: [String: Any] = [LauncherManager.targetPathKey: "/somewhere/NWS Desktop.exe"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: launcher.appendingPathComponent("Contents/Info.plist"))
        let foreign = launcherDir.appendingPathComponent("Someone Elses.app")
        try fm.createDirectory(at: foreign.appendingPathComponent("Contents"),
                               withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleName": "Other"],
                                           format: .xml, options: 0)
            .write(to: foreign.appendingPathComponent("Contents/Info.plist"))

        let planner = CleanupPlanner(paths: paths, home: home, library: library,
                                     bundleIdentifier: "dev.openxe.Test",
                                     launcherDirectories: [launcherDir])
        return Fixture(sandbox: sandbox, home: home, library: library, paths: paths,
                       documents: documents, launcherDir: launcherDir,
                       realDocuments: documents, planner: planner)
    }

    private func makeRunner(
        _ f: Fixture,
        log: SetupLog? = nil,
        shutdown: @escaping @Sendable () -> Void = {},
        unregister: @escaping @Sendable () -> LaunchServicesUnregistration = { .noBundle }
    ) -> CleanupRunner {
        CleanupRunner(planner: f.planner, paths: f.paths, home: f.home, sandbox: f.sandbox,
                      log: log, shutdownWineserver: shutdown,
                      unregisterFromLaunchServices: unregister)
    }

    /// The log lives where it lives on a real Mac — inside `Logs/OpenXE`, which
    /// the removal itself deletes. That is the interesting part.
    private func logURL(_ f: Fixture) -> URL {
        f.library.appendingPathComponent("Logs/OpenXE/setup.log")
    }

    // MARK: symlink containment — the reason this feature needs tests

    func testSizingNeverFollowsASymlinkOutOfThePrefix() throws {
        let f = try makeFixture(bytesPerFile: 4096)
        // The profile holds links to Documents and Downloads, which between them
        // hold three 4 KB files. If sizing followed them, the profile would
        // measure at least 12 KB more than its own content.
        let profile = f.paths.prefix.appendingPathComponent("drive_c/users/testuser")
        let measured = CleanupSafety.size(of: profile)
        let ownContent = CleanupSafety.size(
            of: profile.appendingPathComponent("AppData/Local/NW Scheduler"))
        XCTAssertEqual(measured, ownContent,
                       "sizing traversed a symlink out of the prefix")

        // And `dosdevices/z:` maps to the whole sandbox — following it would
        // recurse into the prefix itself.
        let dosdevices = f.paths.prefix.appendingPathComponent("dosdevices")
        XCTAssertEqual(CleanupSafety.size(of: dosdevices), 0)
    }

    func testDeletingThePrefixRemovesTheLinksAndNotTheRealFolders() throws {
        let f = try makeFixture()
        let fm = FileManager.default
        let realNote = f.documents.appendingPathComponent("congregation-notes.txt")
        let realPhoto = f.documents.appendingPathComponent("Family/photo.jpg")
        let realDownload = f.home.appendingPathComponent("Downloads/installer.dmg")

        let plan = f.planner.plan()
        _ = try makeRunner(f).run(plan: plan, keepNWSData: false,
                                  documentsDirectory: f.documents, now: Date())

        XCTAssertFalse(fm.fileExists(atPath: f.paths.root.path), "the footprint survived")
        XCTAssertTrue(fm.fileExists(atPath: realNote.path),
                      "deletion followed a symlink into the real Documents folder")
        XCTAssertTrue(fm.fileExists(atPath: realPhoto.path))
        XCTAssertTrue(fm.fileExists(atPath: realDownload.path))
        XCTAssertTrue(fm.fileExists(atPath: f.documents.path))
    }

    func testCopyingNeverFollowsASymlink() throws {
        let f = try makeFixture()
        let fm = FileManager.default
        // Plant a link inside the preserve set pointing at the real Documents.
        try fm.createSymbolicLink(
            atPath: f.nwsData.appendingPathComponent("MyData/escape").path,
            withDestinationPath: f.documents.path)

        let destination = f.sandbox.appendingPathComponent("copy-out", isDirectory: true)
        let copied = try CleanupSafety.copySkippingSymlinks(
            from: f.nwsData.appendingPathComponent("MyData"), to: destination)

        XCTAssertEqual(copied, 2, "expected the two real files, and not the link's target")
        XCTAssertFalse(fm.fileExists(atPath: destination.appendingPathComponent("escape").path))
    }

    // MARK: the allowlist

    func testForbiddenPathsAreNeverDeletable() throws {
        let f = try makeFixture()
        let roots = f.planner.allowedRoots
        for bad in [URL(fileURLWithPath: "/"), f.home, f.documents,
                    f.home.appendingPathComponent("Downloads"),
                    f.home.appendingPathComponent("Desktop"),
                    f.library] {
            XCTAssertFalse(CleanupSafety.isDeletable(bad, allowedRoots: roots, home: f.home),
                           "\(bad.path) must never be deletable")
        }
    }

    func testPathsOutsideTheRootsAreRejected() throws {
        let f = try makeFixture()
        let roots = f.planner.allowedRoots
        XCTAssertFalse(CleanupSafety.isDeletable(
            f.documents.appendingPathComponent("congregation-notes.txt"),
            allowedRoots: roots, home: f.home))
        XCTAssertFalse(CleanupSafety.isDeletable(
            URL(fileURLWithPath: "/System/Library"), allowedRoots: roots, home: f.home))
    }

    func testDotDotEscapeIsRejected() throws {
        let f = try makeFixture()
        let roots = f.planner.allowedRoots
        let escape = f.paths.root.appendingPathComponent("../../../Documents")
        XCTAssertFalse(CleanupSafety.isDeletable(escape, allowedRoots: roots, home: f.home))
    }

    /// A string-prefix containment test would accept this.
    func testSiblingDirectoryWithASharedNamePrefixIsRejected() throws {
        let f = try makeFixture()
        let roots = f.planner.allowedRoots
        let lookalike = f.launcherDir.deletingLastPathComponent()
            .appendingPathComponent("OpenXE Apps Backup")
        XCTAssertFalse(CleanupSafety.isDeletable(lookalike, allowedRoots: roots, home: f.home))
    }

    func testTheFootprintItselfIsDeletable() throws {
        let f = try makeFixture()
        let roots = f.planner.allowedRoots
        for good in [f.paths.root, f.paths.prefix, f.paths.engineVersions,
                     f.library.appendingPathComponent("Logs/OpenXE"),
                     f.launcherDir.appendingPathComponent("New World Scheduler.app")] {
            XCTAssertTrue(CleanupSafety.isDeletable(good, allowedRoots: roots, home: f.home),
                          "\(good.path) should be removable")
        }
    }

    // MARK: enumeration

    func testPlanFindsEveryPartOfTheFootprint() throws {
        let f = try makeFixture()
        let plan = f.planner.plan()
        let paths = Set(plan.targets.map(\.url.path))

        XCTAssertTrue(paths.contains(f.paths.root.path))
        XCTAssertTrue(paths.contains(f.library.appendingPathComponent("Logs/OpenXE").path))
        XCTAssertTrue(paths.contains(
            f.library.appendingPathComponent("Preferences/dev.openxe.Test.plist").path))
        XCTAssertTrue(paths.contains(f.library.appendingPathComponent("Caches/dev.openxe.Test").path))
        XCTAssertTrue(paths.contains(
            f.library.appendingPathComponent("HTTPStorages/dev.openxe.Test").path))
        XCTAssertTrue(paths.contains(
            f.launcherDir.appendingPathComponent("New World Scheduler.app").path))

        // Never present: the saved-state dir was not created in the fixture.
        XCTAssertFalse(paths.contains(
            f.library.appendingPathComponent("Saved Application State/dev.openxe.Test.savedState").path))
    }

    func testPlanIgnoresAppsOpenXEDidNotGenerate() throws {
        let f = try makeFixture()
        let plan = f.planner.plan()
        XCTAssertEqual(plan.launcherCount, 1)
        XCTAssertFalse(plan.targets.contains {
            $0.url.lastPathComponent == "Someone Elses.app"
        })
    }

    func testPlanLocatesNWSDataAndSizesItSeparately() throws {
        let f = try makeFixture(bytesPerFile: 1000)
        let plan = f.planner.plan()
        XCTAssertEqual(plan.nwsDataDirectory?.path, f.nwsData.path)
        XCTAssertEqual(plan.nwsDataBytes, 12000, "twelve 1000-byte files in the data directory")
        XCTAssertEqual(plan.preservableBytes, 6000,
                       "MyData (2), Backups (1), and the three JSON files; "
                       + "the two empty folders add nothing")
    }

    /// Sizing must not treat an empty preserve target as a reason to report
    /// nothing preservable — nor inflate the figure with folders that hold none.
    func testEmptyPreserveTargetsContributeNoBytesButDoNotBreakSizing() throws {
        let f = try makeFixture(bytesPerFile: 1000)
        XCTAssertEqual(CleanupSafety.size(of: f.nwsData.appendingPathComponent("Attachments")), 0)
        XCTAssertEqual(CleanupSafety.size(of: f.nwsData.appendingPathComponent("MyTemplates")), 0)
        XCTAssertGreaterThan(f.planner.plan().preservableBytes, 0)
    }

    func testPlanTotalDoesNotDoubleCountNWSData() throws {
        let f = try makeFixture()
        let plan = f.planner.plan()
        let support = try XCTUnwrap(plan.targets.first { $0.url == f.paths.root })
        XCTAssertEqual(plan.totalBytes, plan.targets.reduce(0) { $0 + $1.sizeBytes })
        XCTAssertGreaterThan(support.sizeBytes, plan.nwsDataBytes,
                             "NWS data is inside the support folder, counted once")
    }

    func testPlanOnACleanMachineIsEmpty() throws {
        let fm = FileManager.default
        let sandbox = fm.temporaryDirectory
            .appendingPathComponent("openxe-empty-\(UUID().uuidString)", isDirectory: true)
        fixtures.append(sandbox)
        try fm.createDirectory(at: sandbox, withIntermediateDirectories: true)
        let home = sandbox.appendingPathComponent("home")
        let planner = CleanupPlanner(
            paths: OpenXEPaths(root: home.appendingPathComponent("Library/Application Support/OpenXE")),
            home: home, library: home.appendingPathComponent("Library"),
            bundleIdentifier: "dev.openxe.Test",
            launcherDirectories: [home.appendingPathComponent("Applications/OpenXE Apps")])
        XCTAssertTrue(planner.plan().isEmpty)
    }

    // MARK: registry capture

    func testRegistryValueIsReadFromTheRightSection() throws {
        let f = try makeFixture()
        let value = NWSRegistryCapture.environmentValue(
            named: "NWScheduler",
            inSystemRegAt: f.paths.prefix.appendingPathComponent("system.reg"))
        XCTAssertEqual(value, "SECRET-REGISTRY-VALUE-64",
                       "picked up the KnownDLLs decoy instead of the Environment section")
    }

    func testRegistryValueIsAbsentWhenNWSWasNeverInstalled() {
        let reg = """
        [System\\\\ControlSet001\\\\Control\\\\Session Manager\\\\Environment] 1
        "OS"="Windows_NT"
        """
        XCTAssertNil(NWSRegistryCapture.environmentValue(named: "NWScheduler", inSystemReg: reg))
    }

    func testRegFileIsImportable() {
        let text = NWSRegistryCapture.regFileContents(name: "NWScheduler", value: "abc")
        XCTAssertTrue(text.hasPrefix("Windows Registry Editor Version 5.00"))
        XCTAssertTrue(text.contains(#"Session Manager\Environment]"#))
        XCTAssertTrue(text.contains(#""NWScheduler"="abc""#))
    }

    // MARK: preservation

    func testKeepingDataCopiesExactlyTheSevenTargets() throws {
        let f = try makeFixture()
        let fm = FileManager.default
        let outcome = try makeRunner(f).run(plan: f.planner.plan(), keepNWSData: true,
                                            documentsDirectory: f.documents, now: Date())
        let saved = try XCTUnwrap(outcome.preserved)

        XCTAssertEqual(Set(saved.itemsCopied),
                       Set(["MyData", "Backups", "Settings1.json", "RegistrationKey.json",
                            "DataTimestamps.json", "Attachments", "MyTemplates"]))
        XCTAssertEqual(saved.filesCopied, 6, "the two empty folders hold no files to count")
        for keep in ["MyData/congregation.json", "MyData/schedule.json",
                     "Backups/2026-08-01.NWSchedulerBackup",
                     "Settings1.json", "RegistrationKey.json", "DataTimestamps.json"] {
            XCTAssertTrue(fm.fileExists(atPath: saved.destination.appendingPathComponent(keep).path),
                          "\(keep) was not preserved")
        }
        for discard in ["MeetingData", "MinorUpdates", "Logs", "MapCache", "Temp", "Updates"] {
            XCTAssertFalse(
                fm.fileExists(atPath: saved.destination.appendingPathComponent(discard).path),
                "\(discard) should not have been preserved")
        }
    }

    /// `Attachments` is empty on the real Mac today. If the copy path for an
    /// empty folder is broken, nothing here notices until the day the user has
    /// attachments and they do not come back.
    func testAnEmptyAttachmentsFolderIsRescuedAsAFolder() throws {
        let f = try makeFixture()
        let fm = FileManager.default
        let outcome = try makeRunner(f).run(plan: f.planner.plan(), keepNWSData: true,
                                            documentsDirectory: f.documents, now: Date())
        let saved = try XCTUnwrap(outcome.preserved)

        XCTAssertTrue(saved.itemsCopied.contains("Attachments"))
        var isDir: ObjCBool = false
        XCTAssertTrue(
            fm.fileExists(atPath: saved.destination.appendingPathComponent("Attachments").path,
                          isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    /// The same folder once the user has actually attached something.
    func testAPopulatedAttachmentsFolderIsRescuedWithItsContents() throws {
        let f = try makeFixture()
        let fm = FileManager.default
        let attachments = f.nwsData.appendingPathComponent("Attachments")
        try Data("scan".utf8).write(to: attachments.appendingPathComponent("hall-contract.pdf"))
        try fm.createDirectory(at: attachments.appendingPathComponent("Photos"),
                               withIntermediateDirectories: true)
        try Data("jpeg".utf8).write(
            to: attachments.appendingPathComponent("Photos/territory-map.jpg"))

        let outcome = try makeRunner(f).run(plan: f.planner.plan(), keepNWSData: true,
                                            documentsDirectory: f.documents, now: Date())
        let saved = try XCTUnwrap(outcome.preserved)

        XCTAssertTrue(saved.itemsCopied.contains("Attachments"))
        XCTAssertEqual(saved.filesCopied, 8, "six files plus the two attachments")
        for keep in ["Attachments/hall-contract.pdf", "Attachments/Photos/territory-map.jpg"] {
            XCTAssertTrue(fm.fileExists(atPath: saved.destination.appendingPathComponent(keep).path),
                          "\(keep) was not preserved")
        }
    }

    /// `MyTemplates` is a tree of empty category folders. The structure itself is
    /// the user's work, so it has to survive even with no files in it.
    func testMyTemplatesEmptyCategoryFoldersSurviveTheRescue() throws {
        let f = try makeFixture()
        let fm = FileManager.default
        let outcome = try makeRunner(f).run(plan: f.planner.plan(), keepNWSData: true,
                                            documentsDirectory: f.documents, now: Date())
        let saved = try XCTUnwrap(outcome.preserved)

        XCTAssertTrue(saved.itemsCopied.contains("MyTemplates"))
        for category in ["Assignment Slips", "Meeting Schedule", "Territory Cards"] {
            var isDir: ObjCBool = false
            let url = saved.destination.appendingPathComponent("MyTemplates/\(category)")
            XCTAssertTrue(fm.fileExists(atPath: url.path, isDirectory: &isDir),
                          "the empty category folder \(category) was not recreated")
            XCTAssertTrue(isDir.boolValue)
        }
    }

    func testAPopulatedMyTemplatesFolderIsRescuedWithItsContents() throws {
        let f = try makeFixture()
        let fm = FileManager.default
        try Data("template".utf8).write(
            to: f.nwsData.appendingPathComponent("MyTemplates/Assignment Slips/S-89.nwstemplate"))

        let outcome = try makeRunner(f).run(plan: f.planner.plan(), keepNWSData: true,
                                            documentsDirectory: f.documents, now: Date())
        let saved = try XCTUnwrap(outcome.preserved)
        XCTAssertTrue(fm.fileExists(atPath: saved.destination
            .appendingPathComponent("MyTemplates/Assignment Slips/S-89.nwstemplate").path))
        XCTAssertEqual(saved.filesCopied, 7)
    }

    /// `DataTimestamps.json` is meaningless on its own — it pairs with MyData,
    /// so losing it while keeping the database is the failure to guard against.
    func testDataTimestampsIsRescuedAlongsideMyData() throws {
        let f = try makeFixture()
        let fm = FileManager.default
        try Data(#"{"MyData":"2026-08-09"}"#.utf8)
            .write(to: f.nwsData.appendingPathComponent("DataTimestamps.json"))

        let outcome = try makeRunner(f).run(plan: f.planner.plan(), keepNWSData: true,
                                            documentsDirectory: f.documents, now: Date())
        let saved = try XCTUnwrap(outcome.preserved)
        let restored = try String(
            contentsOf: saved.destination.appendingPathComponent("DataTimestamps.json"),
            encoding: .utf8)
        XCTAssertEqual(restored, #"{"MyData":"2026-08-09"}"#)
        XCTAssertTrue(fm.fileExists(
            atPath: saved.destination.appendingPathComponent("MyData/congregation.json").path))
    }

    /// Every name in the preserve set must be explained in the README. A name
    /// added to the set without copy for it lands in the user's Documents folder
    /// as an unlabelled folder they will not recognise in five years.
    func testEveryPreservedItemIsExplainedInTheReadme() throws {
        let f = try makeFixture()
        let outcome = try makeRunner(f).run(plan: f.planner.plan(), keepNWSData: true,
                                            documentsDirectory: f.documents, now: Date())
        let saved = try XCTUnwrap(outcome.preserved)
        XCTAssertEqual(Set(saved.itemsCopied), Set(CleanupPlanner.preserveNames))

        let readme = try String(
            contentsOf: saved.destination.appendingPathComponent("README.txt"), encoding: .utf8)
        for name in CleanupPlanner.preserveNames {
            guard let line = readme.split(separator: "\n").first(where: {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix(name)
            }) else {
                return XCTFail("\(name) is not listed in the README")
            }
            XCTAssertTrue(line.contains(" - "), "\(name) is listed but not explained")
        }
    }

    /// The path least likely to be exercised by accident.
    ///
    /// A preserved folder that exists but holds nothing must still be rescued as
    /// a folder and still be reported. The obvious implementation — "record it
    /// if we copied at least one file" — drops it silently, and the user is told
    /// their folder was not there when in fact it was empty.
    func testAnEmptyPreservedFolderIsStillRescuedAndReported() throws {
        let f = try makeFixture()
        let fm = FileManager.default
        let backups = f.nwsData.appendingPathComponent("Backups")
        try fm.removeItem(at: backups)
        try fm.createDirectory(at: backups, withIntermediateDirectories: true)
        XCTAssertTrue(try fm.contentsOfDirectory(atPath: backups.path).isEmpty)

        let outcome = try makeRunner(f).run(plan: f.planner.plan(), keepNWSData: true,
                                            documentsDirectory: f.documents, now: Date())
        let saved = try XCTUnwrap(outcome.preserved)

        XCTAssertTrue(saved.itemsCopied.contains("Backups"),
                      "an empty folder was silently dropped from the rescue")
        var isDir: ObjCBool = false
        XCTAssertTrue(
            fm.fileExists(atPath: saved.destination.appendingPathComponent("Backups").path,
                          isDirectory: &isDir),
            "the empty folder was not recreated in the rescue copy")
        XCTAssertTrue(isDir.boolValue, "the empty folder came back as a file")

        let readme = try String(
            contentsOf: saved.destination.appendingPathComponent("README.txt"), encoding: .utf8)
        XCTAssertTrue(readme.contains("Backups"),
                      "the README must list a folder that was rescued empty")
    }

    /// An empty folder must not be mistaken for a failure either — the rescue
    /// continues and the rest of the set still arrives.
    func testAnEmptyPreservedFolderDoesNotAbortTheRescue() throws {
        let f = try makeFixture()
        let fm = FileManager.default
        try fm.removeItem(at: f.nwsData.appendingPathComponent("Backups"))
        try fm.createDirectory(at: f.nwsData.appendingPathComponent("Backups"),
                               withIntermediateDirectories: true)

        let outcome = try makeRunner(f).run(plan: f.planner.plan(), keepNWSData: true,
                                            documentsDirectory: f.documents, now: Date())
        let saved = try XCTUnwrap(outcome.preserved)
        XCTAssertEqual(saved.filesCopied, 5, "the empty folder cost us the other five files")
        for keep in ["MyData/congregation.json", "MyData/schedule.json",
                     "Settings1.json", "RegistrationKey.json", "DataTimestamps.json"] {
            XCTAssertTrue(fm.fileExists(atPath: saved.destination.appendingPathComponent(keep).path),
                          "\(keep) was lost when an empty folder was encountered")
        }
    }

    /// A symlink standing where a preserve target should be is not data we can
    /// rescue, and following it would leave the prefix. It must be skipped *and*
    /// not reported as saved — the one case where "nothing copied" is correct.
    func testASymlinkedPreserveTargetIsSkippedAndNotClaimed() throws {
        let f = try makeFixture()
        let fm = FileManager.default
        try fm.removeItem(at: f.nwsData.appendingPathComponent("Backups"))
        try fm.createSymbolicLink(
            atPath: f.nwsData.appendingPathComponent("Backups").path,
            withDestinationPath: f.documents.path)

        let outcome = try makeRunner(f).run(plan: f.planner.plan(), keepNWSData: true,
                                            documentsDirectory: f.documents, now: Date())
        let saved = try XCTUnwrap(outcome.preserved)
        XCTAssertFalse(saved.itemsCopied.contains("Backups"),
                       "a symlink was reported as rescued data")
        XCTAssertFalse(
            fm.fileExists(atPath: saved.destination.appendingPathComponent("Backups").path),
            "a symlink out of the prefix was copied into the rescue")
        XCTAssertTrue(fm.fileExists(
            atPath: f.documents.appendingPathComponent("congregation-notes.txt").path))
    }

    func testPreservationCapturesTheRegistryValueThatWouldOtherwiseBeLost() throws {
        let f = try makeFixture()
        let outcome = try makeRunner(f).run(plan: f.planner.plan(), keepNWSData: true,
                                            documentsDirectory: f.documents, now: Date())
        let saved = try XCTUnwrap(outcome.preserved)
        XCTAssertEqual(saved.registryValue, "SECRET-REGISTRY-VALUE-64")

        let regFile = saved.destination.appendingPathComponent("Windows Registry Setting.reg")
        let text = try String(contentsOf: regFile, encoding: .utf8)
        XCTAssertTrue(text.contains("SECRET-REGISTRY-VALUE-64"))

        // Belt and braces: the plain-text README carries it too, because a .reg
        // file means nothing to whoever finds this folder in five years.
        let readme = try String(
            contentsOf: saved.destination.appendingPathComponent("README.txt"), encoding: .utf8)
        XCTAssertTrue(readme.contains("SECRET-REGISTRY-VALUE-64"))
    }

    /// The README is where the DPAPI finding of spec §4.3 is recorded for the
    /// user. If it stops saying so, a licence can be lost without explanation.
    func testReadmeWarnsThatTheLicenceIsAccountBound() throws {
        let f = try makeFixture()
        let outcome = try makeRunner(f).run(plan: f.planner.plan(), keepNWSData: true,
                                            documentsDirectory: f.documents, now: Date())
        let saved = try XCTUnwrap(outcome.preserved)
        let readme = try String(
            contentsOf: saved.destination.appendingPathComponent("README.txt"), encoding: .utf8)
        XCTAssertTrue(readme.contains("account name"))
        XCTAssertTrue(readme.contains("registered again"))
        XCTAssertTrue(readme.contains("MyData is not affected"))
    }

    func testPreservedDataSurvivesTheDeletionItPrecedes() throws {
        let f = try makeFixture()
        let fm = FileManager.default
        let outcome = try makeRunner(f).run(plan: f.planner.plan(), keepNWSData: true,
                                            documentsDirectory: f.documents, now: Date())
        let saved = try XCTUnwrap(outcome.preserved)

        XCTAssertFalse(fm.fileExists(atPath: f.paths.root.path), "the prefix should be gone")
        XCTAssertTrue(fm.fileExists(atPath: saved.destination.path),
                      "the rescue copy must not live inside what gets deleted")
        XCTAssertTrue(CleanupSafety.isContained(saved.destination, in: f.documents),
                      "preserved data must land in Documents, where a user will find it")
    }

    func testDeletingDataMakesNoCopy() throws {
        let f = try makeFixture()
        let outcome = try makeRunner(f).run(plan: f.planner.plan(), keepNWSData: false,
                                            documentsDirectory: f.documents, now: Date())
        XCTAssertNil(outcome.preserved)
        let entries = try FileManager.default.contentsOfDirectory(atPath: f.documents.path)
        XCTAssertFalse(entries.contains { $0.hasPrefix("New World Scheduler Data") })
    }

    func testASecondRemovalDoesNotOverwriteTheFirstRescue() throws {
        let f = try makeFixture()
        let fm = FileManager.default
        let now = Date()
        let first = CleanupRunner.uniqueDestination(in: f.documents, now: now)
        try fm.createDirectory(at: first, withIntermediateDirectories: true)
        let second = CleanupRunner.uniqueDestination(in: f.documents, now: now)
        XCTAssertNotEqual(first.path, second.path)
        XCTAssertTrue(second.lastPathComponent.hasSuffix(" 2"))
    }

    func testPreservationFailureRemovesNothing() throws {
        let f = try makeFixture()
        let fm = FileManager.default
        // A destination that cannot be created, so the rescue copy fails.
        let impossible = URL(fileURLWithPath: "/dev/null/nope")
        XCTAssertThrowsError(
            try makeRunner(f).run(plan: f.planner.plan(), keepNWSData: true,
                                  documentsDirectory: impossible, now: Date())
        ) { error in
            guard case CleanupError.preserveFailed = error else {
                return XCTFail("expected preserveFailed, got \(error)")
            }
        }
        XCTAssertTrue(fm.fileExists(atPath: f.paths.root.path),
                      "a failed rescue must abort before deleting anything")
        XCTAssertTrue(fm.fileExists(atPath: f.nwsData.appendingPathComponent("MyData").path))
    }

    // MARK: ordering and reporting

    func testWineserverIsShutDownBeforeAnythingIsDeleted() throws {
        let f = try makeFixture()
        let prefixPath = f.paths.prefix.path
        // Records whether the prefix still existed at shutdown time. It must.
        final class Box: @unchecked Sendable { var prefixAliveAtShutdown = false; var calls = 0 }
        let box = Box()
        let runner = makeRunner(f, shutdown: {
            box.calls += 1
            box.prefixAliveAtShutdown = FileManager.default.fileExists(atPath: prefixPath)
        })
        _ = try runner.run(plan: f.planner.plan(), keepNWSData: true,
                           documentsDirectory: f.documents, now: Date())
        XCTAssertEqual(box.calls, 1)
        XCTAssertTrue(box.prefixAliveAtShutdown,
                      "wineserver must be stopped while it still holds the prefix")
    }

    func testLaunchServicesIsUnregistered() throws {
        let f = try makeFixture()
        final class Box: @unchecked Sendable { var calls = 0 }
        let box = Box()
        let outcome = try makeRunner(f, unregister: {
            box.calls += 1
            return .unregistered(path: "/Applications/OpenXE.app")
        }).run(plan: f.planner.plan(), keepNWSData: false,
               documentsDirectory: f.documents, now: Date())
        XCTAssertEqual(box.calls, 1)
        XCTAssertEqual(outcome.unregistration, .unregistered(path: "/Applications/OpenXE.app"),
                       "the outcome must carry what actually happened to the registration")
    }

    func testOutcomeReportsWhatWasRemovedAndReclaimed() throws {
        let f = try makeFixture()
        let plan = f.planner.plan()
        let outcome = try makeRunner(f).run(plan: plan, keepNWSData: false,
                                            documentsDirectory: f.documents, now: Date())
        XCTAssertEqual(outcome.removed.count, plan.targets.count)
        XCTAssertEqual(outcome.reclaimedBytes, plan.totalBytes)
        XCTAssertEqual(outcome.launchersRemoved, 1)
        XCTAssertTrue(outcome.skipped.isEmpty, "unexpected skips: \(outcome.skipped)")
    }

    func testATargetOutsideTheAllowlistIsSkippedNotDeleted() throws {
        let f = try makeFixture()
        let fm = FileManager.default
        let outsider = f.documents.appendingPathComponent("congregation-notes.txt")
        var plan = f.planner.plan()
        plan = CleanupPlan(
            targets: plan.targets + [CleanupTarget(url: outsider, label: "smuggled", sizeBytes: 1)],
            nwsDataDirectory: plan.nwsDataDirectory, nwsDataBytes: plan.nwsDataBytes,
            preservableBytes: plan.preservableBytes, launcherCount: plan.launcherCount)

        let outcome = try makeRunner(f).run(plan: plan, keepNWSData: false,
                                            documentsDirectory: f.documents, now: Date())
        XCTAssertTrue(fm.fileExists(atPath: outsider.path),
                      "the allowlist did not stop a target outside OpenXE's own tree")
        XCTAssertEqual(outcome.skipped.count, 1)
        XCTAssertTrue(outcome.skipped[0].contains("smuggled"))
    }

    func testRemovalIsIdempotent() throws {
        let f = try makeFixture()
        let runner = makeRunner(f)
        _ = try runner.run(plan: f.planner.plan(), keepNWSData: false,
                           documentsDirectory: f.documents, now: Date())
        let second = try runner.run(plan: f.planner.plan(), keepNWSData: false,
                                    documentsDirectory: f.documents, now: Date())
        XCTAssertTrue(second.removed.isEmpty)
        XCTAssertTrue(second.skipped.isEmpty)
    }

    // MARK: the log
    //
    // A removal that half-runs used to leave no trace at all: establishing
    // whether the user's Remove had run took inode birth times. One file must
    // answer "did cleanup run, and what did it do?" — including when it aborted,
    // and including when it deleted the log directory it was writing into.

    func testTheLogRecordsThePlanTheRescueAndEveryRemoval() throws {
        let f = try makeFixture()
        let url = logURL(f)
        let plan = f.planner.plan()
        _ = try makeRunner(f, log: try SetupLog(url: url), unregister: {
            .unregistered(path: "/Applications/OpenXE.app")
        }).run(plan: plan, keepNWSData: true, documentsDirectory: f.documents, now: Date())

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains(CleanupRunner.logBeginBanner))
        XCTAssertTrue(text.contains(CleanupRunner.logEndBanner))
        XCTAssertTrue(text.contains("keepNWSData=true"))

        // What was planned, by path, before anything happened.
        for target in plan.targets {
            XCTAssertTrue(text.contains("plan: \(target.label) [\(target.url.path)]"),
                          "the plan did not record \(target.url.path)")
        }
        // What was preserved, and where it went.
        XCTAssertTrue(text.contains("preserved"))
        XCTAssertTrue(text.contains("New World Scheduler Data (saved by OpenXE"))
        XCTAssertTrue(text.contains("MyData"))
        // What was removed.
        for target in plan.targets {
            XCTAssertTrue(text.contains("removed: \(target.label) [\(target.url.path)]"),
                          "the removal of \(target.url.path) is not in the log")
        }
        // What happened to the handler registration, and the outcome.
        XCTAssertTrue(
            text.contains("asked LaunchServices to drop the .exe handler: /Applications/OpenXE.app"))
        XCTAssertTrue(text.contains("outcome: removed=\(plan.targets.count) skipped=0"))
    }

    /// The removal deletes `Logs/OpenXE`. Without re-opening the log afterwards,
    /// the successful case is the one case that leaves no record — writes land on
    /// an unlinked inode and the file is simply gone.
    func testTheLogSurvivesTheDeletionOfItsOwnDirectory() throws {
        let f = try makeFixture()
        let url = logURL(f)
        let plan = f.planner.plan()
        XCTAssertTrue(plan.targets.contains { $0.url.lastPathComponent == "OpenXE"
                                              && $0.url.path.contains("Logs") },
                      "fixture must plan to delete the log directory, or this proves nothing")

        _ = try makeRunner(f, log: try SetupLog(url: url))
            .run(plan: plan, keepNWSData: false, documentsDirectory: f.documents, now: Date())

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "the cleanup deleted its own log and left no record that it ran")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("re-created"), "the re-created log must say why it is short")
        XCTAssertTrue(text.contains(CleanupRunner.logBeginBanner),
                      "the whole transcript must be replayed, not just the tail")
        XCTAssertTrue(text.contains("plan: "))
        XCTAssertTrue(text.contains("removed: "))
        XCTAssertTrue(text.contains(CleanupRunner.logEndBanner))
    }

    /// The transcript is replayed into a log the removal had to re-create. It has
    /// to arrive carrying the instants the lines were said at: a real 2.7-second
    /// removal replayed twenty lines all reading `19:46:57`, and per-step timing
    /// is precisely what is wanted when a large delete stalls.
    ///
    /// The stamps are second-resolution, so the test buys a real gap by making
    /// the shutdown step slow rather than by hoping the run is.
    func testTheReplayKeepsEachLinesOwnTimestamp() throws {
        let f = try makeFixture()
        let url = logURL(f)
        _ = try makeRunner(f, log: try SetupLog(url: url),
                           shutdown: { Thread.sleep(forTimeInterval: 1.2) })
            .run(plan: f.planner.plan(), keepNWSData: false,
                 documentsDirectory: f.documents, now: Date())

        // The original file was unlinked with its directory, so everything here
        // is the replay plus what followed it.
        let text = try String(contentsOf: url, encoding: .utf8)
        func stamp(ofLineContaining needle: String) throws -> String {
            let line = try XCTUnwrap(text.split(separator: "\n").first { $0.contains(needle) },
                                     "no line containing \(needle)")
            return String(line.prefix(while: { $0 != " " }))
        }
        let begin = try stamp(ofLineContaining: CleanupRunner.logBeginBanner)
        let stopped = try stamp(ofLineContaining: "stopped the Windows environment")
        let recreated = try stamp(ofLineContaining: "re-created here")

        XCTAssertNotEqual(begin, stopped,
                          "the replay restamped every line with a single instant (\(begin))")
        // ISO 8601 in UTC sorts lexicographically, so this is a real ordering.
        XCTAssertLessThan(begin, stopped)
        XCTAssertLessThan(begin, recreated,
                          "a replayed line must predate the note that introduces the replay")
    }

    func testAnAbortedCleanupSaysWhatStoppedItAndThatNothingWasRemoved() throws {
        let f = try makeFixture()
        let url = logURL(f)
        let impossible = URL(fileURLWithPath: "/dev/null/nope")
        XCTAssertThrowsError(
            try makeRunner(f, log: try SetupLog(url: url))
                .run(plan: f.planner.plan(), keepNWSData: true,
                     documentsDirectory: impossible, now: Date()))

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains(CleanupRunner.logBeginBanner))
        XCTAssertTrue(text.contains("ABORTED"))
        XCTAssertTrue(text.contains("nothing was removed"))
        XCTAssertFalse(text.contains("removed: "), "an aborted run must not claim removals")
        XCTAssertTrue(text.contains(CleanupRunner.logEndBanner),
                      "an aborted run still closes its record")
    }

    func testASkippedTargetIsNamedInTheLogWithItsReason() throws {
        let f = try makeFixture()
        let url = logURL(f)
        var plan = f.planner.plan()
        let outsider = f.documents.appendingPathComponent("congregation-notes.txt")
        plan = CleanupPlan(
            targets: [CleanupTarget(url: outsider, label: "smuggled", sizeBytes: 1)] + plan.targets,
            nwsDataDirectory: plan.nwsDataDirectory, nwsDataBytes: plan.nwsDataBytes,
            preservableBytes: plan.preservableBytes, launcherCount: plan.launcherCount)

        _ = try makeRunner(f, log: try SetupLog(url: url))
            .run(plan: plan, keepNWSData: false, documentsDirectory: f.documents, now: Date())

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("SKIPPED: smuggled"))
        XCTAssertTrue(text.contains("outside the area OpenXE is allowed to remove"))
        XCTAssertTrue(text.contains("skipped=1"))
    }

    /// The translocation refusal has to be legible in the log, or the user is
    /// left with an .exe handler that quietly outlived the removal.
    func testARefusedUnregistrationIsRecorded() throws {
        let f = try makeFixture()
        let url = logURL(f)
        let translocated = "/private/var/folders/z4/T/AppTranslocation/ABC/d/OpenXE.app"
        let outcome = try makeRunner(f, log: try SetupLog(url: url), unregister: {
            .refusedUnresolvedTranslocation(translocated: translocated)
        }).run(plan: f.planner.plan(), keepNWSData: false,
               documentsDirectory: f.documents, now: Date())

        XCTAssertEqual(outcome.unregistration,
                       .refusedUnresolvedTranslocation(translocated: translocated))
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("DID NOT unregister the .exe handler"))
        XCTAssertTrue(text.contains(translocated))
    }

    // MARK: the .exe handler claim
    //
    // `lsregister -u` ran and the log said "unregistered the .exe handler". Four
    // minutes later the bundle was registered again and still claiming
    // com.microsoft.windows-executable: LaunchServices rescans /Applications and
    // re-reads CFBundleDocumentTypes. The registration coming back is not the
    // defect — the log asserting a permanence the system undoes is.

    func testTheHandlerLogLineDoesNotClaimAnUnregistrationThatDoesNotStick() {
        let caveat = LaunchServicesUnregistration.doesNotPersistNote
        let plain = LaunchServicesUnregistration.unregistered(path: "/Applications/OpenXE.app")
        XCTAssertFalse(plain.logLine.hasPrefix("unregistered the .exe handler"),
                       "the log states as fact something LaunchServices undoes: \(plain.logLine)")
        XCTAssertTrue(plain.logLine.hasPrefix("asked LaunchServices to drop the .exe handler"))
        XCTAssertTrue(plain.logLine.contains("/Applications/OpenXE.app"))
        XCTAssertTrue(plain.logLine.contains(caveat), plain.logLine)

        let translocated = LaunchServicesUnregistration.unregisteredAfterTranslocation(
            real: "/Applications/OpenXE.app",
            translocated: "/private/var/folders/z4/T/AppTranslocation/ABC/d/OpenXE.app")
        XCTAssertFalse(translocated.logLine.hasPrefix("unregistered"))
        XCTAssertTrue(translocated.logLine.contains(caveat), translocated.logLine)

        // The refusals never claimed anything happened, so they carry no caveat
        // and stay as loud as they were.
        for refused: LaunchServicesUnregistration in
            [.noBundle, .refusedUnresolvedTranslocation(translocated: "/tmp/x/OpenXE.app")] {
            XCTAssertTrue(refused.logLine.hasPrefix("DID NOT unregister the .exe handler"))
            XCTAssertFalse(refused.logLine.contains(caveat))
        }

        // And the caveat says why, not just that.
        XCTAssertTrue(caveat.contains("Info.plist"))
        XCTAssertTrue(caveat.contains("Trash"))
    }

    /// The same truth, in the user's words, next to the instruction it depends on.
    func testTheUserIsToldTheHandlerClaimOutlivesTheRemoval() {
        let text = SetupCopy.cleanupHandlerUntilTrashed
        XCTAssertTrue(text.hasPrefix("Until you do"),
                      "this line only makes sense after the drag-to-Trash instruction")
        XCTAssertTrue(SetupCopy.cleanupDragToTrash.contains("Trash"))
        XCTAssertTrue(text.contains("OpenXE"))
        XCTAssertFalse(text.lowercased().contains("launchservices"), text)
        XCTAssertFalse(text.contains(".exe"), text)
    }

    /// Logging is diagnostic, not load-bearing: a removal must still work when no
    /// log could be opened at all.
    func testRemovalWorksWithoutALog() throws {
        let f = try makeFixture()
        let outcome = try makeRunner(f, log: nil)
            .run(plan: f.planner.plan(), keepNWSData: false,
                 documentsDirectory: f.documents, now: Date())
        XCTAssertFalse(outcome.removed.isEmpty)
    }

    // MARK: the launcher folder
    //
    // The launchers were removed and "/Applications/OpenXE Apps" was left behind,
    // empty — visible litter after a "remove everything". The folder is ours to
    // remove; anything a user put in it is not.

    func testTheLauncherFolderGoesWhenItHeldOnlyOurShortcuts() throws {
        let f = try makeFixture()
        let fm = FileManager.default
        try fm.removeItem(at: f.launcherDir.appendingPathComponent("Someone Elses.app"))
        // Finder writes one of these the moment the user opens the folder. If it
        // counted as content the folder could never be removed.
        try Data().write(to: f.launcherDir.appendingPathComponent(".DS_Store"))

        let plan = f.planner.plan()
        let folder = try XCTUnwrap(plan.targets.first { $0.url.path == f.launcherDir.path },
                                   "the folder OpenXE made for its shortcuts is never planned")
        XCTAssertEqual(folder.sizeBytes, 0,
                       "the folder's bytes are already counted as launchers; counting them "
                       + "again would overstate what the removal freed")
        XCTAssertEqual(plan.launcherCount, 1, "the folder is not a launcher")

        let outcome = try makeRunner(f).run(plan: plan, keepNWSData: false,
                                            documentsDirectory: f.documents, now: Date())
        XCTAssertTrue(outcome.skipped.isEmpty, "unexpected skips: \(outcome.skipped)")
        XCTAssertEqual(outcome.launchersRemoved, 1)
        XCTAssertFalse(fm.fileExists(atPath: f.launcherDir.path),
                       "the launcher folder was left behind, empty")
        XCTAssertTrue(fm.fileExists(atPath: f.home.appendingPathComponent("Applications").path),
                      "only OpenXE's own folder goes — not the folder it sits in")
    }

    func testTheLauncherFolderStaysWhenSomeoneElsesAppIsInIt() throws {
        let f = try makeFixture()   // the fixture parks a foreign .app in there
        let fm = FileManager.default
        let foreign = f.launcherDir.appendingPathComponent("Someone Elses.app")

        let plan = f.planner.plan()
        XCTAssertFalse(plan.targets.contains { $0.url.path == f.launcherDir.path },
                       "a folder holding somebody else's app was planned for removal")

        _ = try makeRunner(f).run(plan: plan, keepNWSData: false,
                                  documentsDirectory: f.documents, now: Date())
        XCTAssertTrue(fm.fileExists(atPath: foreign.path))
        XCTAssertTrue(fm.fileExists(atPath: f.launcherDir.path))
    }

    /// Not only apps: a file or a folder parked in there is somebody's too.
    func testTheLauncherFolderStaysWhenAnythingElseIsParkedInIt() throws {
        for stray in ["licence.txt", "My Stuff"] {
            let f = try makeFixture()
            let fm = FileManager.default
            try fm.removeItem(at: f.launcherDir.appendingPathComponent("Someone Elses.app"))
            let parked = f.launcherDir.appendingPathComponent(stray)
            if stray.contains(".") {
                try Data("keep me".utf8).write(to: parked)
            } else {
                try fm.createDirectory(at: parked, withIntermediateDirectories: true)
            }

            let plan = f.planner.plan()
            XCTAssertFalse(plan.targets.contains { $0.url.path == f.launcherDir.path },
                           "the folder was planned for removal with \(stray) sitting in it")
            _ = try makeRunner(f).run(plan: plan, keepNWSData: false,
                                      documentsDirectory: f.documents, now: Date())
            XCTAssertTrue(fm.fileExists(atPath: parked.path), "\(stray) was deleted")
        }
    }

    // MARK: copy

    func testRemovalCopyIsDistinctFromResetCopy() {
        XCTAssertTrue(SetupCopy.cleanupMenuTitle.contains("Remove"))
        XCTAssertFalse(SetupCopy.cleanupMenuTitle.contains("Reset"))
        XCTAssertTrue(SetupCopy.cleanupNotAReset.contains("Reset Environment"))
        // No shell, no paths, no jargon in anything the user reads.
        for text in [SetupCopy.cleanupExplanation, SetupCopy.cleanupNotAReset,
                     SetupCopy.cleanupKeepDataCheckbox, SetupCopy.cleanupKeepDataDefaultNote,
                     SetupCopy.cleanupDeleteDataWarning, SetupCopy.cleanupDragToTrash,
                     SetupCopy.cleanupHandlerUntilTrashed, SetupCopy.cleanupItemLauncherFolder] {
            XCTAssertFalse(text.contains("~/"), text)
            XCTAssertFalse(text.contains("/Library"), text)
            XCTAssertFalse(text.lowercased().contains("wineserver"), text)
            XCTAssertFalse(text.lowercased().contains("uninstall"), text)
        }
    }

    func testDragToTrashIsStatedPlainly() {
        XCTAssertTrue(SetupCopy.cleanupDragToTrash.contains("Trash"))
        XCTAssertTrue(SetupCopy.cleanupDragToTrash.contains("Quit"))
    }

    func testByteVocabulary() {
        XCTAssertEqual(SetupCopy.humanBytes(0), "less than 1 MB")
        XCTAssertEqual(SetupCopy.humanBytes(500_000), "less than 1 MB")
        XCTAssertEqual(SetupCopy.humanBytes(185_303_032), "177 MB")
        XCTAssertEqual(SetupCopy.humanBytes(3 << 30), "3.0 GB")
    }
}
