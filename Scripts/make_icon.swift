#!/usr/bin/env swift
// Draws the VoiceVault app icon (waveform melting into text lines on a
// coral→violet gradient) and writes icon_1024.png next to this script.
// Run by build_app.sh; no Xcode asset catalog needed.

import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError("no context") }

// macOS icons supply their own rounded-square canvas.
let inset: CGFloat = size * 0.09
let canvas = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let radius = canvas.width * 0.225
let squircle = NSBezierPath(roundedRect: canvas, xRadius: radius, yRadius: radius)
squircle.addClip()

// Background: deep near-black with a subtle vertical lift, so the gradient
// bars carry all the color.
let bg = NSGradient(colors: [
    NSColor(calibratedRed: 0.10, green: 0.09, blue: 0.13, alpha: 1),
    NSColor(calibratedRed: 0.16, green: 0.13, blue: 0.20, alpha: 1),
])!
bg.draw(in: squircle, angle: 90)

// The mark: seven waveform bars then three text lines, colored by a single
// horizontal coral→violet gradient across the whole group.
let coral = NSColor(calibratedRed: 1.0, green: 0.32, blue: 0.27, alpha: 1)
let violet = NSColor(calibratedRed: 0.55, green: 0.38, blue: 1.0, alpha: 1)

// Left: waveform bars. Right: three horizontal text lines, like the note
// the memo becomes.
let waveHeights: [CGFloat] = [0.34, 0.62, 0.45, 0.74, 0.38, 0.56, 0.28]
let waveWidth = canvas.width * 0.032
let gap = canvas.width * 0.032
let lineBlockWidth = canvas.width * 0.24
let waveBlockWidth = CGFloat(waveHeights.count) * waveWidth
    + CGFloat(waveHeights.count - 1) * gap
let totalWidth = waveBlockWidth + gap * 1.6 + lineBlockWidth
var x = canvas.midX - totalWidth / 2

let group = CGMutablePath()
for h in waveHeights {
    let height = canvas.height * h
    let rect = CGRect(x: x, y: canvas.midY - height / 2, width: waveWidth, height: height)
    group.addPath(CGPath(roundedRect: rect, cornerWidth: waveWidth / 2,
                         cornerHeight: waveWidth / 2, transform: nil))
    x += waveWidth + gap
}
x += gap * 0.6
let lineThickness = canvas.height * 0.045
let lineSpacing = canvas.height * 0.105
let lineWidths: [CGFloat] = [1.0, 0.82, 0.6]
for (i, widthFactor) in lineWidths.enumerated() {
    let y = canvas.midY + lineSpacing - CGFloat(i) * lineSpacing - lineThickness / 2
    let rect = CGRect(x: x, y: y, width: lineBlockWidth * widthFactor, height: lineThickness)
    group.addPath(CGPath(roundedRect: rect, cornerWidth: lineThickness / 2,
                         cornerHeight: lineThickness / 2, transform: nil))
}

ctx.saveGState()
ctx.addPath(group)
ctx.clip()
let markGradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [coral.cgColor, violet.cgColor] as CFArray,
    locations: [0, 1])!
ctx.drawLinearGradient(
    markGradient,
    start: CGPoint(x: canvas.midX - totalWidth / 2, y: canvas.midY),
    end: CGPoint(x: canvas.midX + totalWidth / 2, y: canvas.midY),
    options: [])
ctx.restoreGState()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("couldn't encode png")
}
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "icon_1024.png")
try! png.write(to: out)
print("wrote \(out.path)")
