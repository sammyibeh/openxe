import AppKit
import OpenXECore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let paths = OpenXEPaths.standard
    private lazy var engine = EngineManager(paths: paths)
    private lazy var prefixManager = PrefixManager(paths: paths)
    private lazy var runner = Runner(paths: paths)
    private lazy var nwsInstaller = NWSInstaller(paths: paths)

    private var pendingExes: [URL] = []
    private var receivedOpenEvent = false
    private var working = false

    /// Prompt for Accessibility at most once ever (spec §9.4). Persisted so we
    /// never nag a user who has chosen not to grant it.
    private var hasPromptedForAccessibility: Bool {
        get { UserDefaults.standard.bool(forKey: "OpenXEDidPromptAccessibility") }
        set { UserDefaults.standard.set(newValue, forKey: "OpenXEDidPromptAccessibility") }
    }

    private var progressWindow: ProgressWindowController?
    private var settingsWindow: SettingsWindowController?
    private var wizardWindow: WizardWindowController?

    // MARK: setup log (instrumentation spec §3.2)

    /// One `SetupLog` per app run, opened on first use and shared with the
    /// wizard. Never closed explicitly: `SetupLog` writes straight through the
    /// file handle, so process exit loses nothing, and setup outlives any one
    /// window. Failure to open is non-fatal — setup runs unlogged rather than
    /// not at all.
    private var openedSetupLog: SetupLog?

    private func setupLog() -> SetupLog? {
        if let openedSetupLog { return openedSetupLog }
        guard let log = try? SetupLog(url: paths.setupLog) else { return nil }
        log.beginRun(buildID: Runner.currentBuildID,
                     engineID: engine.activeDescriptor?.id ?? EngineCatalog.default.id,
                     freeBytes: Self.freeBytesForImportantUsage())
        openedSetupLog = log
        return log
    }

    /// Space macOS will actually make available for a purgeable-aware download,
    /// which is the figure that matters for a 177 MB engine plus its unpack.
    private static func freeBytesForImportantUsage() -> Int64 {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    // MARK: lifecycle

    func application(_ application: NSApplication, open urls: [URL]) {
        receivedOpenEvent = true
        pendingExes.append(contentsOf: urls)
        processQueue()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Open-file events normally precede this; give a late event a beat,
        // then fall back to the settings window (opened directly, no document).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, !self.receivedOpenEvent, !self.working else { return }
            // Guided first-run: if the Windows environment isn't ready yet, or
            // New World Scheduler isn't installed, open the setup wizard.
            // Otherwise fall back to the small settings window.
            let ready = self.engine.isActiveInstalled && self.prefixManager.isReady
            if !ready || !self.nwsInstaller.isInstalled {
                self.showWizard()
            } else {
                self.showSettings()
            }
        }
    }

    // MARK: orchestration (spec §5 data flow)

    private func processQueue() {
        guard !working, !pendingExes.isEmpty else { return }
        working = true

        // `working` is set synchronously above, so the Task below cannot be
        // re-entered by a second open-file event while the gate is running.
        Task {
            // 2. Rosetta gate (Apple Silicon only; a no-op on Intel, where the
            // engine runs natively).
            guard await self.ensureRosetta() else {
                self.working = false
                self.pendingExes.removeAll()
                self.terminateIfIdle()
                return
            }

            let needsEngine = !self.engine.isActiveInstalled
            let needsPrefix = needsEngine || !self.prefixManager.isReady
            if needsEngine || needsPrefix {
                self.runSetupThenLaunch(needsEngine: needsEngine)
            } else {
                self.launchPending()
            }
        }
    }

    private func runSetupThenLaunch(needsEngine: Bool) {
        let progress = ProgressWindowController()
        progressWindow = progress
        progress.show(message: needsEngine
            ? "Setting up your Windows environment — \(SetupCopy.engineSizeSummary)."
            : "Finishing your Windows environment setup.")

        let engine = self.engine
        let prefixManager = self.prefixManager
        let log = setupLog()
        Task {
            do {
                if needsEngine {
                    try await engine.ensureDefaultActive(log: log) { update in
                        Task { @MainActor [weak self] in self?.progressWindow?.apply(update) }
                    }
                }
                progress.setIndeterminate(message: "Booting the Windows environment (first time only)…")
                try await Task.detached(priority: .userInitiated) {
                    try prefixManager.ensurePrefix(log: log)
                }.value
                self.progressWindow?.close()
                self.progressWindow = nil
                self.launchPending()
            } catch {
                log?.note("setup failed: \(error.localizedDescription)")
                self.progressWindow?.close()
                self.progressWindow = nil
                self.working = false
                self.pendingExes.removeAll()
                self.showError(title: "Setup failed",
                               message: error.localizedDescription,
                               offerLog: true)
                self.terminateIfIdle()
            }
        }
    }

    private func launchPending() {
        let exes = pendingExes
        pendingExes.removeAll()
        let runner = self.runner
        Task {
            for exe in exes {
                let outcome: LaunchOutcome
                do {
                    outcome = try await Task.detached(priority: .userInitiated) {
                        try runner.launch(exe: exe)
                    }.value
                } catch {
                    self.showError(title: "Could not launch \(exe.lastPathComponent)",
                                   message: error.localizedDescription, offerLog: true)
                    continue
                }
                switch outcome {
                case .launched(let pid):
                    // Spec §9.4: bring the program's window forward. Requires
                    // Accessibility, granted to OpenXE.app itself (never the
                    // parent terminal). If untrusted, prompt at most ONCE ever
                    // (respect a user managing these prompts), then stay silent
                    // and skip focus — Accessibility NEVER blocks the launch.
                    if WindowActivation.isTrusted {
                        _ = WindowActivation.activate(pid: pid)
                    } else if !self.hasPromptedForAccessibility {
                        self.hasPromptedForAccessibility = true
                        WindowActivation.ensureTrustPrompting()
                    }

                    // Spec §9.3: surface the program in Spotlight/Launchpad.
                    // Best-effort — never a launch blocker — but MUST be
                    // awaited: the app terminates right after this loop, and a
                    // fire-and-forget task dies with it (observed live).
                    let fallbackIcon = Bundle.main.url(forResource: "LauncherFallback",
                                                       withExtension: "icns")
                    await Task.detached(priority: .utility) {
                        let launchers = LauncherManager()
                        if !launchers.launcherExists(for: exe) {
                            _ = try? launchers.createLauncher(for: exe, fallbackIcon: fallbackIcon)
                        }
                    }.value
                case .refused(let verdict):
                    self.showError(title: "Cannot run \(exe.lastPathComponent)",
                                   message: verdict.explanation, offerLog: false)
                case .crashed(let code, let tail):
                    self.showError(title: "\(exe.lastPathComponent) quit unexpectedly (exit \(code))",
                                   message: "Recent Wine log output:\n\n\(tail.suffix(1200))",
                                   offerLog: true)
                }
            }
            self.working = false
            self.processQueue() // anything queued while we worked
            self.terminateIfIdle()
        }
    }

    private func terminateIfIdle() {
        if !working, pendingExes.isEmpty, settingsWindow == nil, progressWindow == nil,
           wizardWindow == nil {
            NSApp.terminate(nil)
        }
    }

    // MARK: Rosetta (spec §6)

    /// The double-click-an-.exe path — the one a non-technical user actually
    /// hits. It used to carry its own hardcoded copy ("Rosetta 2 translation
    /// layer", "x86 program") that had already drifted from the wizard's, and
    /// it trusted the installer's exit status. Both now come from the same
    /// place as everything else: SetupCopy and RosettaGate.
    private func ensureRosetta(gate: RosettaGate = .live()) async -> Bool {
        // Stage 1 brackets the automated check only. The prompt, the user's
        // authentication and the installer that may follow are minutes of human
        // latency and are recorded as notes, not folded into a 15 s stage.
        let log = setupLog()
        let stage1 = log?.startStage(.preflight)
        let outcome = await Task.detached(priority: .userInitiated) { gate.check() }.value
        if let stage1 { log?.endStage(.preflight, startedAt: stage1) }
        guard case .missing(let failure) = outcome else { return true }
        log?.note("Rosetta 2 missing: \(failure.userMessage)")

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = SetupCopy.rosettaTitle
        alert.informativeText = [failure.userMessage,
                                 failure.suggestedAction,
                                 SetupCopy.rosettaDeprecationNote].joined(separator: "\n\n")
        if gate.offersInstall {
            alert.addButton(withTitle: SetupCopy.rosettaInstallButton)
            alert.addButton(withTitle: SetupCopy.rosettaNotNowButton)
        } else {
            alert.addButton(withTitle: SetupCopy.rosettaDismissButton)
        }
        let response = alert.runModal()
        guard gate.offersInstall, response == .alertFirstButtonReturn else { return false }

        return await runRosettaInstall(gate: gate)
    }

    /// Shows visible progress for the duration — this is minutes, not instant —
    /// and reports every outcome in the same plain language the wizard uses.
    private func runRosettaInstall(gate: RosettaGate) async -> Bool {
        let progress = ProgressWindowController()
        progressWindow = progress
        progress.show(message: SetupCopy.rosettaInstalling)
        let log = setupLog()
        let installStart = DispatchTime.now()
        let ticker = InstallTicker { [weak progress] message in
            progress?.setIndeterminate(message: message)
        }

        let install = await Task.detached(priority: .userInitiated) {
            gate.attemptInstall(onStatus: { phase in
                Task { @MainActor in
                    ticker.pinnedMessage = phase == .awaitingAuthorization
                        ? phase.statusMessage : nil
                }
            })
        }.value

        ticker.stop()
        progressWindow?.close()
        progressWindow = nil

        switch install {
        case .installed:
            log?.note("Rosetta 2 installed", since: installStart)
            return true
        case .failed(let failure):
            log?.note("Rosetta 2 install failed (\(failure.userMessage))", since: installStart)
            showError(title: SetupCopy.rosettaTitle,
                      message: failure.userMessage + "\n\n" + failure.suggestedAction,
                      offerLog: false)
            return false
        }
    }

    // MARK: settings + alerts

    func showSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(
                engine: engine, prefixManager: prefixManager, runner: runner, paths: paths,
                onSetUp: { [weak self] in self?.showWizard() },
                onClose: { [weak self] in
                    self?.settingsWindow = nil
                    self?.terminateIfIdle()
                })
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.show()
    }

    func showWizard() {
        if wizardWindow == nil {
            wizardWindow = WizardWindowController(
                engine: engine, prefixManager: prefixManager, nws: nwsInstaller,
                runner: runner, paths: paths, log: setupLog(),
                onClose: { [weak self] in
                    self?.wizardWindow = nil
                    self?.terminateIfIdle()
                })
        }
        NSApp.activate(ignoringOtherApps: true)
        wizardWindow?.show()
    }

    func showError(title: String, message: String, offerLog: Bool) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        if offerLog { alert.addButton(withTitle: "Show Log") }
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([runner.logURL])
        }
    }
}
