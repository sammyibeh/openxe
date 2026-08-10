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

    /// Same mapping as the wizard, from the same place. This window used to
    /// carry its own copy, which is how it ended up with a different set of
    /// words for the same events and its own indeterminate `.unpacking`.
    func apply(_ update: EngineProgress) {
        apply(SetupDisplay.engine(update,
                                  unpackTotal: EngineCatalog.default.expectedUnpackEntries))
    }

    func apply(_ update: PrefixProgress) {
        apply(SetupDisplay.prefix(update, tracker: &prefixTracker))
    }

    /// Stage 4's never-rewind high-water mark. Deliberately per-window rather
    /// than shared with the wizard: the two windows are never live at the same
    /// time, and one tracker behind both would be global mutable state whose
    /// only effect would be to let one run's high-water mark freeze the next
    /// run's bar. `beginDeterminate` is what keeps it fresh.
    private var prefixTracker = PrefixProgressTracker()

    private func apply(_ display: StageDisplay) {
        bar.apply(display.bar)
        label.stringValue = display.label
    }

    func setIndeterminate(message: String) {
        apply(StageDisplay(bar: .indeterminate, label: message))
    }

    /// Reset to a real zero when a new determinate stage begins, so the bar
    /// does not start stage 4 sitting at stage 3's final position.
    ///
    /// This resets the tracker too. Without it the window worked only because
    /// `AppDelegate` happens to construct a fresh controller per run: a reused
    /// controller would carry the previous run's high-water mark, every stage-4
    /// event would map to `.unchanged`, and the bar would sit at 0 for the whole
    /// prefix boot — a frozen bar with a green suite, again. The wizard already
    /// resets explicitly at the same point; this makes the other window
    /// correct by construction rather than by coincidence.
    func beginDeterminate(message: String) {
        prefixTracker = PrefixProgressTracker()
        apply(StageDisplay(bar: .determinate(0), label: message))
    }

    func close() {
        window.orderOut(nil)
    }
}
