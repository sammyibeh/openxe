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

        // 2. Rosetta gate (Apple Silicon only).
        guard ensureRosetta() else {
            working = false
            pendingExes.removeAll()
            terminateIfIdle()
            return
        }

        let needsEngine = !engine.isActiveInstalled
        let needsPrefix = needsEngine || !prefixManager.isReady
        if needsEngine || needsPrefix {
            runSetupThenLaunch(needsEngine: needsEngine)
        } else {
            launchPending()
        }
    }

    private func runSetupThenLaunch(needsEngine: Bool) {
        let progress = ProgressWindowController()
        progressWindow = progress
        progress.show(message: needsEngine
            ? "Setting up your Windows environment — one time, ~200 MB download."
            : "Finishing your Windows environment setup.")

        let engine = self.engine
        let prefixManager = self.prefixManager
        Task {
            do {
                if needsEngine {
                    try await engine.ensureDefaultActive { update in
                        Task { @MainActor [weak self] in self?.progressWindow?.apply(update) }
                    }
                }
                progress.setIndeterminate(message: "Booting the Windows environment (first time only)…")
                try await Task.detached(priority: .userInitiated) {
                    try prefixManager.ensurePrefix()
                }.value
                self.progressWindow?.close()
                self.progressWindow = nil
                self.launchPending()
            } catch {
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

    private func ensureRosetta() -> Bool {
        guard !RosettaCheck.canRunX86_64 else { return true }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Rosetta 2 is required"
        alert.informativeText = "OpenXE's Windows engine is an x86 program and needs Apple's "
            + "Rosetta 2 translation layer on this Mac. Install it now?"
        alert.addButton(withTitle: "Install Rosetta")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        let result = RosettaCheck.install()
        if result.status == 0, RosettaCheck.canRunX86_64 { return true }
        showError(title: "Rosetta installation did not complete",
                  message: String(result.output.suffix(500)), offerLog: false)
        return false
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
                runner: runner, paths: paths,
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
