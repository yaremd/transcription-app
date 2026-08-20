import AppKit
import CoreGraphics
import CoreText

// Generates the background art for the install disk image.
//
//   swift Brand/gen-dmg-background.swift          # from the repo root
//
// Writes:
//   Brand/out/dmg/background.png      640x400, the 1x canvas
//   Brand/out/dmg/background@2x.png   1280x800
//   Brand/out/dmg/background.tiff     both, for Finder — this is what ships
//
// Finder wants ONE file and picks the representation itself, which is why the
// pair is welded into a multi-resolution TIFF at the end. Handing it the plain
// PNG ships a background that is visibly soft on every Mac sold since 2012.
//
// Two constraints shaped this layout, both found by building the thing and
// looking at it:
//
//  1. Finder draws icon labels in BLACK once a window has a background
//     picture — in Dark Mode too, where it would otherwise use white. A dark
//     background therefore ships black-on-forest labels nobody can read. The
//     field here is light on purpose and must stay light.
//
//  2. The picture is anchored to the top-left of the content area and the
//     window's bottom chrome eats into it. The path bar alone costs 28pt, and
//     it is a per-user Finder setting we cannot control. Everything below the
//     caption is therefore empty field, so a crop is invisible.
//
// The layout constants must match scripts/make-dmg.sh, which positions the two
// icons in this same coordinate space (origin top-left, 1x points).

// MARK: - Canvas

let W: CGFloat = 640
let H: CGFloat = 400

let ICON_ROW_Y: CGFloat = 214      // centre line of both icons
let APP_X: CGFloat = 168           // centre of the app icon
let APPS_X: CGFloat = 472          // centre of the /Applications drop target
let ARROW_X: CGFloat = (APP_X + APPS_X) / 2

// MARK: - Palette (docs/styles.css)

func srgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let FOREST = srgb(0x0A2A21)
let ACCENT = srgb(0x14513C)         // --accent, the app's own accent in light
let INK    = srgb(0x0E1512)
let MUTED  = srgb(0x4A544E)
let LIME_SOFT = srgb(0xEFFAD8)      // --lime-soft; full lime shouts at 13pt
let FIELD_TOP    = srgb(0xFCFCFA)
let FIELD_BOTTOM = srgb(0xEFF2EA)

// MARK: - Mark geometry (the 240 grid from gen-seal-mark.swift)

let GRID: CGFloat = 240
let DISC_R: CGFloat = 80
let EYE_R: CGFloat = 18, EYE_LX: CGFloat = 81, EYE_Y: CGFloat = 104

func nose() -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: 97, y: 141))
    p.addQuadCurve(to: CGPoint(x: 108, y: 131), control: CGPoint(x: 97, y: 131))
    p.addQuadCurve(to: CGPoint(x: 120, y: 138), control: CGPoint(x: 115, y: 131))
    p.addQuadCurve(to: CGPoint(x: 132, y: 131), control: CGPoint(x: 125, y: 131))
    p.addQuadCurve(to: CGPoint(x: 143, y: 141), control: CGPoint(x: 143, y: 131))
    p.addQuadCurve(to: CGPoint(x: 128, y: 160), control: CGPoint(x: 143, y: 152))
    p.addQuadCurve(to: CGPoint(x: 112, y: 160), control: CGPoint(x: 120, y: 164.5))
    p.addQuadCurve(to: CGPoint(x: 97, y: 141), control: CGPoint(x: 97, y: 152))
    return p
}

func whiskers() -> CGPath {
    let p = CGMutablePath()
    for (sx, sy, ex, ey, cx, cy) in [
        (CGFloat(88), CGFloat(150), CGFloat(52), CGFloat(166), CGFloat(70), CGFloat(152)),
        (CGFloat(90), CGFloat(163), CGFloat(56), CGFloat(182), CGFloat(72), CGFloat(167)),
    ] {
        p.move(to: CGPoint(x: sx, y: sy))
        p.addQuadCurve(to: CGPoint(x: ex, y: ey), control: CGPoint(x: cx, y: cy))
        p.move(to: CGPoint(x: GRID - sx, y: sy))
        p.addQuadCurve(to: CGPoint(x: GRID - ex, y: ey), control: CGPoint(x: GRID - cx, y: cy))
    }
    return p.copy(strokingWithWidth: 6, lineCap: .round, lineJoin: .round, miterLimit: 10)
}

/// The mark: a solid disc with the face punched clean through. Fill even-odd.
func mark() -> CGPath {
    let p = CGMutablePath()
    p.addEllipse(in: CGRect(x: 120 - DISC_R, y: 120 - DISC_R, width: DISC_R * 2, height: DISC_R * 2))
    for cx in [EYE_LX, GRID - EYE_LX] {
        p.addEllipse(in: CGRect(x: cx - EYE_R, y: EYE_Y - EYE_R, width: EYE_R * 2, height: EYE_R * 2))
    }
    p.addPath(nose())
    p.addPath(whiskers())
    return p
}

// MARK: - Text

func textPath(_ text: String, size: CGFloat, weight: NSFont.Weight,
              tracking: CGFloat) -> (path: CGPath, width: CGFloat) {
    let font = NSFont.systemFont(ofSize: size, weight: weight) as CTFont
    let chars = Array(text.utf16)
    var glyphs = [CGGlyph](repeating: 0, count: chars.count)
    guard CTFontGetGlyphsForCharacters(font, chars, &glyphs, chars.count) else {
        fatalError("missing glyphs for \(text)")
    }
    var advances = [CGSize](repeating: .zero, count: glyphs.count)
    CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, glyphs.count)
    let out = CGMutablePath()
    var x: CGFloat = 0
    for (i, glyph) in glyphs.enumerated() {
        if let gp = CTFontCreatePathForGlyph(font, glyph, nil) {
            out.addPath(gp, transform: CGAffineTransform(translationX: x, y: 0))
        }
        x += advances[i].width + tracking
    }
    return (out, max(0, x - tracking))
}

/// Draws text into an already y-flipped context, sitting on `baseline`.
@discardableResult
func draw(_ ctx: CGContext, _ text: String, x: CGFloat, baseline: CGFloat,
          size: CGFloat, weight: NSFont.Weight = .semibold,
          tracking: CGFloat = 0, color: NSColor) -> CGFloat {
    let (path, width) = textPath(text, size: size, weight: weight, tracking: tracking)
    var t = CGAffineTransform(translationX: x, y: baseline).scaledBy(x: 1, y: -1)
    guard let placed = path.copy(using: &t) else { fatalError("transform failed") }
    ctx.saveGState()
    ctx.addPath(placed)
    ctx.setFillColor(color.cgColor)
    ctx.fillPath()
    ctx.restoreGState()
    return width
}

func centred(_ ctx: CGContext, _ text: String, baseline: CGFloat, size: CGFloat,
             weight: NSFont.Weight, tracking: CGFloat, color: NSColor) {
    let width = textPath(text, size: size, weight: weight, tracking: tracking).width
    draw(ctx, text, x: (W - width) / 2, baseline: baseline,
         size: size, weight: weight, tracking: tracking, color: color)
}

// MARK: - The art

let SPACE = CGColorSpace(name: CGColorSpace.sRGB)!

func paint(_ ctx: CGContext) {
    // Field: a warm-green off-white, barely graded so the window has a top.
    let field = CGGradient(colorsSpace: SPACE,
                           colors: [FIELD_TOP.cgColor, FIELD_BOTTOM.cgColor] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(field, start: CGPoint(x: 0, y: 0),
                           end: CGPoint(x: 0, y: H), options: [])

    // A soft ellipse of light under the icon row. It does no work you would
    // name, but it stops the two icons floating on a flat sheet.
    let glow = CGGradient(colorsSpace: SPACE,
                          colors: [srgb(0xFFFFFF, 0.85).cgColor,
                                   srgb(0xFFFFFF, 0).cgColor] as CFArray,
                          locations: [0, 1])!
    ctx.saveGState()
    ctx.translateBy(x: ARROW_X, y: ICON_ROW_Y)
    ctx.scaleBy(x: 1, y: 0.42)
    ctx.drawRadialGradient(glow, startCenter: .zero, startRadius: 0,
                           endCenter: .zero, endRadius: 320, options: [])
    ctx.restoreGState()

    // Lockup: mark + wordmark, centred, sitting in the head of the window.
    let markSize: CGFloat = 32
    let gap: CGFloat = 12
    let wmSize: CGFloat = 27
    let wmTracking = -wmSize * 0.03
    let (_, wmWidth) = textPath("Seal", size: wmSize, weight: .bold, tracking: wmTracking)
    let wmBox = textPath("Seal", size: wmSize, weight: .bold, tracking: wmTracking).path.boundingBoxOfPath
    let lockW = markSize + gap + wmWidth
    let lockX = (W - lockW) / 2
    let markTop: CGFloat = 36

    ctx.saveGState()
    ctx.translateBy(x: lockX, y: markTop)
    ctx.scaleBy(x: markSize / (DISC_R * 2), y: markSize / (DISC_R * 2))
    ctx.translateBy(x: -40, y: -40)                   // the disc starts at 40 on the grid
    ctx.addPath(mark())
    ctx.setFillColor(FOREST.cgColor)
    ctx.fillPath(using: .evenOdd)
    ctx.restoreGState()

    // Centre the wordmark's own mass on the mark, the way the lockup does.
    draw(ctx, "Seal", x: lockX + markSize + gap,
         baseline: markTop + markSize / 2 + wmBox.midY,
         size: wmSize, weight: .bold, tracking: wmTracking, color: INK)

    // The promise, carrying the site's lime highlight so the window is
    // recognisably the same brand as the page they downloaded it from.
    let tagSize: CGFloat = 13.5
    let tagTrack: CGFloat = -0.15
    let tagBase: CGFloat = 99
    // The three runs are measured without their spaces and spaced by hand:
    // folding the space into a run puts it under the highlight, and the
    // neighbouring words end up touching the box.
    func tagWidth(_ t: String) -> CGFloat {
        textPath(t, size: tagSize, weight: .medium, tracking: tagTrack).width
    }
    let lead = "Meeting notes that", hi = "never leave", tail = "your Mac"
    let spaceW = tagWidth(" ")
    let hiPad: CGFloat = 5
    let hiBox = textPath(hi, size: tagSize, weight: .medium,
                         tracking: tagTrack).path.boundingBoxOfPath
    let boxW = tagWidth(hi) + hiPad * 2
    let total = tagWidth(lead) + spaceW + boxW + spaceW + tagWidth(tail)
    let tx = (W - total) / 2
    let boxX = tx + tagWidth(lead) + spaceW

    ctx.saveGState()
    ctx.setFillColor(LIME_SOFT.cgColor)
    ctx.addPath(CGPath(roundedRect: CGRect(x: boxX, y: tagBase - hiBox.maxY - hiPad * 0.7,
                                           width: boxW, height: hiBox.height + hiPad * 1.4),
                       cornerWidth: 4, cornerHeight: 4, transform: nil))
    ctx.fillPath()
    ctx.restoreGState()

    draw(ctx, lead, x: tx, baseline: tagBase, size: tagSize,
         weight: .medium, tracking: tagTrack, color: MUTED)
    draw(ctx, hi, x: boxX + hiPad, baseline: tagBase, size: tagSize,
         weight: .semibold, tracking: tagTrack, color: FOREST)
    draw(ctx, tail, x: boxX + boxW + spaceW, baseline: tagBase, size: tagSize,
         weight: .medium, tracking: tagTrack, color: MUTED)

    // The arrow. Filled and stroked with the same colour and a round join, so
    // the tip and shoulders come out rounded instead of needle-sharp.
    let span: CGFloat = 100
    let headW: CGFloat = 31
    let headH: CGFloat = 34
    let shaftH: CGFloat = 9
    let x0 = ARROW_X - span / 2
    let x1 = ARROW_X + span / 2
    ctx.saveGState()
    ctx.setFillColor(ACCENT.cgColor)
    ctx.setStrokeColor(ACCENT.cgColor)
    ctx.setLineWidth(7)
    ctx.setLineJoin(.round)
    ctx.setLineCap(.round)
    let shaft = CGPath(roundedRect: CGRect(x: x0, y: ICON_ROW_Y - shaftH / 2,
                                           width: span - headW + 6, height: shaftH),
                       cornerWidth: shaftH / 2, cornerHeight: shaftH / 2, transform: nil)
    ctx.addPath(shaft)
    ctx.fillPath()
    let head = CGMutablePath()
    head.move(to: CGPoint(x: x1 - 3.5, y: ICON_ROW_Y))
    head.addLine(to: CGPoint(x: x1 - headW, y: ICON_ROW_Y - headH / 2 + 3))
    head.addLine(to: CGPoint(x: x1 - headW, y: ICON_ROW_Y + headH / 2 - 3))
    head.closeSubpath()
    ctx.addPath(head)
    ctx.drawPath(using: .fillStroke)
    ctx.restoreGState()

    // The instruction. Finder's own labels land at y≈284; this sits clear of
    // them, and clear of the bottom chrome that may crop the last 28pt.
    centred(ctx, "Drag Seal into your Applications folder", baseline: 344,
            size: 13, weight: .medium, tracking: -0.1, color: MUTED)
}

// MARK: - Output

func render(scale: CGFloat) -> Data {
    let pw = Int(W * scale), ph = Int(H * scale)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let ctx = NSGraphicsContext(bitmapImageRep: rep)?.cgContext else {
        fatalError("cannot allocate \(pw)x\(ph) bitmap")
    }
    ctx.translateBy(x: 0, y: CGFloat(ph))
    ctx.scaleBy(x: 1, y: -1)                          // SVG coordinates: y down
    ctx.scaleBy(x: scale, y: scale)
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    paint(ctx)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("png encode failed")
    }
    return png
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
func write(_ data: Data, _ path: String) {
    let url = root.appendingPathComponent(path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    do { try data.write(to: url) } catch { fatalError("write \(path): \(error)") }
    print("  \(path)")
}

write(render(scale: 1), "Brand/out/dmg/background.png")
write(render(scale: 2), "Brand/out/dmg/background@2x.png")

// Weld the pair into the multi-resolution TIFF Finder actually reads.
let tiff = Process()
tiff.executableURL = URL(fileURLWithPath: "/usr/bin/tiffutil")
tiff.arguments = ["-cathidpicheck",
                  root.appendingPathComponent("Brand/out/dmg/background.png").path,
                  root.appendingPathComponent("Brand/out/dmg/background@2x.png").path,
                  "-out", root.appendingPathComponent("Brand/out/dmg/background.tiff").path]
tiff.standardOutput = FileHandle.nullDevice
try tiff.run()
tiff.waitUntilExit()
guard tiff.terminationStatus == 0 else { fatalError("tiffutil failed") }
print("  Brand/out/dmg/background.tiff")
