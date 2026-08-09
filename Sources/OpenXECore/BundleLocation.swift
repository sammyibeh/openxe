import Foundation

/// Where the running app bundle actually lives on disk.
///
/// Gatekeeper's App Translocation runs a quarantined bundle from a randomized,
/// read-only mount under `…/AppTranslocation/<uuid>/d/`, and `Bundle.main`
/// reports *that* path — not `/Applications/OpenXE.app`. Anything that names the
/// bundle to another subsystem (here: `lsregister -u`) therefore names a path
/// that will vanish, while the real installed copy stays registered. Observed
/// live: the in-app Remove ran `lsregister -u` against the translocated path and
/// `/Applications/OpenXE.app` remained the `.exe` handler.
public enum BundleLocation: Sendable, Equatable {
    /// Running from where it is installed.
    case real(URL)
    /// Running translocated, and the installed copy was resolved.
    case translocated(real: URL, translocated: URL)
    /// Running translocated, and the installed copy could NOT be resolved. There
    /// is deliberately no guess here: acting on a wrong path is worse than
    /// reporting that the right one is unknown.
    case unresolvedTranslocation(URL)

    /// The path on disk that other subsystems should be told about, or nil when
    /// it could not be established.
    public var realURL: URL? {
        switch self {
        case .real(let url): return url
        case .translocated(let real, _): return real
        case .unresolvedTranslocation: return nil
        }
    }

    public var isTranslocated: Bool {
        switch self {
        case .real: return false
        case .translocated, .unresolvedTranslocation: return true
        }
    }
}

/// Resolves a bundle URL to its real on-disk location.
///
/// Both primitives are injected so the translocated case — which cannot be
/// staged on a test machine without Gatekeeper's cooperation — is testable, and
/// so no test can be surprised by whatever the host Mac happens to be doing.
public struct BundleLocationResolver: Sendable {
    /// `true`/`false` from the system, or nil when the query itself failed.
    let isTranslocated: @Sendable (URL) -> Bool?
    /// The pre-translocation path, or nil when it could not be produced.
    let originalPath: @Sendable (URL) -> URL?

    public init(isTranslocated: @escaping @Sendable (URL) -> Bool?,
                originalPath: @escaping @Sendable (URL) -> URL?) {
        self.isTranslocated = isTranslocated
        self.originalPath = originalPath
    }

    /// The component App Translocation always puts in the path. Used only as a
    /// last-resort signal when the API query fails: it is enough to know we must
    /// NOT trust the path, which is the decision that matters.
    static let translocationPathComponent = "AppTranslocation"

    public func resolve(_ bundleURL: URL) -> BundleLocation {
        switch isTranslocated(bundleURL) {
        case .some(false):
            return .real(bundleURL)

        case .some(true):
            guard let original = originalPath(bundleURL),
                  original.standardizedFileURL.path != bundleURL.standardizedFileURL.path
            else {
                return .unresolvedTranslocation(bundleURL)
            }
            return .translocated(real: original, translocated: bundleURL)

        case .none:
            // The query failed. If the path itself carries the translocation
            // marker, say so and resolve nothing; otherwise the bundle is where
            // it says it is, which is the overwhelmingly common case.
            return bundleURL.pathComponents.contains(Self.translocationPathComponent)
                ? .unresolvedTranslocation(bundleURL)
                : .real(bundleURL)
        }
    }

    /// The production resolver, backed by `Security.framework`.
    public static let system = BundleLocationResolver(
        isTranslocated: { SecTranslocateShim.isTranslocated($0) },
        originalPath: { SecTranslocateShim.originalPath($0) })
}

/// `SecTranslocateIsTranslocatedURL` / `SecTranslocateCreateOriginalPathForURL`.
///
/// These are the documented API for this problem and have shipped in
/// Security.framework since 10.12, but `SecTranslocate.h` is not exported by the
/// current macOS SDK, so they cannot be called by name at compile time. They are
/// looked up once at runtime instead. Nothing is linked; a missing symbol
/// degrades to "unknown" — never a crash, and never a wrong answer.
enum SecTranslocateShim {
    typealias IsTranslocatedFn = @convention(c) (
        CFURL, UnsafeMutablePointer<DarwinBoolean>,
        UnsafeMutablePointer<Unmanaged<CFError>?>?) -> DarwinBoolean

    typealias OriginalPathFn = @convention(c) (
        CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?

    private nonisolated(unsafe) static let library: UnsafeMutableRawPointer? =
        dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY)

    private nonisolated(unsafe) static let isTranslocatedFn: IsTranslocatedFn? =
        dlsym(library, "SecTranslocateIsTranslocatedURL")
            .map { unsafeBitCast($0, to: IsTranslocatedFn.self) }

    private nonisolated(unsafe) static let originalPathFn: OriginalPathFn? =
        dlsym(library, "SecTranslocateCreateOriginalPathForURL")
            .map { unsafeBitCast($0, to: OriginalPathFn.self) }

    static func isTranslocated(_ url: URL) -> Bool? {
        guard let fn = isTranslocatedFn else { return nil }
        var flag = DarwinBoolean(false)
        var error: Unmanaged<CFError>?
        let ok = fn(url as CFURL, &flag, &error)
        error?.release()
        guard ok.boolValue else { return nil }
        return flag.boolValue
    }

    static func originalPath(_ url: URL) -> URL? {
        guard let fn = originalPathFn else { return nil }
        var error: Unmanaged<CFError>?
        let result = fn(url as CFURL, &error)
        error?.release()
        // Create-rule: the returned CFURL is owned by us.
        return result.map { $0.takeRetainedValue() as URL }
    }
}
