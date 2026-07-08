import AppKit
import OpenXECore

/// Minimal per-app configuration window (spec §4.6): pick a known app, set its
/// Windows version and DLL overrides. Delivered inside the single shared prefix
/// via Wine's per-app AppDefaults + WINEDLLOVERRIDES — no separate bottles.
@MainActor
final class AppConfigWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let store: AppConfigStore
    private let onClose: () -> Void

    private let appPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let versionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let overridesField = NSTextField(string: "")
    private let statusLabel = NSTextField(labelWithString: "")

    /// Full exe paths, index-aligned with `appPopup` items.
    private var appPaths: [String] = []
    private let versions = AppConfig.WindowsVersion.allCases

    init(paths: OpenXEPaths, onClose: @escaping () -> Void) {
        self.store = AppConfigStore(paths: paths)
        self.onClose = onClose
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 260),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()

        window.title = "Per-App Settings"
        window.isReleasedWhenClosed = false
        window.delegate = self

        // Known apps: everything OpenXE has generated a launcher for, unioned
        // with anything that already has a saved config.
        var paths_ = Set(LauncherManager().knownTargetPaths())
        paths_.formUnion(store.allConfigs().map { $0.exePath })
        appPaths = paths_.sorted()

        for path in appPaths {
            let item = NSMenuItem(title: URL(fileURLWithPath: path).lastPathComponent,
                                  action: nil, keyEquivalent: "")
            item.toolTip = path
            appPopup.menu?.addItem(item)
        }
        if appPaths.isEmpty {
            appPopup.addItem(withTitle: "No apps yet — launch one first")
            appPopup.isEnabled = false
            versionPopup.isEnabled = false
            overridesField.isEnabled = false
        }
        appPopup.target = self
        appPopup.action = #selector(appSelected)

        for v in versions { versionPopup.addItem(withTitle: v.displayName) }

        overridesField.placeholderString = "e.g. d3d11=n,b; dxgi=b; winmm=disabled→ use n / b / n,b / b,n / (blank=off)"
        overridesField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor

        let hint = NSTextField(wrappingLabelWithString:
            "Applied to the shared Windows environment at launch. Windows version uses "
            + "Wine's per-app AppDefaults; DLL overrides use WINEDLLOVERRIDES "
            + "(modes: n=native, b=built-in, n,b / b,n, blank=disabled).")
        hint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor

        let save = NSButton(title: "Save", target: self, action: #selector(saveConfig))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"

        let stack = NSStackView(views: [
            labeled("Application:", appPopup),
            labeled("Windows version:", versionPopup),
            labeled("DLL overrides:", overridesField),
            hint, save, statusLabel,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        window.contentView = stack

        overridesField.widthAnchor.constraint(equalToConstant: 400).isActive = true
        loadSelectedConfig()
    }

    func show() {
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { onClose() }

    private func labeled(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.spacing = 8
        label.widthAnchor.constraint(equalToConstant: 110).isActive = true
        return row
    }

    private var selectedPath: String? {
        let idx = appPopup.indexOfSelectedItem
        guard idx >= 0, idx < appPaths.count else { return nil }
        return appPaths[idx]
    }

    @objc private func appSelected() { loadSelectedConfig() }

    private func loadSelectedConfig() {
        guard let path = selectedPath else { return }
        let config = store.config(forExePath: path)
            ?? AppConfig(exePath: path)
        if let vIdx = versions.firstIndex(of: config.windowsVersion) {
            versionPopup.selectItem(at: vIdx)
        }
        overridesField.stringValue = config.dllOverridesString ?? ""
        statusLabel.stringValue = ""
    }

    @objc private func saveConfig() {
        guard let path = selectedPath else { return }
        let version = versions[max(0, versionPopup.indexOfSelectedItem)]
        let overrides = AppConfig.parseDLLOverrides(overridesField.stringValue)
        let config = AppConfig(exePath: path, windowsVersion: version,
                               dllOverrides: overrides)
        store.save(config)
        // Reflect normalization back to the field.
        overridesField.stringValue = config.dllOverridesString ?? ""
        statusLabel.stringValue = config.isDefault
            ? "Reset to defaults — applied on next launch."
            : "Saved. Applied the next time this app launches."
    }
}
