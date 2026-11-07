import AppKit

// Creates the transparent foreground artwork imported by Apple Icon Composer.
// The rounded container, light/dark treatment, and Liquid Glass effects belong to
// the system-rendered .icon document rather than this source layer.

let outputPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "assets/icon-layers/MurmurBars.png"

let size = 1024
let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: size,
    pixelsHigh: size,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
)!

func color(_ hex: UInt32) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255,
        alpha: 1
    )
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
let context = NSGraphicsContext.current!.cgContext
context.clear(CGRect(x: 0, y: 0, width: size, height: size))

let colors: [UInt32] = [0xD1643B, 0xB76E88, 0x9277BB, 0x4C8F85]
let heights: [CGFloat] = [300, 520, 400, 230]
let barWidth: CGFloat = 92
let gap: CGFloat = 50
let totalWidth = barWidth * 4 + gap * 3
var x = CGFloat(size) / 2 - totalWidth / 2

for index in colors.indices {
    let height = heights[index]
    let rect = CGRect(
        x: x,
        y: CGFloat(size) / 2 - height / 2,
        width: barWidth,
        height: height
    )
    context.addPath(
        CGPath(
            roundedRect: rect,
            cornerWidth: barWidth / 2,
            cornerHeight: barWidth / 2,
            transform: nil
        )
    )
    context.setFillColor(color(colors[index]))
    context.fillPath()
    x += barWidth + gap
}

NSGraphicsContext.restoreGraphicsState()

let outputURL = URL(fileURLWithPath: outputPath)
try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
try bitmap.representation(using: .png, properties: [:])!.write(to: outputURL)
print("Wrote \(outputPath)")
