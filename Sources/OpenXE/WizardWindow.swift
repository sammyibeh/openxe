import AppKit
import OpenXECore

/// Guided first-run setup wizard (spec §4.4). Walks a non-technical user through
/// getting a working New World Scheduler on their Mac: welcome + disclaimer →
/// prepare the Windows environment → download & install NWS → done/launch.
///
/// Plain language throughout: the user is not expected to know "Wine", "prefix",
/// or "engine". The wizard reuses EngineManager/PrefixManager/NWSInstaller/Runner
/// and holds no business logic of its own.
@MainActor
final class WizardWindowController: NSObject, NSWindowDelegate {

    enum Step { case welcome, environment, nws, done }

    private let window: NSWindow
    private let engine: EngineManager
    private let prefixManager: PrefixManager
    private let nws: NWSInstaller
    private let runner: Runner
    private let paths: OpenXEPaths
    private let onClose: () -> Void

    // Shared chrome, reused across steps.
    private let titleLabel = NSTextField(labelWithString: "")
    private let bodyStack = NSStackView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let progressBar = NSProgressIndicator()
    private let backButton = NSButton()
    private let secondaryButton = NSButton()
    private let primaryButton = NSButton()

    private var step: Step = .welcome
    private var working = false
    private var didFinish = false

    // NWS step state.
    private var latestRelease: NWSInstaller.Release?
    private var pinnedReleases: [NWSInstaller.Release] = []
    private var versionPopup: NSPopUpButton?

    init(engine: EngineManager, prefixManager: PrefixManager, nws: NWSInstaller,
         runner: Runner, paths: OpenXEPaths, onClose: @escaping () -> Void) {
        self.engine = engine
        self.prefixManager = prefixManager
        self.nws = nws
        self.runner = runner
        self.paths = paths
        self.onClose = onClose
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 440),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()

        window.title = "Set Up New World Scheduler"
        window.isReleasedWhenClosed = false
        window.delegate = self

        titleLabel.font = .boldSystemFont(ofSize: 17)
        titleLabel.lineBreakMode = .byWordWrapping

        bodyStack.orientation = .vertical
        bodyStack.alignment = .leading
        bodyStack.spacing = 10

        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor

        progressBar.style = .bar
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.isIndeterminate = true
        progressBar.isHidden = true

        backButton.title = "Back"
        backButton.bezelStyle = .rounded
        backButton.target = self
        backButton.action = #selector(backTapped)

        // Secondary action, used only on the final step ("Finish Without Launching").
        secondaryButton.bezelStyle = .rounded
        secondaryButton.keyEquivalent = "\u{1b}" // Esc — the close-without-launching path
        secondaryButton.target = self
        secondaryButton.action = #selector(secondaryTapped)
        secondaryButton.isHidden = true

        primaryButton.title = "Continue"
        primaryButton.bezelStyle = .rounded
        primaryButton.keyEquivalent = "\r"
        primaryButton.target = self
        primaryButton.action = #selector(primaryTapped)

        let buttonRow = NSStackView(views: [backButton, NSView(), secondaryButton, primaryButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        let root = NSStackView(views: [titleLabel, bodyStack, NSView(), statusLabel,
                                       progressBar, buttonRow])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = root
        NSLayoutConstraint.activate([
            titleLabel.widthAnchor.constraint(equalToConstant: 492),
            bodyStack.widthAnchor.constraint(equalToConstant: 492),
            statusLabel.widthAnchor.constraint(equalToConstant: 492),
            progressBar.widthAnchor.constraint(equalToConstant: 492),
            buttonRow.widthAnchor.constraint(equalToConstant: 492),
        ])
    }

    func show() {
        renderWelcome()
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { onClose() }

    // MARK: shared helpers

    private func clearBody() {
        for v in bodyStack.arrangedSubviews { bodyStack.removeArrangedSubview(v); v.removeFromSuperview() }
    }

    private func paragraph(_ text: String) -> NSTextField {
        let l = NSTextField(wrappingLabelWithString: text)
        l.font = .systemFont(ofSize: NSFont.systemFontSize)
        l.widthAnchor.constraint(equalToConstant: 492).isActive = true
        return l
    }

    private func linkButton(_ title: String, url: URL) -> NSButton {
        let b = NSButton(title: title, target: self, action: #selector(openLink(_:)))
        b.bezelStyle = .inline
        b.isBordered = false
        b.contentTintColor = .linkColor
        b.identifier = NSUserInterfaceItemIdentifier(url.absoluteString)
        return b
    }

    @objc private func openLink(_ sender: NSButton) {
        if let id = sender.identifier?.rawValue, let url = URL(string: id) {
            NSWorkspace.shared.open(url)
        }
    }

    private func setStatus(_ text: String, isError: Bool = false) {
        statusLabel.stringValue = text
        statusLabel.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    private func setBusy(_ busy: Bool, indeterminate: Bool = true) {
        working = busy
        progressBar.isHidden = !busy
        primaryButton.isEnabled = !busy
        secondaryButton.isEnabled = !busy
        backButton.isEnabled = !busy && step != .welcome
        if busy {
            progressBar.isIndeterminate = indeterminate
            if indeterminate { progressBar.startAnimation(nil) }
        } else {
            progressBar.stopAnimation(nil)
        }
    }

    private func setProgress(_ fraction: Double) {
        if fraction < 0 { progressBar.isIndeterminate = true; progressBar.startAnimation(nil) }
        else { progressBar.isIndeterminate = false; progressBar.doubleValue = fraction }
    }

    // MARK: navigation

    @objc private func backTapped() {
        switch step {
        case .welcome: break
        case .environment: renderWelcome()
        case .nws: renderEnvironment()
        case .done: renderNWS()
        }
    }

    @objc private func primaryTapped() {
        switch step {
        case .welcome: renderEnvironment()
        case .environment: environmentPrimary()
        case .nws: nwsPrimary()
        case .done: launchAndFinish()
        }
    }

    @objc private func secondaryTapped() {
        guard step == .done, !working else { return }
        finishWithoutLaunching()
    }

    // MARK: Step 1 — Welcome + disclaimer (spec §4.4)

    private func renderWelcome() {
        step = .welcome
        setBusy(false)
        setStatus("")
        titleLabel.stringValue = "Welcome to OpenXE"
        clearBody()

        bodyStack.addArrangedSubview(paragraph(
            "OpenXE runs New World Scheduler on your Mac. It sets up a small Windows "
            + "environment behind the scenes, downloads New World Scheduler from its "
            + "official source, and installs it — all in a few guided steps."))

        let disclaimer = NSTextField(wrappingLabelWithString:
            "OpenXE is an unofficial tool. It is not affiliated with, endorsed by, or "
            + "connected to New World Scheduler or nwscheduler.com. New World Scheduler "
            + "is downloaded directly from its official release and is subject to its own "
            + "license and terms.")
        disclaimer.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        disclaimer.widthAnchor.constraint(equalToConstant: 492).isActive = true
        bodyStack.addArrangedSubview(disclaimer)

        let links = NSStackView(views: [
            linkButton("Official download page", url: URL(string: "https://nwscheduler.com/download-jw-scheduler/")!),
            linkButton("Terms & Conditions", url: URL(string: "https://nwscheduler.com/terms-and-conditions/")!),
        ])
        links.orientation = .horizontal
        links.spacing = 20
        bodyStack.addArrangedSubview(links)

        backButton.isHidden = true
        primaryButton.title = "Continue"
        primaryButton.isEnabled = true
    }

    // MARK: Step 2 — Windows environment (reuse EngineManager + PrefixManager)

    private func renderEnvironment() {
        step = .environment
        setBusy(false)
        setStatus("")
        titleLabel.stringValue = "Set up the Windows environment"
        clearBody()
        backButton.isHidden = false
        backButton.isEnabled = true

        let ready = engine.isActiveInstalled && prefixManager.isReady
        if ready {
            bodyStack.addArrangedSubview(paragraph(
                "The Windows environment is already set up and ready. You can continue "
                + "to installing New World Scheduler."))
            primaryButton.title = "Continue"
        } else {
            bodyStack.addArrangedSubview(paragraph(
                "OpenXE needs to prepare a small Windows environment the first time you "
                + "run it. This is \(SetupCopy.engineSizeSummary). It can take several "
                + "minutes, and you only do this once."))
            primaryButton.title = "Set Up"
        }
        primaryButton.isEnabled = true
    }

    private func environmentPrimary() {
        if engine.isActiveInstalled && prefixManager.isReady {
            renderNWS()
            return
        }
        setBusy(true)
        setStatus("Preparing the Windows environment…")

        let engine = self.engine
        let prefixManager = self.prefixManager
        Task {
            do {
                try await engine.ensureDefaultActive { update in
                    Task { @MainActor [weak self] in self?.applyEngineProgress(update) }
                }
                await MainActor.run {
                    self.setProgress(-1)
                    self.setStatus("Finishing the Windows environment (first time only)…")
                }
                try await Task.detached(priority: .userInitiated) {
                    try prefixManager.ensurePrefix()
                }.value
                self.setBusy(false)
                self.setStatus("Windows environment ready.")
                self.renderNWS()
            } catch {
                self.setBusy(false)
                self.setStatus(error.localizedDescription, isError: true)
            }
        }
    }

    private func applyEngineProgress(_ update: EngineProgress) {
        switch update {
        case .downloading(let f) where f >= 0:
            setProgress(f)
            setStatus("Downloading the Windows environment… \(Int(f * 100))%")
        case .downloading:
            setProgress(-1); setStatus("Downloading the Windows environment…")
        case .verifying:
            setProgress(-1); setStatus("Verifying the download…")
        case .extracting:
            setProgress(-1); setStatus("Unpacking the Windows environment…")
        }
    }

    // MARK: Step 3 — Download & install NWS

    private func renderNWS() {
        step = .nws
        setBusy(false)
        setStatus("")
        titleLabel.stringValue = "Install New World Scheduler"
        clearBody()
        backButton.isHidden = false
        backButton.isEnabled = true

        if nws.isInstalled {
            bodyStack.addArrangedSubview(paragraph(
                "New World Scheduler is already installed. You can reinstall or update it "
                + "to the latest version, or continue to finish."))
            primaryButton.title = "Reinstall / Update"
        } else {
            bodyStack.addArrangedSubview(paragraph(
                "OpenXE will download New World Scheduler (about 50 MB) from its official "
                + "source and install it for you."))
            primaryButton.title = "Download & Install"
        }

        let detected = paragraph("Checking for the latest version…")
        bodyStack.addArrangedSubview(detected)

        // Advanced: pick a specific version (pinning).
        let advanced = NSButton(title: "Choose a specific version…", target: self,
                                action: #selector(chooseVersionTapped))
        advanced.bezelStyle = .inline
        advanced.isBordered = false
        advanced.contentTintColor = .linkColor
        bodyStack.addArrangedSubview(advanced)

        primaryButton.isEnabled = false // enabled once we know the latest (or a pin)

        // Fetch latest to show the detected version.
        Task {
            do {
                let latest = try await nws.fetchLatest()
                self.latestRelease = latest
                detected.stringValue = "Latest version: \(latest.displayLabel)"
                self.primaryButton.isEnabled = true
            } catch let e as NWSError {
                // GitHub unreachable/rate-limited: fall back to the vendor link.
                self.latestRelease = nil
                detected.stringValue = "Couldn't check the latest version — OpenXE will use "
                    + "the vendor's official download link instead."
                self.setStatus(e.errorDescription ?? "", isError: true)
                self.primaryButton.isEnabled = true // fallback download still possible
            } catch {
                detected.stringValue = error.localizedDescription
                self.primaryButton.isEnabled = true
            }
        }
    }

    @objc private func chooseVersionTapped() {
        setBusy(true)
        setStatus("Loading available versions…")
        Task {
            do {
                let releases = try await nws.fetchAllReleases()
                self.pinnedReleases = releases
                self.setBusy(false)
                self.presentVersionPicker(releases)
            } catch {
                self.setBusy(false)
                self.setStatus("Couldn't load the version list: \(error.localizedDescription)",
                               isError: true)
            }
        }
    }

    private func presentVersionPicker(_ releases: [NWSInstaller.Release]) {
        guard !releases.isEmpty else { return }
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        for r in releases { popup.addItem(withTitle: r.displayLabel) }
        popup.target = self
        popup.action = #selector(versionPicked)
        versionPopup = popup

        // Insert the popup after the "detected" paragraph if not already present.
        let label = NSTextField(labelWithString: "Version to install:")
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        bodyStack.addArrangedSubview(label)
        bodyStack.addArrangedSubview(popup)
        versionPicked() // adopt the top (latest) selection
    }

    @objc private func versionPicked() {
        guard let popup = versionPopup else { return }
        let idx = popup.indexOfSelectedItem
        guard idx >= 0, idx < pinnedReleases.count else { return }
        latestRelease = pinnedReleases[idx]
        setStatus("Selected version \(pinnedReleases[idx].tag).")
        primaryButton.isEnabled = true
    }

    private func nwsPrimary() {
        setBusy(true, indeterminate: false)
        setProgress(0)
        setStatus("Downloading New World Scheduler…")

        let nws = self.nws
        let chosen = self.latestRelease
        Task {
            do {
                let installer: URL
                if let release = chosen {
                    installer = try await nws.download(release) { p in
                        Task { @MainActor [weak self] in self?.applyNWSProgress(p) }
                    }
                } else {
                    // GitHub was unreachable — use the vendor's official fallback link.
                    installer = try await nws.downloadViaFallback { p in
                        Task { @MainActor [weak self] in self?.applyNWSProgress(p) }
                    }
                }
                await MainActor.run {
                    self.setProgress(-1)
                    self.setStatus("Installing New World Scheduler…")
                }
                try await Task.detached(priority: .userInitiated) {
                    try await nws.install(installerAt: installer) { p in
                        Task { @MainActor [weak self] in self?.applyNWSProgress(p) }
                    }
                }.value
                nws.cleanupDownloads()
                self.setBusy(false)
                self.setStatus("New World Scheduler installed.")
                self.renderDone()
            } catch let e as NWSError {
                self.setBusy(false)
                // Rate-limited on the API path but we had a release: retry via fallback.
                if case .rateLimited = e, chosen == nil {
                    self.setStatus(e.errorDescription ?? "", isError: true)
                } else {
                    self.setStatus(e.errorDescription ?? "Install failed.", isError: true)
                }
            } catch {
                self.setBusy(false)
                self.setStatus(error.localizedDescription, isError: true)
            }
        }
    }

    private func applyNWSProgress(_ p: NWSProgress) {
        switch p {
        case .downloading(let f) where f >= 0:
            setProgress(f)
            setStatus("Downloading New World Scheduler… \(Int(f * 100))%")
        case .downloading:
            setProgress(-1); setStatus("Downloading New World Scheduler…")
        case .installing:
            setProgress(-1); setStatus("Installing New World Scheduler…")
        case .verifying:
            setProgress(-1); setStatus("Finishing installation…")
        }
    }

    // MARK: Step 4 — Done

    private func renderDone() {
        step = .done
        setBusy(false)
        setStatus("")
        titleLabel.stringValue = "You're all set"
        clearBody()
        backButton.isHidden = true

        bodyStack.addArrangedSubview(paragraph(
            "New World Scheduler is installed and ready to use. It now appears in your "
            + "Applications folder and Launchpad, so you can open it any time like a "
            + "normal Mac app."))
        bodyStack.addArrangedSubview(paragraph(
            "The first launch may take a few seconds. New World Scheduler manages its own "
            + "60-day trial and activation from inside the app."))

        secondaryButton.title = "Finish Without Launching"
        secondaryButton.isHidden = false
        secondaryButton.isEnabled = true

        primaryButton.title = "Launch New World Scheduler"
        primaryButton.isEnabled = true
    }

    /// Primary path: launch NWS, then close the wizard. On failure the wizard
    /// stays open with a plain-language message so the user can retry or finish
    /// without launching.
    private func launchAndFinish() {
        guard let exe = nws.installedExe else {
            setStatus("New World Scheduler could not be found.", isError: true)
            return
        }
        setBusy(true)
        setStatus("Launching New World Scheduler…")
        let runner = self.runner
        Task {
            await self.ensureLauncher(for: exe)
            do {
                let outcome = try await Task.detached(priority: .userInitiated) {
                    try runner.launch(exe: exe)
                }.value
                switch outcome {
                case .launched:
                    self.finish()
                case .refused(let verdict):
                    self.setBusy(false)
                    self.setStatus(verdict.explanation, isError: true)
                case .crashed(let code, _):
                    self.setBusy(false)
                    self.setStatus("New World Scheduler quit unexpectedly (code \(code)).",
                                   isError: true)
                }
            } catch {
                self.setBusy(false)
                self.setStatus(error.localizedDescription, isError: true)
            }
        }
    }

    /// Secondary path: close the wizard without starting NWS. Setup completion
    /// is identical to the launch path — only the launch itself is skipped.
    private func finishWithoutLaunching() {
        guard let exe = nws.installedExe else {
            finish()
            return
        }
        setBusy(true)
        Task {
            await self.ensureLauncher(for: exe)
            self.finish()
        }
    }

    /// Setup-completion side effect shared by both final-step paths: make NWS
    /// appear in Spotlight/Launchpad (spec §9.3). Best-effort, but MUST be
    /// awaited before the window closes — the app terminates once the wizard
    /// goes away, and a fire-and-forget task would die with it.
    private func ensureLauncher(for exe: URL) async {
        let fallbackIcon = Bundle.main.url(forResource: "LauncherFallback", withExtension: "icns")
        await Task.detached(priority: .utility) {
            let launchers = LauncherManager()
            if !launchers.launcherExists(for: exe) {
                _ = try? launchers.createLauncher(for: exe, fallbackIcon: fallbackIcon)
            }
        }.value
    }

    private func finish() {
        didFinish = true
        window.close()
    }
}
