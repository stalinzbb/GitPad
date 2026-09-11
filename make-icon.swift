#!/usr/bin/env swift
// Writes Resources/AppIcon-1024.png from Resources/AppIcon-source.png. Run via make-icns.sh.
//
// The source is the designed icon, edge to edge. macOS wants the rounded plate at
// 824×824 inside a 1024 canvas (a 100pt transparent margin on every side), or it
// renders visibly larger than every other icon in the Dock. Only that padding
// happens here — no drawing. The menu-bar glyph is Resources/MenuBarIcon.svg, loaded
// as a template image (see GitPadApp.statusImage).
import AppKit

let size = 1024.0, plate = 824.0
guard let src = NSImage(contentsOfFile: "Resources/AppIcon-source.png") else {
    FileHandle.standardError.write(Data("make-icon: Resources/AppIcon-source.png missing\n".utf8))
    exit(1)
}
let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
    let inset = (size - plate) / 2
    src.draw(in: NSRect(x: inset, y: inset, width: plate, height: plate),
             from: .zero, operation: .sourceOver, fraction: 1)
    return true
}
// draw into a bitmap at exactly 1024 px, independent of the screen's scale
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
img.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .copy, fraction: 1)
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "Resources/AppIcon-1024.png"))
print("wrote Resources/AppIcon-1024.png")
