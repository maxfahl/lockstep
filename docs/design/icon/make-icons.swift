// Draws the three icon ideas for Lockstep as PNG pictures, large and small,
// and the chosen one at every size the app needs.
//
//     swift docs/design/icon/make-icons.swift
//
// Run from the repository root. Writes <idea>-1024.png and <idea>-64.png next
// to this file for each idea. Everything is drawn on a 1024 by 1024 canvas and
// scaled down, so the small picture is the same drawing seen from afar. Then it
// writes the chosen idea into Lockstep/Resources/Assets.xcassets/AppIcon.appiconset.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// The colours of the app (LockstepUI/DesignTokens.swift).
let accent = CGColor(srgbRed: 0x8A / 255, green: 0x8F / 255, blue: 0xFF / 255, alpha: 1)
let windowBackground = CGColor(srgbRed: 0x0B / 255, green: 0x0B / 255, blue: 0x0E / 255, alpha: 1)
let tileTop = CGColor(srgbRed: 0x1C / 255, green: 0x1C / 255, blue: 0x24 / 255, alpha: 1)
func white(_ alpha: CGFloat) -> CGColor { CGColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha) }

// The tile every macOS app icon sits on: a rounded square with the standard
// margin of a 1024 canvas, so the pictures look like icons in the Dock.
let tileRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let tileRadius: CGFloat = 185

func drawTile(_ c: CGContext) {
    let tile = CGPath(roundedRect: tileRect, cornerWidth: tileRadius, cornerHeight: tileRadius, transform: nil)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: CGColor(gray: 0, alpha: 0.5))
    c.addPath(tile)
    c.setFillColor(windowBackground)
    c.fillPath()
    c.restoreGState()
    c.saveGState()
    c.addPath(tile)
    c.clip()
    let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                              colors: [tileTop, windowBackground] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(gradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    c.restoreGState()
    c.addPath(CGPath(roundedRect: tileRect.insetBy(dx: 2, dy: 2), cornerWidth: tileRadius - 2,
                     cornerHeight: tileRadius - 2, transform: nil))
    c.setStrokeColor(white(0.10))
    c.setLineWidth(4)
    c.strokePath()
}

// Idea 1, "On the beat": five evenly spaced beat lines and a short voice
// waveform whose syllables swell exactly on the lines.
func drawOnTheBeat(_ c: CGContext) {
    let beats: [CGFloat] = [272, 392, 512, 632, 752]
    let heights: [CGFloat] = [0.70, 1.00, 0.55, 0.90, 0.65]
    c.setLineCap(.round)
    c.setStrokeColor(white(0.30))
    c.setLineWidth(18)
    for x in beats {
        c.move(to: CGPoint(x: x, y: 250))
        c.addLine(to: CGPoint(x: x, y: 774))
    }
    c.strokePath()

    func amplitude(_ x: CGFloat) -> CGFloat {
        var a: CGFloat = 0
        for (b, h) in zip(beats, heights) {
            let d = (x - b) / 34
            a = max(a, 200 * h * exp(-d * d / 2))
        }
        // The ends taper to nothing, so the voice starts and stops.
        let edge = min(x - 212, 812 - x) / 60
        return max(a, 14 * min(max(edge, 0), 1))
    }
    let path = CGMutablePath()
    let start: CGFloat = 212, end: CGFloat = 812
    path.move(to: CGPoint(x: start, y: 512))
    for x in stride(from: start, through: end, by: 2) { path.addLine(to: CGPoint(x: x, y: 512 + amplitude(x))) }
    for x in stride(from: end, through: start, by: -2) { path.addLine(to: CGPoint(x: x, y: 512 - amplitude(x))) }
    path.closeSubpath()
    c.addPath(path)
    c.setFillColor(accent)
    c.fillPath()
}

// Idea 2, "In step": four syllables of a voice in the accent, each standing
// exactly over one of four grey beat dots, like two rows walking in lockstep.
func drawInStep(_ c: CGContext) {
    let xs: [CGFloat] = [302, 442, 582, 722]
    let topHeights: [CGFloat] = [250, 190, 290, 210]
    for (x, h) in zip(xs, topHeights) {
        let r = CGRect(x: x - 42, y: 470, width: 84, height: h)
        c.addPath(CGPath(roundedRect: r, cornerWidth: 42, cornerHeight: 42, transform: nil))
    }
    c.setFillColor(accent)
    c.fillPath()
    for x in xs {
        c.addEllipse(in: CGRect(x: x - 42, y: 330, width: 84, height: 84))
    }
    c.setFillColor(white(0.42))
    c.fillPath()
}

// Idea 3, "Round the bar": a waveform bent into a ring, one bar going round,
// swelling on each of the four beats, which are bright dots at the top, right,
// bottom and left.
func drawRoundTheBar(_ c: CGContext) {
    let centre = CGPoint(x: 512, y: 512)
    let count = 36
    let inner: CGFloat = 150
    // A fixed, uneven pattern so the ring looks like a voice, not a gear.
    let texture: [CGFloat] = [1.0, 0.7, 0.85, 0.55, 0.75, 0.6, 0.9, 0.5, 0.8]
    c.setLineCap(.round)
    c.setLineWidth(24)
    c.setStrokeColor(accent)
    for i in 0..<count {
        let angle = CGFloat(i) / CGFloat(count) * 2 * .pi
        // Distance in bars from the nearest beat; the voice swells on each beat.
        let phase = CGFloat(i % 9)
        let distance = min(phase, 9 - phase)
        let length = 30 + 120 * texture[i % 9] * (0.35 + 0.65 * exp(-distance * distance / 6))
        c.move(to: CGPoint(x: centre.x + inner * sin(angle), y: centre.y + inner * cos(angle)))
        c.addLine(to: CGPoint(x: centre.x + (inner + length) * sin(angle), y: centre.y + (inner + length) * cos(angle)))
    }
    c.strokePath()
    // The four beats, as bright dots just outside the ring.
    c.setFillColor(white(0.92))
    for i in 0..<4 {
        let angle = CGFloat(i) / 4 * 2 * .pi
        let r: CGFloat = 340
        let p = CGPoint(x: centre.x + r * sin(angle), y: centre.y + r * cos(angle))
        c.addEllipse(in: CGRect(x: p.x - 28, y: p.y - 28, width: 56, height: 56))
    }
    c.fillPath()
}

let ideas: [(name: String, draw: (CGContext) -> Void)] = [
    ("on-the-beat", drawOnTheBeat),
    ("in-step", drawInStep),
    ("round-the-bar", drawRoundTheBar),
]

let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

func render(_ draw: (CGContext) -> Void, size: Int, to url: URL) {
    let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.interpolationQuality = .high
    c.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    drawTile(c)
    draw(c)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, c.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
}

for idea in ideas {
    for size in [1024, 64] {
        let url = folder.appendingPathComponent("\(idea.name)-\(size).png")
        render(idea.draw, size: size, to: url)
        print("Wrote \(url.path)")
    }
}

// The app's own icon. Max chose "In step" on 13 November 2026. macOS wants the
// icon as an asset catalog icon set: five sizes in points (16, 32, 128, 256 and
// 512), each at 1x and 2x, so ten pictures from 16 to 1024 pixels. Each one is
// drawn from scratch at its own size, tile and margin included, rather than
// shrunk from the large picture, so the small ones stay sharp.
let chosen = drawInStep
let repository = folder.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let catalog = repository.appendingPathComponent("Lockstep/Resources/Assets.xcassets")
let iconSet = catalog.appendingPathComponent("AppIcon.appiconset")
try FileManager.default.createDirectory(at: iconSet, withIntermediateDirectories: true)

var images: [String] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        render(chosen, size: points * scale, to: iconSet.appendingPathComponent(name))
        images.append("""
            { "filename" : "\(name)", "idiom" : "mac", "scale" : "\(scale)x", "size" : "\(points)x\(points)" }
        """)
    }
}
let info = #""info" : { "author" : "xcode", "version" : 1 }"#
try "{\n  \"images\" : [\n\(images.joined(separator: ",\n"))\n  ],\n  \(info)\n}\n"
    .write(to: iconSet.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
try "{\n  \(info)\n}\n".write(to: catalog.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("Wrote the app icon, ten sizes, to \(iconSet.path)")
