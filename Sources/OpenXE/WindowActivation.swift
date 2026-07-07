import AppKit
import ApplicationServices

/// Brings a launched Windows program's window to the front. Spec §9.4.
///
/// Wine runs each program as a child process with its own Cocoa windows
/// (winemac.drv). Raising another process's windows requires the macOS
/// Accessibility permission — and it must be granted to **OpenXE.app itself**,
/// never to a parent terminal. This type prompts as OpenXE via the official
/// AX API and degrades to a no-op when the permission is absent: window focus
/// is a convenience, never a gate on launching.
@MainActor
enum WindowActivation {

    /// Whether OpenXE currently holds Accessibility trust. Never prompts.
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Ask once, on first use of the focus feature, prompting the user if
    /// needed. The system dialog attributes to the calling app (OpenXE when
    /// run as OpenXE.app). Returns current trust; a fresh grant may only take
    /// effect on the next launch, so callers must not block on `true`.
    @discardableResult
    static func ensureTrustPrompting() -> Bool {
        // kAXTrustedCheckOptionPrompt is the documented option key; reference
        // it as a plain CFString to sidestep the global-var concurrency check.
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let options = [key: kCFBooleanTrue as Any] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Best-effort raise of the given process's windows. No-op (returns false)
    /// when Accessibility is not granted — the program still ran; only the
    /// auto-focus is skipped.
    @discardableResult
    static func activate(pid: pid_t) -> Bool {
        guard isTrusted else { return false }
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return app.activate(options: [.activateAllWindows])
    }
}
