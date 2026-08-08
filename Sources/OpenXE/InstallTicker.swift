import AppKit
import OpenXECore

/// A once-a-second "still working" status for the Rosetta install.
///
/// The install takes minutes and produces no incremental output we can parse,
/// so a static label is indistinguishable from a hung app — and a non-technical
/// user's response to a hung app is to force-quit it partway through a system
/// install. An advancing clock is the cheapest honest signal that it is alive.
@MainActor
final class InstallTicker {
    /// When set, shown verbatim instead of the clock. Used while macOS is
    /// waiting on the user's password: a timer counting up next to a password
    /// panel reads as pressure, and the elapsed time is not ours any more.
    var pinnedMessage: String? { didSet { emit() } }

    private let started = Date()
    private let show: (String) -> Void
    private var timer: Timer?

    init(show: @escaping (String) -> Void) {
        self.show = show
        emit()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.emit() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func emit() {
        if let pinnedMessage {
            show(pinnedMessage)
        } else {
            show(SetupCopy.rosettaInstalling(elapsed: Date().timeIntervalSince(started)))
        }
    }
}
