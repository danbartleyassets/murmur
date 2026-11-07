import AppKit

// Builds a conventional .icns fallback from an Icon Composer PNG rendition.
// The canonical, future-facing source remains assets/MurmurAppIcon.icon.
//
// Usage:
//   swiftc -framework AppKit scripts/make-icon.swift -o /tmp/make-icon
//   /tmp/make-icon source.png output.iconset output.icns

guard CommandLine.arguments.count == 4 else {
    fatalError("usage: make-icon source.png output.iconset output.icns")
}

let sourcePath = CommandLine.arguments[1]
let outputDirectory = CommandLine.arguments[2]
let icnsPath = CommandLine.arguments[3]

guard let source = NSImage(contentsOfFile: sourcePath) else {
    fatalError("could not read \(sourcePath)")
}

try FileManager.default.createDirectory(
    atPath: outputDirectory,
    withIntermediateDirectories: true
)

func render(_ pixels: Int) -> Data {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    source.draw(
        in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
        from: NSRect(origin: .zero, size: source.size),
        operation: .copy,
        fraction: 1
    )
    NSGraphicsContext.restoreGraphicsState()

    return bitmap.representation(using: .png, properties: [:])!
}

let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16),
    ("icon_16x16@2x", 32),
    ("icon_32x32", 32),
    ("icon_32x32@2x", 64),
    ("icon_128x128", 128),
    ("icon_128x128@2x", 256),
    ("icon_256x256", 256),
    ("icon_256x256@2x", 512),
    ("icon_512x512", 512),
    ("icon_512x512@2x", 1024),
]

for size in sizes {
    try render(size.pixels).write(
        to: URL(fileURLWithPath: "\(outputDirectory)/\(size.name).png")
    )
}

let chunks: [(type: String, file: String)] = [
    ("ic04", "icon_16x16.png"),
    ("ic05", "icon_32x32.png"),
    ("ic11", "icon_16x16@2x.png"),
    ("ic12", "icon_32x32@2x.png"),
    ("ic07", "icon_128x128.png"),
    ("ic08", "icon_256x256.png"),
    ("ic13", "icon_128x128@2x.png"),
    ("ic09", "icon_512x512.png"),
    ("ic14", "icon_256x256@2x.png"),
    ("ic10", "icon_512x512@2x.png"),
]

func appendUInt32(_ value: Int, to data: inout Data) {
    var bigEndian = UInt32(value).bigEndian
    withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
}

var body = Data()
for chunk in chunks {
    let png = try Data(
        contentsOf: URL(fileURLWithPath: "\(outputDirectory)/\(chunk.file)")
    )
    body.append(contentsOf: chunk.type.utf8)
    appendUInt32(png.count + 8, to: &body)
    body.append(png)
}

var icns = Data("icns".utf8)
appendUInt32(body.count + 8, to: &icns)
icns.append(body)
try icns.write(to: URL(fileURLWithPath: icnsPath))

print("Wrote \(outputDirectory) and \(icnsPath)")
