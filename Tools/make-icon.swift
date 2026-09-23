// Génère Resources/AppIcon.icns : swift Tools/make-icon.swift
import AppKit

func render(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: size / 1024, y: size / 1024)

    // Fond : « squircle » macOS sur la grille 1024 (marge 100).
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
    ctx.saveGState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    NSColor.black.setFill()
    tilePath.fill()
    ctx.restoreGState()
    ctx.saveGState()
    tilePath.addClip()
    NSGradient(colors: [NSColor(srgbRed: 0.33, green: 0.20, blue: 0.85, alpha: 1),
                        NSColor(srgbRed: 0.10, green: 0.55, blue: 0.98, alpha: 1)])!
        .draw(in: tile, angle: 60)

    // Fenêtre en arrière-plan (estompée).
    func window(_ r: NSRect, alpha: CGFloat) {
        let body = NSBezierPath(roundedRect: r, xRadius: 38, yRadius: 38)
        NSColor.white.withAlphaComponent(alpha).setFill()
        body.fill()
        let bar = NSRect(x: r.minX, y: r.maxY - 70, width: r.width, height: 70)
        ctx.saveGState()
        body.addClip()
        NSColor(white: 0.92, alpha: alpha).setFill()
        bar.fill()
        ctx.restoreGState()
        let dots: [NSColor] = [.systemRed, .systemYellow, .systemGreen]
        for (i, c) in dots.enumerated() {
            c.withAlphaComponent(alpha).setFill()
            NSBezierPath(ovalIn: NSRect(x: r.minX + 34 + CGFloat(i) * 44, y: r.maxY - 50, width: 30, height: 30)).fill()
        }
    }
    window(NSRect(x: 200, y: 250, width: 480, height: 360), alpha: 0.35)

    // Fenêtre épinglée au premier plan.
    ctx.saveGState()
    let s2 = NSShadow()
    s2.shadowColor = NSColor.black.withAlphaComponent(0.3)
    s2.shadowBlurRadius = 30
    s2.shadowOffset = NSSize(width: 0, height: -14)
    s2.set()
    window(NSRect(x: 320, y: 190, width: 500, height: 380), alpha: 1)
    ctx.restoreGState()
    // Lignes de contenu.
    NSColor(white: 0.82, alpha: 1).setFill()
    for (i, w) in [360.0, 300, 330].enumerated() {
        NSBezierPath(roundedRect: NSRect(x: 370, y: 420 - CGFloat(i) * 60, width: w, height: 28), xRadius: 14, yRadius: 14).fill()
    }
    ctx.restoreGState()

    // Punaise.
    let cfg = NSImage.SymbolConfiguration(pointSize: 300, weight: .bold)
        .applying(.init(paletteColors: [NSColor(srgbRed: 1, green: 0.27, blue: 0.23, alpha: 1)]))
    let pin = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil)!.withSymbolConfiguration(cfg)!
    ctx.saveGState()
    let s3 = NSShadow()
    s3.shadowColor = NSColor.black.withAlphaComponent(0.4)
    s3.shadowBlurRadius = 18
    s3.shadowOffset = NSSize(width: 6, height: -12)
    s3.set()
    ctx.translateBy(x: 700, y: 640)
    ctx.rotate(by: -0.45)
    let ps = pin.size
    pin.draw(in: NSRect(x: -ps.width / 2, y: -ps.height / 2, width: ps.width, height: ps.height))
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let fm = FileManager.default
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let png = render(size: CGFloat(base * scale)).representation(using: .png, properties: [:])!
        try! png.write(to: iconset.appendingPathComponent(name))
    }
}
try! fm.createDirectory(atPath: "Resources", withIntermediateDirectories: true)
try! render(size: 1024).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "Resources/AppIcon.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! p.run()
p.waitUntilExit()
print("OK → Resources/AppIcon.icns")
