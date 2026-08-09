import Foundation

/// What the progress bar should do for one event.
public enum BarState: Sendable, Equatable {
    /// A real, measured position in 0...1.
    case determinate(Double)
    /// No honest denominator exists. Animate, do not pretend to a number.
    case indeterminate
    /// This event carries no new position; leave the bar exactly where it is.
    /// Used by stage 4, whose sub-steps must never drag the bar backwards.
    case unchanged
}

/// One event rendered: where the bar goes and what the line underneath says.
public struct StageDisplay: Sendable, Equatable {
    public let bar: BarState
    public let label: String

    public init(bar: BarState, label: String) {
        self.bar = bar
        self.label = label
    }
}

/// The progress-event → screen mapping, as pure functions.
///
/// This used to live inside `WizardWindowController` as private methods on a
/// `@MainActor` AppKit class, where nothing could test it — which is how
/// `.unpacking` came to be mapped to an indeterminate bar for an entire stage
/// while the unit suite stayed green, and how the wizard and the `.exe`-launch
/// progress window drifted into two different sets of words for the same
/// event. The surface holds no logic worth testing; this is where the logic
/// lives instead.
public enum SetupDisplay {

    // MARK: stage 2 + 3 — engine download and unpack

    public static func engine(_ update: EngineProgress,
                              unpackTotal: Int? = nil) -> StageDisplay {
        switch update {
        case .downloading(let fraction) where fraction >= 0:
            return StageDisplay(bar: .determinate(fraction),
                                label: "Downloading the Windows environment… "
                                     + "\(Int((fraction * 100).rounded()))%")
        case .downloading:
            return StageDisplay(bar: .indeterminate,
                                label: "Downloading the Windows environment…")
        case .verifying:
            return StageDisplay(bar: .indeterminate, label: "Checking the download…")
        case .extracting:
            return StageDisplay(bar: unpackTotal == nil ? .indeterminate : .determinate(0),
                                label: "Unpacking the Windows environment…")
        case .unpacking(let entries):
            let fraction = unpackFraction(entries: entries, of: unpackTotal)
            return StageDisplay(
                bar: fraction.map(BarState.determinate) ?? .indeterminate,
                label: "Unpacking the Windows environment… \(entries) files")
        }
    }

    /// Stage 3's bar position, or nil when there is no trustworthy denominator.
    ///
    /// The archive's entry total cannot be known without reading the archive,
    /// and reading it twice costs a second full xz decompression of 177 MB. So
    /// the total is a per-engine *measurement* carried on the descriptor,
    /// exactly like `PrefixProgress.expectedPrefixEntries` and the stage
    /// weights. Two rules keep a wrong measurement honest:
    ///
    ///   - the result is capped below 1.0, so the bar never claims the unpack
    ///     is finished while `tar` is still running;
    ///   - if the real archive turns out to hold MORE entries than measured,
    ///     this returns nil and the bar drops back to indeterminate rather
    ///     than sticking at a lie.
    public static func unpackFraction(entries: Int, of total: Int?) -> Double? {
        guard let total, total > 0, entries >= 0, entries <= total else { return nil }
        return min(Double(entries) / Double(total), 0.99)
    }

    // MARK: stage 4 — prefix

    /// The tracker holds the never-rewind guarantee, so it is `inout` here
    /// rather than hidden inside the window controller.
    public static func prefix(_ update: PrefixProgress,
                              tracker: inout PrefixProgressTracker) -> StageDisplay {
        let position = tracker.position(for: update)
        return StageDisplay(bar: position.map(BarState.determinate) ?? .unchanged,
                            label: PrefixProgressTracker.detail(for: update))
    }

    // MARK: stage 5 + 6 — NWS download and install

    public static func nws(_ update: NWSProgress) -> StageDisplay {
        switch update {
        case .downloading(let fraction) where fraction >= 0:
            return StageDisplay(bar: .determinate(fraction),
                                label: "Downloading New World Scheduler… "
                                     + "\(Int((fraction * 100).rounded()))%")
        case .downloading:
            return StageDisplay(bar: .indeterminate,
                                label: "Downloading New World Scheduler…")
        case .installing:
            // The Inno installer runs silently under Wine and publishes no
            // progress of any kind. An indeterminate bar is the honest
            // rendering of "working, duration unknown"; inventing a creeping
            // fraction here would be a lie about ~18 seconds.
            return StageDisplay(bar: .indeterminate,
                                label: "Installing New World Scheduler…")
        case .verifying:
            return StageDisplay(bar: .indeterminate, label: "Finishing installation…")
        }
    }
}
