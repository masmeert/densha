#!/usr/bin/env swift
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/Densha.iconset")
let output = root.appendingPathComponent("Resources/Densha.icns")

let variants: [(Int, Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
    (256, 1), (256, 2), (512, 1), (512, 2),
]

func color(_ hex: UInt32) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: 1)
}

func render(pixels: Int) -> Data {
    guard
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { fatalError("cannot allocate \(pixels)px bitmap") }
    rep.size = NSSize(width: pixels, height: pixels)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    let canvas = CGFloat(pixels)
    let inset = canvas * 0.094
    let side = canvas - inset * 2
    let squircle = NSRect(x: inset, y: inset, width: side, height: side)
    let radius = side * 0.224

    let path = NSBezierPath(roundedRect: squircle, xRadius: radius, yRadius: radius)
    NSGradient(starting: color(0x5B7CFA), ending: color(0x2436A7))?
        .draw(in: path, angle: -90)

    if pixels >= 128 {
        path.lineWidth = max(1, canvas * 0.004)
        color(0xFFFFFF).withAlphaComponent(0.22).setStroke()
        path.stroke()
    }

    let glyphSide = side * 0.58
    let configuration = NSImage.SymbolConfiguration(pointSize: glyphSide, weight: .medium)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    guard
        let symbol = NSImage(systemSymbolName: "tram.fill", accessibilityDescription: "Densha")?
            .withSymbolConfiguration(configuration)
    else { fatalError("SF Symbol tram.fill unavailable") }

    let drawn = symbol.size
    let scale = min(glyphSide / drawn.width, glyphSide / drawn.height)
    let target = NSSize(width: drawn.width * scale, height: drawn.height * scale)
    let origin = NSPoint(x: (canvas - target.width) / 2, y: (canvas - target.height) / 2)
    let box = NSRect(origin: origin, size: target)

    NSGraphicsContext.current?.imageInterpolation = .high
    symbol.isTemplate = false
    symbol.draw(in: box)

    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("PNG encoding failed")
    }
    return png
}

try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for (size, scale) in variants {
    let suffix = scale == 1 ? "" : "@\(scale)x"
    let name = "icon_\(size)x\(size)\(suffix).png"
    try render(pixels: size * scale).write(to: iconset.appendingPathComponent(name))
}

try FileManager.default.createDirectory(
    at: output.deletingLastPathComponent(), withIntermediateDirectories: true)

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}
print("wrote \(output.path)")
