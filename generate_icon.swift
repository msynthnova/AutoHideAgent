import AppKit
import CoreGraphics
import Foundation

// Renders a clean, native Apple-style macOS squircle icon and menu bar template glyph
// using pure CoreGraphics vector geometry (zero AI artifacts).

func createAppIcon(size: Int) -> NSImage {
    let cgSize = CGSize(width: size, height: size)
    let image = NSImage(size: cgSize)
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }

    let s = CGFloat(size)
    let pad = s * 0.095
    let squircleRect = CGRect(x: pad, y: pad, width: s - pad * 2, height: s - pad * 2)
    let cornerRadius = squircleRect.width * 0.225

    // 1. Subtle outer drop shadow (standard macOS icon elevation)
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -s * 0.025),
        blur: s * 0.05,
        color: NSColor(calibratedWhite: 0, alpha: 0.38).cgColor
    )
    let squirclePath = NSBezierPath(roundedRect: squircleRect, xRadius: cornerRadius, yRadius: cornerRadius)
    NSColor(calibratedRed: 0.09, green: 0.11, blue: 0.15, alpha: 1.0).setFill()
    squirclePath.fill()
    ctx.restoreGState()

    // 2. Clip to squircle and draw anodized slate gradient background
    ctx.saveGState()
    squirclePath.addClip()

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bgColors = [
        NSColor(calibratedRed: 0.17, green: 0.20, blue: 0.26, alpha: 1.0).cgColor, // Top slate
        NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.13, alpha: 1.0).cgColor  // Bottom obsidian
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0.0, 1.0]) {
        ctx.drawLinearGradient(
            gradient,
            start: CGPoint(x: s * 0.5, y: squircleRect.maxY),
            end: CGPoint(x: s * 0.5, y: squircleRect.minY),
            options: []
        )
    }

    // Subtle inner top specular rim
    ctx.setStrokeColor(NSColor(calibratedWhite: 1.0, alpha: 0.14).cgColor)
    ctx.setLineWidth(s * 0.012)
    squirclePath.stroke()

    // 3. Draw Back Window (Receding / Dimmed / Dashed — representing "Hidden Background App")
    let winW = s * 0.44
    let winH = s * 0.34
    let backRect = CGRect(
        x: s * 0.50 - winW * 0.30,
        y: s * 0.50 - winH * 0.20,
        width: winW,
        height: winH
    )
    let winCorner = s * 0.042
    let backPath = NSBezierPath(roundedRect: backRect, xRadius: winCorner, yRadius: winCorner)

    NSColor(calibratedRed: 0.22, green: 0.27, blue: 0.36, alpha: 0.45).setFill()
    backPath.fill()

    ctx.saveGState()
    ctx.setStrokeColor(NSColor(calibratedRed: 0.48, green: 0.58, blue: 0.75, alpha: 0.55).cgColor)
    ctx.setLineWidth(s * 0.013)
    let dashPattern: [CGFloat] = [s * 0.028, s * 0.020]
    backPath.setLineDash(dashPattern, count: 2, phase: 0)
    backPath.stroke()
    ctx.restoreGState()

    // 4. Draw Front Window (Crisp Active macOS Window Card)
    let frontRect = CGRect(
        x: s * 0.50 - winW * 0.70,
        y: s * 0.50 - winH * 0.68,
        width: winW,
        height: winH
    )
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -s * 0.018),
        blur: s * 0.035,
        color: NSColor(calibratedWhite: 0, alpha: 0.45).cgColor
    )
    let frontPath = NSBezierPath(roundedRect: frontRect, xRadius: winCorner, yRadius: winCorner)
    NSColor(calibratedRed: 0.96, green: 0.97, blue: 0.99, alpha: 1.0).setFill()
    frontPath.fill()
    ctx.restoreGState()

    // Front window header bar divider
    let headerH = winH * 0.26
    let headerY = frontRect.maxY - headerH
    ctx.setStrokeColor(NSColor(calibratedWhite: 0.85, alpha: 1.0).cgColor)
    ctx.setLineWidth(s * 0.006)
    ctx.move(to: CGPoint(x: frontRect.minX, y: headerY))
    ctx.addLine(to: CGPoint(x: frontRect.maxX, y: headerY))
    ctx.strokePath()

    // Minimalist traffic light dots inside front window
    let dotR = s * 0.013
    let dotY = frontRect.maxY - headerH * 0.5
    let dotColors: [NSColor] = [
        NSColor(calibratedRed: 1.0, green: 0.37, blue: 0.34, alpha: 1.0),
        NSColor(calibratedRed: 1.0, green: 0.74, blue: 0.18, alpha: 1.0),
        NSColor(calibratedRed: 0.15, green: 0.78, blue: 0.25, alpha: 1.0)
    ]
    for (i, color) in dotColors.enumerated() {
        let dotX = frontRect.minX + s * 0.038 + CGFloat(i) * (dotR * 3.1)
        let dotRect = CGRect(x: dotX - dotR, y: dotY - dotR, width: dotR * 2, height: dotR * 2)
        color.setFill()
        NSBezierPath(ovalIn: dotRect).fill()
    }

    // 5. Precision Timer Badge on bottom-right corner of front window (accent blue)
    let badgeR = s * 0.105
    let badgeCenter = CGPoint(x: frontRect.maxX + s * 0.02, y: frontRect.minY + s * 0.02)
    let badgeRect = CGRect(
        x: badgeCenter.x - badgeR,
        y: badgeCenter.y - badgeR,
        width: badgeR * 2,
        height: badgeR * 2
    )

    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -s * 0.01),
        blur: s * 0.02,
        color: NSColor(calibratedWhite: 0, alpha: 0.35).cgColor
    )
    let badgePath = NSBezierPath(ovalIn: badgeRect)
    NSColor(calibratedRed: 0.04, green: 0.52, blue: 1.0, alpha: 1.0).setFill()
    badgePath.fill()
    ctx.restoreGState()

    // White ring + clock hand inside badge
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setLineWidth(s * 0.016)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    // Clock hands (12 o'clock to center to 4 o'clock)
    ctx.move(to: CGPoint(x: badgeCenter.x, y: badgeCenter.y + badgeR * 0.52))
    ctx.addLine(to: badgeCenter)
    ctx.addLine(to: CGPoint(x: badgeCenter.x + badgeR * 0.42, y: badgeCenter.y - badgeR * 0.22))
    ctx.strokePath()

    ctx.restoreGState()
    image.unlockFocus()
    return image
}

func savePNG(_ image: NSImage, to url: URL, pixelSize: Int) throws {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return }

    rep.size = NSSize(width: pixelSize, height: pixelSize)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(
        in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize),
        from: .zero,
        operation: .copy,
        fraction: 1.0
    )
    NSGraphicsContext.restoreGraphicsState()

    if let pngData = rep.representation(using: .png, properties: [:]) {
        try pngData.write(to: url)
    }
}

let iconsetDir = URL(fileURLWithPath: "/Users/flx/local/code/AutoHideAgent/build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconsetDir)
try FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for entry in sizes {
    let img = createAppIcon(size: entry.pixels)
    try savePNG(img, to: iconsetDir.appendingPathComponent(entry.name), pixelSize: entry.pixels)
}
print("Generated iconset successfully.")
