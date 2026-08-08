import AppKit
import OpenXECore

/// First-run progress window. Spec §4.4: determinate bar for the download,
/// indeterminate for extraction and prefix boot.
@MainActor
final class ProgressWindowController {
    private let window: NSWindow
    private let label = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()

    init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 96),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "OpenXE"
        window.isReleasedWhenClosed = false

        label.lineBreakMode = .byWordWrapping
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        bar.style = .bar
        bar.minValue = 0
        bar.maxValue = 1
        bar.isIndeterminate = true

        let stack = NSStackView(views: [label, bar])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = stack
        NSLayoutConstraint.activate([
            bar.widthAnchor.constraint(equalToConstant: 380),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
        ])
    }

    func show(message: String) {
        label.stringValue = message
        bar.startAnimation(nil)
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func apply(_ update: EngineProgress) {
        switch update {
        case .downloading(let fraction) where fraction >= 0:
            bar.isIndeterminate = false
            bar.doubleValue = fraction
            label.stringValue = "Downloading Windows engine… \(Int(fraction * 100))%"
        case .downloading:
            setIndeterminate(message: "Downloading Windows engine…")
        case .verifying:
            setIndeterminate(message: "Verifying download…")
        case .extracting:
            setIndeterminate(message: "Unpacking the Windows environment (about 700 MB)…")
        }
    }

    func setIndeterminate(message: String) {
        bar.isIndeterminate = true
        bar.startAnimation(nil)
        label.stringValue = message
    }

    func close() {
        window.orderOut(nil)
    }
}
