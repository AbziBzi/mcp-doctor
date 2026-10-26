// Draws the app icon: a heartbeat line between two connection points (an agent and an MCP
// server) on a teal-to-blue glass tile. Writes Resources/AppIcon.icns and docs/icon.png.
//
//   swift scripts/make-icon.swift
//
// Everything is drawn with Core Graphics in a 1024×1024 space, following Apple's icon grid
// (an 824×824 tile with 100 px margins). Small sizes get thicker strokes to stay legible.
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

/// A superellipse, close to the continuous-corner tile macOS uses for app icons.
func tile(_ rect: CGRect, exponent: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let steps = 1440
    for step in 0...steps {
        let angle = CGFloat(step) / CGFloat(steps) * 2 * .pi
        let cosine = cos(angle), sine = sin(angle)
        let point = CGPoint(
            x: rect.midX + rect.width / 2 * copysign(pow(abs(cosine), 2 / exponent), cosine),
            y: rect.midY + rect.height / 2 * copysign(pow(abs(sine), 2 / exponent), sine)
        )
        if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    return path
}

func render(size: Int) -> CGImage {
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let scale = CGFloat(size) / 1024
    // Work in a 1024-point space with y pointing down.
    context.translateBy(x: 0, y: CGFloat(size))
    context.scaleBy(x: scale, y: -scale)

    let small = size <= 32
    let shape = tile(CGRect(x: 100, y: 100, width: 824, height: 824))

    // Background: teal to blue, with a soft glass highlight across the top.
    context.saveGState()
    context.addPath(shape)
    context.clip()
    let background = CGGradient(
        colorsSpace: nil,
        colors: [color(0x2FD8C0), color(0x1E9BD7), color(0x2B4FE0)] as CFArray,
        locations: [0, 0.5, 1]
    )!
    context.drawLinearGradient(
        background, start: CGPoint(x: 300, y: 100), end: CGPoint(x: 724, y: 924),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    let highlight = CGGradient(
        colorsSpace: nil,
        colors: [color(0xFFFFFF, 0.32), color(0xFFFFFF, 0)] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(highlight, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 560), options: [])
    context.restoreGState()

    // A thin light rim, like the edge of a glass tile.
    if !small {
        context.addPath(shape)
        context.setStrokeColor(color(0xFFFFFF, 0.28))
        context.setLineWidth(5)
        context.strokePath()
    }

    // The heartbeat line and its two endpoints, with a soft shadow below.
    let baseline: CGFloat = 540
    let pulse = CGMutablePath()
    pulse.move(to: CGPoint(x: 262, y: baseline))
    pulse.addLine(to: CGPoint(x: 408, y: baseline))
    pulse.addLine(to: CGPoint(x: 452, y: baseline + 52))
    pulse.addLine(to: CGPoint(x: 514, y: 300))
    pulse.addLine(to: CGPoint(x: 578, y: 742))
    pulse.addLine(to: CGPoint(x: 624, y: baseline))
    pulse.addLine(to: CGPoint(x: 762, y: baseline))

    let lineWidth: CGFloat = small ? 92 : 54
    let nodeRadius: CGFloat = small ? 74 : 50

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -14 * scale), blur: 28 * scale, color: color(0x0A1A5C, 0.35))
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    context.setStrokeColor(color(0xFFFFFF))
    context.setFillColor(color(0xFFFFFF))
    context.setLineWidth(lineWidth)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.addPath(pulse)
    context.strokePath()
    for x in [262.0, 762.0] {
        context.fillEllipse(in: CGRect(x: x - nodeRadius, y: baseline - nodeRadius, width: nodeRadius * 2, height: nodeRadius * 2))
    }
    context.endTransparencyLayer()
    context.restoreGState()

    // Hollow out the endpoints so they read as connection points.
    if !small {
        context.setFillColor(color(0x1E9BD7))
        let inner = nodeRadius * 0.42
        for x in [262.0, 762.0] {
            context.fillEllipse(in: CGRect(x: x - inner, y: baseline - inner, width: inner * 2, height: inner * 2))
        }
    }

    return context.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Couldn't write \(url.path)") }
}

let iconset = FileManager.default.temporaryDirectory.appending(path: "AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

let files: [(Int, [String])] = [
    (16, ["icon_16x16"]),
    (32, ["icon_16x16@2x", "icon_32x32"]),
    (64, ["icon_32x32@2x"]),
    (128, ["icon_128x128"]),
    (256, ["icon_128x128@2x", "icon_256x256"]),
    (512, ["icon_256x256@2x", "icon_512x512"]),
    (1024, ["icon_512x512@2x"]),
]
for (size, names) in files {
    let image = render(size: size)
    for name in names {
        writePNG(image, to: iconset.appending(path: "\(name).png"))
    }
}

let icns = root.appending(path: "Resources/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }

let docs = root.appending(path: "docs")
try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
writePNG(render(size: 1024), to: docs.appending(path: "icon.png"))
print("Wrote \(icns.path) and docs/icon.png")
