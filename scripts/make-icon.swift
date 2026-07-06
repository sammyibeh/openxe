#!/usr/bin/env swift
// Generates Resources/OpenXE.icns and Resources/LauncherFallback.icns
// programmatically — no external assets. Spec §9.1. Build-time only; AppKit
// used here never becomes an app dependency.
//
// Usage: swift scripts/make-icon.swift <output-dir>

import AppKit

let outputDir = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "Resources", isDirectory: true)

func render(pixels: Int, fallback: Bool) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let s = CGFloat(pixels)
    // macOS-style icon grid: content tile inset ~10%, corner radius ~22.37%.
    let inset = s * 0.10
    let tile = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.2237,
                            yRadius: tile.width * 0.2237)

    let top: NSColor
    let bottom: NSColor
    if fallback {
        top = NSColor(calibratedRed: 0.42, green: 0.44, blue: 0.50, alpha: 1)
        bottom = NSColor(calibratedRed: 0.20, green: 0.21, blue: 0.26, alpha: 1)
    } else {
        top = NSColor(calibratedRed: 0.18, green: 0.24, blue: 0.38, alpha: 1)
        bottom = NSColor(calibratedRed: 0.05, green: 0.07, blue: 0.13, alpha: 1)
    }
    NSGradient(starting: top, ending: bottom)!.draw(in: path, angle: -90)

    // Glyph: a terse prompt caret + "XE".
    let caret = NSMutableParagraphStyle()
    caret.alignment = .center
    let fontSize = tile.width * (fallback ? 0.30 : 0.34)
    let text = NSAttributedString(
        string: fallback ? "EXE" : "\u{203A}XE", // ›XE
        attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .heavy),
            .foregroundColor: NSColor.white.withAlphaComponent(fallback ? 0.85 : 0.96),
            .paragraphStyle: caret,
        ])
    let textSize = text.size()
    text.draw(at: NSPoint(x: tile.midX - textSize.width / 2,
                          y: tile.midY - textSize.height / 2))

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func makeIcns(name: String, fallback: Bool) throws {
    let fm = FileManager.default
    let iconset = fm.temporaryDirectory
        .appendingPathComponent("\(name)-\(UUID().uuidString).iconset", isDirectory: true)
    try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: iconset) }

    for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                            (256, 1), (256, 2), (512, 1), (512, 2)] {
        let rep = render(pixels: points * scale, fallback: fallback)
        let file = scale == 1 ? "icon_\(points)x\(points).png"
                              : "icon_\(points)x\(points)@2x.png"
        try rep.representation(using: .png, properties: [:])!
            .write(to: iconset.appendingPathComponent(file))
    }

    try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)
    let out = outputDir.appendingPathComponent("\(name).icns")
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    task.arguments = ["-c", "icns", "-o", out.path, iconset.path]
    try task.run()
    task.waitUntilExit()
    guard task.terminationStatus == 0 else {
        fputs("iconutil failed for \(name)\n", stderr)
        exit(1)
    }
    print("wrote \(out.path)")
}

try makeIcns(name: "OpenXE", fallback: false)
try makeIcns(name: "LauncherFallback", fallback: true)
