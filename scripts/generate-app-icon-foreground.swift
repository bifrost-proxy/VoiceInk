#!/usr/bin/env swift

import AppKit
import Foundation

private let usage = "Usage: generate-app-icon-foreground.swift <dark-source.png> <output.png>"

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(Data("\(usage)\n".utf8))
    exit(64)
}

let inputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])

guard
    let sourceData = try? Data(contentsOf: inputURL),
    let source = NSBitmapImageRep(data: sourceData)
else {
    FileHandle.standardError.write(Data("Unable to read \(inputURL.path)\n".utf8))
    exit(65)
}

guard let foreground = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: source.pixelsWide,
    pixelsHigh: source.pixelsHigh,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .calibratedRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    FileHandle.standardError.write(Data("Unable to allocate output bitmap\n".utf8))
    exit(70)
}

// Exact foreground colors sampled from Bifrost's production icon.
let mint = (red: 142.0 / 255.0, green: 252.0 / 255.0, blue: 226.0 / 255.0)
let cyan = (red: 100.0 / 255.0, green: 215.0 / 255.0, blue: 231.0 / 255.0)

for y in 0 ..< source.pixelsHigh {
    for x in 0 ..< source.pixelsWide {
        guard let sourceColor = source.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else {
            continue
        }

        let red = sourceColor.redComponent
        let green = sourceColor.greenComponent
        let blue = sourceColor.blueComponent
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let saturation = maximum > 0 ? (maximum - minimum) / maximum : 0

        // The generated dark master has a black tile. Its microphone pixels are
        // brightly saturated, so this produces a clean antialiased alpha mask
        // while dropping the tile and its subtle gray outline.
        let normalizedX = CGFloat(x) / CGFloat(max(1, source.pixelsWide - 1))
        let normalizedY = CGFloat(y) / CGFloat(max(1, source.pixelsHigh - 1))
        let isInsideArtworkBounds = (0.18 ... 0.82).contains(normalizedX)
            && (0.08 ... 0.93).contains(normalizedY)

        let alpha: CGFloat
        if !isInsideArtworkBounds || saturation < 0.12 || maximum < 0.04 {
            alpha = 0
        } else {
            alpha = min(1, max(0, (maximum - 0.04) / 0.32))
        }

        let progress = min(1, max(0, (normalizedX - 0.25) / 0.5))
        let targetRed = mint.red + (cyan.red - mint.red) * progress
        let targetGreen = mint.green + (cyan.green - mint.green) * progress
        let targetBlue = mint.blue + (cyan.blue - mint.blue) * progress

        foreground.setColor(
            NSColor(
                calibratedRed: targetRed,
                green: targetGreen,
                blue: targetBlue,
                alpha: alpha
            ),
            atX: x,
            y: y
        )
    }
}

let outputSize = NSSize(width: 1024, height: 1024)
guard let resizedBitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(outputSize.width),
    pixelsHigh: Int(outputSize.height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .calibratedRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    FileHandle.standardError.write(Data("Unable to allocate resized bitmap\n".utf8))
    exit(70)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: resizedBitmap)
NSGraphicsContext.current?.imageInterpolation = .high
foreground.draw(in: NSRect(origin: .zero, size: outputSize))
NSGraphicsContext.current?.flushGraphics()
NSGraphicsContext.restoreGraphicsState()

guard let png = resizedBitmap.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write(Data("Unable to encode output PNG\n".utf8))
    exit(70)
}

try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
try png.write(to: outputURL, options: .atomic)

func writeCompositedIcon(backgroundWhite: CGFloat, named filename: String) throws {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(outputSize.width),
        pixelsHigh: Int(outputSize.height),
        bitsPerSample: 8,
        samplesPerPixel: 3,
        hasAlpha: false,
        isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw CocoaError(.fileWriteUnknown)
    }

    let calibratedBackground = NSColor(
        calibratedRed: backgroundWhite,
        green: backgroundWhite,
        blue: backgroundWhite,
        alpha: 1
    )
    for y in 0 ..< bitmap.pixelsHigh {
        for x in 0 ..< bitmap.pixelsWide {
            guard let foregroundColor = resizedBitmap.colorAt(x: x, y: y)?.usingColorSpace(.genericRGB) else {
                bitmap.setColor(calibratedBackground, atX: x, y: y)
                continue
            }

            let alpha = foregroundColor.alphaComponent
            let inverseAlpha = 1 - alpha
            bitmap.setColor(
                NSColor(
                    calibratedRed: foregroundColor.redComponent * alpha + backgroundWhite * inverseAlpha,
                    green: foregroundColor.greenComponent * alpha + backgroundWhite * inverseAlpha,
                    blue: foregroundColor.blueComponent * alpha + backgroundWhite * inverseAlpha,
                    alpha: 1
                ),
                atX: x,
                y: y
            )
        }
    }

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try data.write(
        to: outputURL.deletingLastPathComponent().appendingPathComponent(filename),
        options: .atomic
    )
}

try writeCompositedIcon(backgroundWhite: 1, named: "VoiceInkLight.png")
try writeCompositedIcon(backgroundWhite: 0, named: "VoiceInkDark.png")
