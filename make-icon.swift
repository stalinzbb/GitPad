#!/usr/bin/env swift
// Draws Resources/AppIcon-1024.png — the Dock/Finder icon. Run via make-icns.sh.
// The menu-bar glyph is a *template* SF Symbol instead (see GitPadApp.statusImage),
// so it adapts to light/dark menu bars; this one is the full-colour app icon.
import AppKit

let size = 1024.0
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()

// rounded-square plate with a violet gradient
let inset = size * 0.09
let plate = NSBezierPath(roundedRect: NSRect(x: inset, y: inset,
                                             width: size - inset * 2, height: size - inset * 2),
                         xRadius: size * 0.2237, yRadius: size * 0.2237)
NSGradient(colors: [NSColor(srgbRed: 0.42, green: 0.31, blue: 0.85, alpha: 1),
                    NSColor(srgbRed: 0.62, green: 0.36, blue: 0.92, alpha: 1)])?
    .draw(in: plate, angle: -90)

// page: a white sheet with a folded corner
let w = size * 0.42, h = size * 0.50
let x = (size - w) / 2, y = (size - h) / 2
let fold = size * 0.11
let page = NSBezierPath()
page.move(to: NSPoint(x: x, y: y))
page.line(to: NSPoint(x: x + w, y: y))
page.line(to: NSPoint(x: x + w, y: y + h - fold))
page.line(to: NSPoint(x: x + w - fold, y: y + h))
page.line(to: NSPoint(x: x, y: y + h))
page.close()
NSColor.white.setFill()
page.fill()

// three ruled lines + a checked box, drawn as plain strokes (no font dependency)
NSColor(srgbRed: 0.42, green: 0.31, blue: 0.85, alpha: 1).setStroke()
let pad = w * 0.16
for i in 0..<3 {
    let ly = y + h * (0.62 - Double(i) * 0.19)
    let line = NSBezierPath()
    line.lineWidth = size * 0.022
    line.lineCapStyle = .round
    // the bottom line sits beside the checkmark, so it starts further in
    line.move(to: NSPoint(x: x + pad + [0, 0.16, 0.30][i] * w, y: ly))
    line.line(to: NSPoint(x: x + w - pad, y: ly))
    line.stroke()
}
let check = NSBezierPath()
check.lineWidth = size * 0.026
check.lineCapStyle = .round
check.lineJoinStyle = .round
let cy = y + h * 0.24
check.move(to: NSPoint(x: x + pad, y: cy))
check.line(to: NSPoint(x: x + pad + w * 0.07, y: cy - w * 0.06))
check.line(to: NSPoint(x: x + pad + w * 0.17, y: cy + w * 0.08))
check.stroke()

img.unlockFocus()

let out = URL(fileURLWithPath: "Resources/AppIcon-1024.png")
try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)
guard let tiff = img.tiffRepresentation,
      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
    fatalError("could not render icon")
}
try! png.write(to: out)
print("wrote \(out.path)")
