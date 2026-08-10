#if canImport(AppKit)
import AppKit

extension NSProgressIndicator {

    /// The one place `BarState` becomes pixels.
    ///
    /// This lives in Core rather than in the app target for one reason: the
    /// test target links Core and cannot link an executable, so while this sat
    /// next to the windows it was the last link in the progress chain that no
    /// test could reach. Everything before it — byte counts, fractions, the
    /// event→`StageDisplay` mapping — is covered; dropping `isIndeterminate =
    /// false` here would freeze the bar exactly as the shipped defect did, and
    /// nothing would have caught it. It imports no more than the app already
    /// links, and AppKit is a system framework, so the size budget is unmoved.
    ///
    /// `stopAnimation(nil)` before switching to determinate is deliberate.
    /// AppKit's documented order is to stop the indeterminate animation before
    /// clearing `isIndeterminate`; the previous code left the animation running
    /// forever, since `setBusy` only stopped it when the whole step finished.
    ///
    /// Honesty note: whether AppKit on macOS 27 *actually* misrenders in that
    /// state could not be settled programmatically. An off-screen readback of
    /// `NSProgressIndicator` (both `cacheDisplay(in:to:)` and
    /// `CALayer.render(in:)`) reports no fill even in the control case — stop
    /// the animation first, set 0.25, then 0.75, and all three measure
    /// identical. The instrument is blind, not the indicator. So this follows
    /// the documented order rather than betting on an observation that could
    /// not be made, and the rendering itself remains verifiable only by a
    /// human watching a real run.
    public func apply(_ state: BarState) {
        switch state {
        case .determinate(let fraction):
            stopAnimation(nil)
            isIndeterminate = false
            doubleValue = min(max(fraction, minValue), maxValue)
        case .indeterminate:
            isIndeterminate = true
            startAnimation(nil)
        case .unchanged:
            break
        }
    }
}
#endif
