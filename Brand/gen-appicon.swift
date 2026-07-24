import AppKit

// Renders the macOS AppIcon set from a full-bleed square source image.
// The source is drawn into the Big Sur icon grid: art occupies 824/1024 of the
// canvas, clipped to an Apple-style squircle, margins transparent.
// Usage: swift gen-appicon.swift <source-image> <appiconset-dir>

let args = CommandLine.arguments
guard args.count == 3 else {
    print("usage: swift gen-appicon.swift <source-image> <appiconset-dir>")
    exit(1)
}
let srcURL = URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: args[2])
guard let image = NSImage(contentsOf: srcURL) else {
    print("cannot read \(args[1])")
    exit(1)
}

let sizes: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for (name, px) in sizes {
    let canvas = CGFloat(px)
    let art = canvas * 824.0 / 1024.0
    // Slightly deeper than Apple's 185.4/824 so the clip cuts inside the
    // source's own baked corner curve (JPEG corners are opaque).
    let radius = art * 0.235
    let origin = ((canvas - art) / 2).rounded(.down)
    let rect = NSRect(x: origin, y: origin, width: art, height: art)

    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { exit(1) }
    rep.size = NSSize(width: canvas, height: canvas)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).addClip()
    image.draw(in: rect, from: .zero, operation: .copy, fraction: 1.0)
    NSGraphicsContext.current?.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
    do {
        try png.write(to: outDir.appendingPathComponent("\(name).png"))
    } catch {
        print("write failed for \(name): \(error)")
        exit(1)
    }
}
print("Wrote \(sizes.count) icons to \(outDir.path)")
