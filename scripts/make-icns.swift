#!/usr/bin/env swift
import AppKit
import Foundation

// Renders a simple hard-drive icon into Resources/AppIcon.iconset and converts it to .icns.

let fileManager = FileManager.default
let root = URL(fileURLWithPath: fileManager.currentDirectoryPath)
let iconsetURL = root.appendingPathComponent("Resources/AppIcon.iconset")
let icnsURL = root.appendingPathComponent("Resources/AppIcon.icns")

try? fileManager.removeItem(at: iconsetURL)
try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

func makeIcon(pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }

    rep.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.current = context

    let size = CGFloat(pixels)
    let fullRect = NSRect(x: 0, y: 0, width: size, height: size)

    // Background
    let inset = size * 0.06
    let backgroundRect = fullRect.insetBy(dx: inset, dy: inset)
    let backgroundPath = NSBezierPath(roundedRect: backgroundRect, xRadius: size * 0.22, yRadius: size * 0.22)
    let topColor = NSColor(calibratedRed: 0.30, green: 0.35, blue: 0.44, alpha: 1.0)
    let bottomColor = NSColor(calibratedRed: 0.11, green: 0.13, blue: 0.19, alpha: 1.0)
    if let gradient = NSGradient(starting: topColor, ending: bottomColor) {
        gradient.draw(in: backgroundPath, angle: -90)
    } else {
        bottomColor.setFill()
        backgroundPath.fill()
    }

    // Drive body
    let bodyWidth = size * 0.66
    let bodyHeight = size * 0.44
    let bodyRect = NSRect(
        x: (size - bodyWidth) / 2,
        y: (size - bodyHeight) / 2 + size * 0.02,
        width: bodyWidth,
        height: bodyHeight
    )
    let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: size * 0.07, yRadius: size * 0.07)
    NSColor(calibratedWhite: 0.96, alpha: 1.0).setFill()
    bodyPath.fill()

    // Vent slot
    let slotRect = NSRect(
        x: bodyRect.minX + bodyWidth * 0.62,
        y: bodyRect.midY - size * 0.035,
        width: bodyWidth * 0.26,
        height: size * 0.07
    )
    NSColor(calibratedWhite: 0.30, alpha: 1.0).setFill()
    NSBezierPath(roundedRect: slotRect, xRadius: size * 0.035, yRadius: size * 0.035).fill()

    // Label circle
    let circleSize = size * 0.13
    let circleRect = NSRect(
        x: bodyRect.minX + bodyWidth * 0.14,
        y: bodyRect.midY - circleSize / 2,
        width: circleSize,
        height: circleSize
    )
    NSColor(calibratedRed: 0.22, green: 0.47, blue: 0.75, alpha: 1.0).setFill()
    NSBezierPath(ovalIn: circleRect).fill()

    // Status dot
    let dotSize = size * 0.16
    let dotRect = NSRect(
        x: size * 0.64,
        y: size * 0.16,
        width: dotSize,
        height: dotSize
    )
    NSColor(calibratedRed: 0.24, green: 0.82, blue: 0.42, alpha: 1.0).setFill()
    NSBezierPath(ovalIn: dotRect).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

struct IconFile {
    let pixels: Int
    let name: String
}

let files: [IconFile] = [
    IconFile(pixels: 16, name: "icon_16x16.png"),
    IconFile(pixels: 32, name: "icon_16x16@2x.png"),
    IconFile(pixels: 32, name: "icon_32x32.png"),
    IconFile(pixels: 64, name: "icon_32x32@2x.png"),
    IconFile(pixels: 128, name: "icon_128x128.png"),
    IconFile(pixels: 256, name: "icon_128x128@2x.png"),
    IconFile(pixels: 256, name: "icon_256x256.png"),
    IconFile(pixels: 512, name: "icon_256x256@2x.png"),
    IconFile(pixels: 512, name: "icon_512x512.png"),
    IconFile(pixels: 1024, name: "icon_512x512@2x.png")
]

for file in files {
    guard let data = makeIcon(pixels: file.pixels) else {
        fputs("Konnte \(file.name) nicht erzeugen\n", stderr)
        exit(1)
    }
    try data.write(to: iconsetURL.appendingPathComponent(file.name))
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetURL.path, "-o", icnsURL.path]
try process.run()
process.waitUntilExit()

if process.terminationStatus == 0 {
    print("Icon erstellt: \(icnsURL.path)")
} else {
    fputs("iconutil fehlgeschlagen\n", stderr)
    exit(process.terminationStatus)
}
