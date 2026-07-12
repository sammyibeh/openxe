import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// ICO data -> .icns, via ImageIO (decode + resize) and iconutil (pack).
/// Returns false on any failure — icon problems must never block a launch.
public enum IconBuilder {
    public static func makeICNS(fromICO ico: Data, output: URL) -> Bool {
        guard let source = CGImageSourceCreateWithData(ico as CFData, [
            kCGImageSourceTypeIdentifierHint: "com.microsoft.ico" as CFString,
        ] as CFDictionary) else { return false }

        // Largest frame wins.
        var bestImage: CGImage?
        for i in 0..<CGImageSourceGetCount(source) {
            if let img = CGImageSourceCreateImageAtIndex(source, i, nil),
               img.width > (bestImage?.width ?? 0) {
                bestImage = img
            }
        }
        guard let master = bestImage else { return false }

        let fm = FileManager.default
        let iconset = fm.temporaryDirectory
            .appendingPathComponent("openxe-\(UUID().uuidString).iconset", isDirectory: true)
        defer { try? fm.removeItem(at: iconset) }
        do { try fm.createDirectory(at: iconset, withIntermediateDirectories: true) }
        catch { return false }

        // A subset of iconset sizes is valid; cover the common points.
        for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2)] {
            let pixels = points * scale
            guard let ctx = CGContext(
                data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(master, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
            guard let scaled = ctx.makeImage() else { return false }
            let name = scale == 1 ? "icon_\(points)x\(points).png"
                                  : "icon_\(points)x\(points)@2x.png"
            let url = iconset.appendingPathComponent(name)
            guard let dest = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
            CGImageDestinationAddImage(dest, scaled, nil)
            guard CGImageDestinationFinalize(dest) else { return false }
        }

        let result = try? Subprocess.run(
            URL(fileURLWithPath: "/usr/bin/iconutil"),
            arguments: ["-c", "icns", "-o", output.path, iconset.path],
            timeout: 60)
        return result?.status == 0 && FileManager.default.fileExists(atPath: output.path)
    }
}

public enum LauncherError: Error, LocalizedError {
    case signingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .signingFailed(let detail): return "Could not sign the launcher app: \(detail)"
        }
    }
}

/// Generates per-exe launcher apps in "/Applications/OpenXE Apps" (fallback
/// "~/Applications/OpenXE Apps") so Windows programs appear in Spotlight and
/// Launchpad. Spec §9.3. Bundles reference the original .exe — never copy it.
public final class LauncherManager: Sendable {
    /// Info.plist key marking a bundle as OpenXE-generated; holds the exe path.
    public static let targetPathKey = "OpenXETargetPath"

    public let baseDirectory: URL
    /// Directories scanned for existing launchers. The default manager scans
    /// primary + fallback; an explicit baseDirectory (tests) scans only itself.
    private let scanDirectories: [URL]

    /// All directories launchers may live in (primary + fallback).
    public static var candidateDirectories: [URL] {
        [
            URL(fileURLWithPath: "/Applications/OpenXE Apps", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/OpenXE Apps", isDirectory: true),
        ]
    }

    /// Primary location when writable, else the per-user fallback.
    public static func defaultBaseDirectory() -> URL {
        FileManager.default.isWritableFile(atPath: "/Applications")
            ? candidateDirectories[0]
            : candidateDirectories[1]
    }

    public init(baseDirectory: URL? = nil) {
        if let baseDirectory {
            self.baseDirectory = baseDirectory
            self.scanDirectories = [baseDirectory]
        } else {
            self.baseDirectory = Self.defaultBaseDirectory()
            self.scanDirectories = Self.candidateDirectories
        }
    }

    // MARK: queries

    /// True when a generated launcher pointing at exactly this exe already
    /// exists in any candidate location (or this manager's base directory).
    public func launcherExists(for exe: URL) -> Bool {
        existingLaunchers().contains { $0.target == exe.path }
    }

    /// The exe paths of every generated launcher, for the per-app settings UI
    /// (the natural set of "apps OpenXE knows about"). Deduplicated.
    public func knownTargetPaths() -> [String] {
        Array(Set(existingLaunchers().map { $0.target })).sorted()
    }

    private func existingLaunchers() -> [(bundle: URL, target: String)] {
        let fm = FileManager.default
        var found: [(URL, String)] = []
        for dir in scanDirectories {
            let bundles = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for bundle in bundles where bundle.pathExtension == "app" {
                if let target = targetPath(ofBundle: bundle) {
                    found.append((bundle, target))
                }
            }
        }
        return found
    }

    private func targetPath(ofBundle bundle: URL) -> String? {
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        else { return nil }
        return dict[Self.targetPathKey] as? String
    }

    // MARK: creation

    /// Creates (or recreates) the launcher for `exe`. `fallbackIcon` is used
    /// when PE icon extraction fails. Returns the bundle URL.
    @discardableResult
    public func createLauncher(for exe: URL, fallbackIcon: URL?) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: baseDirectory, withIntermediateDirectories: true)

        let name = launcherName(for: exe)
        let bundle = baseDirectory.appendingPathComponent("\(name).app", isDirectory: true)
        try? fm.removeItem(at: bundle) // stale launcher with the same name
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)

        // Stub executable: hand the exe back to OpenXE by bundle id.
        // Single-quote the path; escape embedded single quotes for sh.
        let quoted = "'" + exe.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = "#!/bin/sh\nexec /usr/bin/open -b dev.openxe.OpenXE \(quoted)\n"
        let stub = macOS.appendingPathComponent("launcher")
        try Data(script.utf8).write(to: stub)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        // Icon: extracted from the exe's PE resources, else the fallback.
        var hasIcon = false
        let icnsURL = resources.appendingPathComponent("AppIcon.icns")
        if let ico = PEResources.extractPrimaryIconICO(fromFileAt: exe),
           IconBuilder.makeICNS(fromICO: ico, output: icnsURL) {
            hasIcon = true
        } else if let fallbackIcon, (try? fm.copyItem(at: fallbackIcon, to: icnsURL)) != nil {
            hasIcon = true
        }

        // Stable identifier derived from the exe path.
        let pathDigest = (try? FileHasher.sha256Hex(of: exe).prefix(12))
            .map(String.init) ?? UUID().uuidString
        var plist: [String: Any] = [
            "CFBundleName": name,
            "CFBundleDisplayName": name,
            "CFBundleIdentifier": "dev.openxe.launcher.\(pathDigest)",
            "CFBundleExecutable": "launcher",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "LSMinimumSystemVersion": "14.0",
            // The stub only re-dispatches to OpenXE (`open -b`) and must never
            // take a Dock tile of its own — the Wine GUI process (Runner's icon
            // wrapper) owns the one visible Dock icon. Without this the stub
            // shows a second tile that lingers while its subordinates run.
            "LSUIElement": true,
            Self.targetPathKey: exe.path,
        ]
        if hasIcon { plist["CFBundleIconFile"] = "AppIcon" }
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: contents.appendingPathComponent("Info.plist"))

        // Ad-hoc signature — Gatekeeper complains about unsigned bundles.
        let sign = try Subprocess.run(
            URL(fileURLWithPath: "/usr/bin/codesign"),
            arguments: ["--force", "-s", "-", bundle.path],
            timeout: 60)
        guard sign.status == 0 else {
            try? fm.removeItem(at: bundle)
            throw LauncherError.signingFailed(String(sign.output.suffix(300)))
        }

        // Make Spotlight/Launchpad aware of it.
        _ = try? Subprocess.run(
            URL(fileURLWithPath: "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"),
            arguments: ["-f", bundle.path],
            timeout: 60)
        return bundle
    }

    /// Deletes every OpenXE-generated launcher (identified by the marker key)
    /// in all candidate locations. Returns how many were removed.
    @discardableResult
    public func removeAllLaunchers() -> Int {
        var removed = 0
        for (bundle, _) in existingLaunchers() where (try? FileManager.default.removeItem(at: bundle)) != nil {
            removed += 1
        }
        return removed
    }

    // MARK: naming

    private func launcherName(for exe: URL) -> String {
        var base = PEResources.productName(fromFileAt: exe)
            ?? exe.deletingPathExtension().lastPathComponent
        base = base
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = "Windows Program" }
        base = String(base.prefix(60))

        // Collisions with launchers for *other* exes get a numeric suffix.
        let fm = FileManager.default
        var candidate = base
        var n = 2
        while true {
            let bundle = baseDirectory.appendingPathComponent("\(candidate).app")
            if !fm.fileExists(atPath: bundle.path) { return candidate }
            if targetPath(ofBundle: bundle) == exe.path { return candidate } // ours; recreate in place
            candidate = "\(base) \(n)"
            n += 1
        }
    }
}
