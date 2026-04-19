#!/usr/bin/env swift
//
//  generate_icons.swift
//
//  Renders the PRTracker app icon as a 1024×1024 PNG, then asks `sips` to
//  produce every size the macOS AppIcon.appiconset expects.
//
//  Design:
//    – Indigo → deep-navy linear gradient on a macOS-style "squircle"
//      (rounded rect with corner-radius ratio 0.2237 of the side, matching
//      Big Sur+ system icons).
//    – Subtle inner highlight along the top edge for depth.
//    – Centered white `arrow.triangle.pull` SF Symbol (the literal
//      pull-request glyph) with a soft drop shadow.
//
//  Run from the repo root:
//      swift scripts/generate_icons.swift
//
//  The PNGs are written into PRTracker/Assets.xcassets/AppIcon.appiconset/.

import AppKit
import CoreGraphics
import Foundation

// MARK: - Paths

let fm = FileManager.default
let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
let iconSetURL = cwd
    .appendingPathComponent("PRTracker")
    .appendingPathComponent("Assets.xcassets")
    .appendingPathComponent("AppIcon.appiconset")

guard fm.fileExists(atPath: iconSetURL.path) else {
    FileHandle.standardError.write(Data(
        "error: \(iconSetURL.path) not found. Run from repo root.\n".utf8
    ))
    exit(1)
}

// MARK: - Render the master 1024×1024 icon

let masterSize: CGFloat = 1024
let masterURL = iconSetURL.appendingPathComponent("icon_512x512@2x.png")

func renderMasterIcon(size: CGFloat) -> Data {
    let pixelSize = Int(size)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: pixelSize,
        height: pixelSize,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("Could not create CGContext")
    }

    let rect = CGRect(x: 0, y: 0, width: size, height: size)

    // Squircle clip
    let cornerRadius = size * 0.2237
    let squircle = CGPath(
        roundedRect: rect,
        cornerWidth: cornerRadius,
        cornerHeight: cornerRadius,
        transform: nil
    )
    ctx.addPath(squircle)
    ctx.clip()

    // Background gradient (indigo → deep navy, top-left → bottom-right)
    let topColor = CGColor(red: 0.36, green: 0.40, blue: 0.93, alpha: 1.0)
    let bottomColor = CGColor(red: 0.09, green: 0.12, blue: 0.42, alpha: 1.0)
    let gradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [topColor, bottomColor] as CFArray,
        locations: [0.0, 1.0]
    )!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: size),
        end: CGPoint(x: size, y: 0),
        options: []
    )

    // Subtle top highlight for depth
    let highlight = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.18),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.0)
        ] as CFArray,
        locations: [0.0, 1.0]
    )!
    ctx.drawLinearGradient(
        highlight,
        start: CGPoint(x: size / 2, y: size),
        end: CGPoint(x: size / 2, y: size * 0.55),
        options: []
    )

    // Render `arrow.triangle.pull` SF Symbol centered, white, with shadow.
    // We render via NSImage so the symbol is auto-rasterized at full quality.
    let symbolName = "arrow.triangle.pull"
    let pointSize = size * 0.56
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
    guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else {
        fatalError("SF Symbol \(symbolName) unavailable on this macOS")
    }
    let symbolSize = symbol.size
    let symbolRect = CGRect(
        x: (size - symbolSize.width) / 2,
        y: (size - symbolSize.height) / 2,
        width: symbolSize.width,
        height: symbolSize.height
    )

    // Tint the symbol white via a CIFilter-free approach: draw with white fill.
    let tinted = NSImage(size: symbolSize, flipped: false) { drawRect in
        NSColor.white.set()
        drawRect.fill()
        symbol.draw(
            in: drawRect,
            from: .zero,
            operation: .destinationIn,
            fraction: 1.0
        )
        return true
    }

    let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsCtx

    // Soft shadow under the glyph
    let shadow = NSShadow()
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.012)
    shadow.shadowBlurRadius = size * 0.04
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.set()

    tinted.draw(
        in: symbolRect,
        from: .zero,
        operation: .sourceOver,
        fraction: 1.0
    )

    NSGraphicsContext.restoreGraphicsState()

    guard let cgImage = ctx.makeImage() else {
        fatalError("makeImage failed")
    }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    rep.size = NSSize(width: size, height: size)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("png encoding failed")
    }
    return png
}

let masterPNG = renderMasterIcon(size: masterSize)
try masterPNG.write(to: masterURL)
print("wrote \(masterURL.lastPathComponent)")

// MARK: - Downscale to every required size

struct IconSpec {
    let filename: String
    let pixelSize: Int
}

let specs: [IconSpec] = [
    .init(filename: "icon_16x16.png",      pixelSize: 16),
    .init(filename: "icon_16x16@2x.png",   pixelSize: 32),
    .init(filename: "icon_32x32.png",      pixelSize: 32),
    .init(filename: "icon_32x32@2x.png",   pixelSize: 64),
    .init(filename: "icon_128x128.png",    pixelSize: 128),
    .init(filename: "icon_128x128@2x.png", pixelSize: 256),
    .init(filename: "icon_256x256.png",    pixelSize: 256),
    .init(filename: "icon_256x256@2x.png", pixelSize: 512),
    .init(filename: "icon_512x512.png",    pixelSize: 512),
    // 1024 master already written above.
]

func runSips(input: URL, output: URL, pixelSize: Int) throws {
    let task = Process()
    task.launchPath = "/usr/bin/sips"
    task.arguments = [
        "-z", "\(pixelSize)", "\(pixelSize)",
        input.path,
        "--out", output.path
    ]
    let nullPipe = Pipe()
    task.standardOutput = nullPipe
    task.standardError = nullPipe
    try task.run()
    task.waitUntilExit()
    if task.terminationStatus != 0 {
        throw NSError(
            domain: "sips",
            code: Int(task.terminationStatus),
            userInfo: [NSLocalizedDescriptionKey: "sips failed for \(output.lastPathComponent)"]
        )
    }
}

for spec in specs {
    let outURL = iconSetURL.appendingPathComponent(spec.filename)
    try runSips(input: masterURL, output: outURL, pixelSize: spec.pixelSize)
    print("wrote \(spec.filename) (\(spec.pixelSize)px)")
}

print("done.")
