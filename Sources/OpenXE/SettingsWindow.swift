import AppKit
import OpenXECore

/// The single settings window. Spec §4.4: engine version display,
/// Open C: Drive, Shut Down Windows Environment, Reset Environment.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let engine: EngineManager
    private let prefixManager: PrefixManager
    private let runner: Runner
    private let paths: OpenXEPaths
    private let onClose: () -> Void
    private let statusLabel = NSTextField(labelWithString: "")

    init(engine: EngineManager, prefixManager: PrefixManager, runner: Runner,
         paths: OpenXEPaths, onClose: @escaping () -> Void) {
        self.engine = engine
        self.prefixManager = prefixManager
        self.runner = runner
        self.paths = paths
        self.onClose = onClose
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 200),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()

        window.title = "OpenXE"
        window.isReleasedWhenClosed = false
        window.delegate = self

        let versionText = engine.installedVersion.map { "Engine: \($0)" }
            ?? "Engine: not installed (downloads on first .exe launch)"
        let versionLabel = NSTextField(labelWithString: versionText)
        versionLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        versionLabel.textColor = .secondaryLabelColor

        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor

        let openC = button("Open C: Drive in Finder", #selector(openCDrive))
        openC.isEnabled = prefixManager.isReady
        let shutdown = button("Shut Down Windows Environment", #selector(shutdownEnvironment))
        let reset = button("Reset Environment…", #selector(resetEnvironment))
        reset.isEnabled = prefixManager.isReady
        let removeLaunchers = button("Remove Generated Launchers", #selector(removeGeneratedLaunchers))

        let stack = NSStackView(views: [versionLabel, openC, shutdown, reset, removeLaunchers, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        window.contentView = stack
    }

    func show() {
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        return b
    }

    @objc private func openCDrive() {
        NSWorkspace.shared.open(paths.prefix.appendingPathComponent("drive_c"))
    }

    @objc private func shutdownEnvironment() {
        let runner = self.runner
        statusLabel.stringValue = "Shutting down…"
        Task {
            await Task.detached { runner.shutdownWineserver() }.value
            self.statusLabel.stringValue = "Windows environment shut down."
        }
    }

    @objc private func removeGeneratedLaunchers() {
        statusLabel.stringValue = "Removing launchers…"
        Task {
            let removed = await Task.detached { LauncherManager().removeAllLaunchers() }.value
            self.statusLabel.stringValue = removed == 0
                ? "No generated launchers found."
                : "Removed \(removed) launcher\(removed == 1 ? "" : "s")."
        }
    }

    @objc private func resetEnvironment() {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Reset the Windows environment?"
        alert.informativeText = "This deletes the entire C: drive, the Windows registry, and every "
            + "installed Windows program. Files in your Mac's Documents, Downloads, and Desktop "
            + "folders are not affected. This cannot be undone."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let prefixManager = self.prefixManager
        statusLabel.stringValue = "Resetting…"
        Task {
            do {
                try await Task.detached { try prefixManager.reset() }.value
                self.statusLabel.stringValue = "Environment reset. It will be rebuilt on the next launch."
            } catch {
                self.statusLabel.stringValue = "Reset failed: \(error.localizedDescription)"
            }
        }
    }
}
