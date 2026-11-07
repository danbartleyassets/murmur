import AppKit

// Murmur's app icon: four rounded bars in Bartley's colours on a light or dark tile.
// Follows the macOS icon grid (824 pt tile on a 1024 pt canvas, with shadow).
// Usage: swift scripts/make-icon.swift assets/AppIcon.iconset [light|dark] [output.icns]

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
let dark = CommandLine.arguments.count > 2 && CommandLine.arguments[2] == "dark"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func draw(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = CGFloat(px) / 1024
    ctx.scaleBy(x: s, y: s)

    // Tile with a soft drop shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: color(0x000000, 0.28))
    ctx.addPath(path); ctx.setFillColor(color(dark ? 0x1C1C1E : 0xFFFFFF)); ctx.fillPath()
    ctx.restoreGState()

    if !dark {
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        let bg = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0xFFFFFF), color(0xF7EBE5)] as CFArray,
                            locations: [0, 1])!
        ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
        ctx.restoreGState()
    }

    // Hairline edge so the tile holds its shape against either Dock appearance.
    ctx.addPath(CGPath(roundedRect: tile.insetBy(dx: 1, dy: 1), cornerWidth: 185, cornerHeight: 185, transform: nil))
    ctx.setStrokeColor(color(dark ? 0xFFFFFF : 0x000000, dark ? 0.12 : 0.06)); ctx.setLineWidth(2); ctx.strokePath()

    // Four bars, centred.
    let colors: [UInt32] = [0xD1643B, 0xB76E88, 0x9277BB, 0x4C8F85]
    let heights: [CGFloat] = [300, 520, 400, 230]
    let barWidth: CGFloat = 92, gap: CGFloat = 50
    let total = barWidth * 4 + gap * 3
    var x = 512 - total / 2
    for i in 0..<4 {
        let h = heights[i]
        let rect = CGRect(x: x, y: 512 - h / 2, width: barWidth, height: h)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
        ctx.setFillColor(color(colors[i])); ctx.fillPath()
        x += barWidth + gap
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]
for (name, px) in sizes {
    let data = draw(px).representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
}
print("Wrote \(sizes.count) icons to \(outDir)")

// iconutil is unreliable with generated iconsets on some Command Line Tools releases,
// so optionally write the straightforward PNG-backed ICNS container ourselves.
if CommandLine.arguments.count > 3 {
    let icnsPath = CommandLine.arguments[3]
    let chunks: [(String, String)] = [
        ("ic04", "icon_16x16.png"),
        ("ic05", "icon_32x32.png"),
        ("ic11", "icon_16x16@2x.png"),
        ("ic12", "icon_32x32@2x.png"),
        ("ic07", "icon_128x128.png"),
        ("ic08", "icon_256x256.png"),
        ("ic13", "icon_128x128@2x.png"),
        ("ic09", "icon_512x512.png"),
        ("ic14", "icon_256x256@2x.png"),
        ("ic10", "icon_512x512@2x.png")
    ]

    func appendUInt32(_ value: Int, to data: inout Data) {
        var bigEndian = UInt32(value).bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    var body = Data()
    for (type, file) in chunks {
        let png = try! Data(contentsOf: URL(fileURLWithPath: "\(outDir)/\(file)"))
        body.append(contentsOf: type.utf8)
        appendUInt32(png.count + 8, to: &body)
        body.append(png)
    }

    var icns = Data("icns".utf8)
    appendUInt32(body.count + 8, to: &icns)
    icns.append(body)
    try! icns.write(to: URL(fileURLWithPath: icnsPath))
    print("Wrote \(icnsPath)")
}
