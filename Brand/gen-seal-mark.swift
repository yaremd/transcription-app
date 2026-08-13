import AppKit
import CoreGraphics
import CoreText

// Generates every export of the Seal mark (Route B, "the struck impression")
// from one source of truth: the geometry constants below.
//
//   swift Brand/gen-seal-mark.swift
//
// Run from the repo root. Writes:
//   Brand/seal-mark-icon.svg             flat glyph, one path, features punched
//   Brand/seal-mark-icon-small.svg       small cut for 20 px and below
//   Brand/seal-lockup.svg                mark + outlined "Seal" wordmark
//   Support/Assets.xcassets/AppIcon.appiconset/  the app icon, per size
//   Brand/out/appicon-source-1024.png    full-bleed 1024 mark render, press kits
//   Brand/out/web/*.png                  favicon / touch icon / nav icon
//
// Everything is authored on a 240-unit grid in SVG coordinates (y increases
// downward). Contexts are flipped once at render time so the same numbers can
// be pasted straight into an SVG.

// MARK: - Geometry (240 grid)

let GRID: CGFloat = 240
let DISC_R: CGFloat = 80
let DISC_C = CGPoint(x: 120, y: 120)

// Primary cut
let EYE_R: CGFloat = 18, EYE_LX: CGFloat = 81, EYE_Y: CGFloat = 104
let WHISKER_WIDTH: CGFloat = 6

// Small cut (20 px and below): whiskers dropped, eyes and nose enlarged
let SM_EYE_R: CGFloat = 22, SM_EYE_LX: CGFloat = 77

// Brand colours
let FOREST = NSColor(srgbRed: 0x0A/255, green: 0x2A/255, blue: 0x21/255, alpha: 1)
let LIME   = NSColor(srgbRed: 0xD3/255, green: 0xF3/255, blue: 0x6B/255, alpha: 1)

/// Seal nose: two lobes, a dipped bridge, a rounded point. The dip is what
/// stops it reading as a cat — a plain triangle tested as unmistakably feline.
func nose(large: Bool) -> CGPath {
    let p = CGMutablePath()
    if large {
        p.move(to: CGPoint(x: 97, y: 141))
        p.addQuadCurve(to: CGPoint(x: 108, y: 131), control: CGPoint(x: 97, y: 131))
        p.addQuadCurve(to: CGPoint(x: 120, y: 138), control: CGPoint(x: 115, y: 131))
        p.addQuadCurve(to: CGPoint(x: 132, y: 131), control: CGPoint(x: 125, y: 131))
        p.addQuadCurve(to: CGPoint(x: 143, y: 141), control: CGPoint(x: 143, y: 131))
        p.addQuadCurve(to: CGPoint(x: 128, y: 160), control: CGPoint(x: 143, y: 152))
        p.addQuadCurve(to: CGPoint(x: 112, y: 160), control: CGPoint(x: 120, y: 164.5))
        p.addQuadCurve(to: CGPoint(x: 97, y: 141), control: CGPoint(x: 97, y: 152))
    } else {
        p.move(to: CGPoint(x: 104, y: 142))
        p.addQuadCurve(to: CGPoint(x: 112.5, y: 134), control: CGPoint(x: 104, y: 134))
        p.addQuadCurve(to: CGPoint(x: 120, y: 139), control: CGPoint(x: 117, y: 134))
        p.addQuadCurve(to: CGPoint(x: 127.5, y: 134), control: CGPoint(x: 123, y: 134))
        p.addQuadCurve(to: CGPoint(x: 136, y: 142), control: CGPoint(x: 136, y: 134))
        p.addQuadCurve(to: CGPoint(x: 125.5, y: 156.5), control: CGPoint(x: 136, y: 150.5))
        p.addQuadCurve(to: CGPoint(x: 114.5, y: 156.5), control: CGPoint(x: 120, y: 159.5))
        p.addQuadCurve(to: CGPoint(x: 104, y: 142), control: CGPoint(x: 104, y: 150.5))
    }
    p.closeSubpath()
    return p
}

/// Two whiskers a side, drooping down and out. Whiskers that angle upward read
/// cat; the droop is doing real work. Returned already expanded to outlines so
/// the mark can ship as one path with holes.
func whiskers() -> CGPath {
    let strokes = CGMutablePath()
    let runs: [(CGPoint, CGPoint, CGPoint)] = [
        (CGPoint(x: 95, y: 147), CGPoint(x: 76, y: 150), CGPoint(x: 58, y: 156)),
        (CGPoint(x: 97, y: 157), CGPoint(x: 83, y: 165), CGPoint(x: 72, y: 174)),
        (CGPoint(x: 145, y: 147), CGPoint(x: 164, y: 150), CGPoint(x: 182, y: 156)),
        (CGPoint(x: 143, y: 157), CGPoint(x: 157, y: 165), CGPoint(x: 168, y: 174)),
    ]
    for (start, control, end) in runs {
        strokes.move(to: start)
        strokes.addQuadCurve(to: end, control: control)
    }
    return strokes.copy(strokingWithWidth: WHISKER_WIDTH, lineCap: .round,
                        lineJoin: .round, miterLimit: 10)
}

/// The whole mark: disc plus every feature as a hole. Fill with `.evenOdd`.
func mark(small: Bool) -> CGPath {
    let p = CGMutablePath()
    p.addEllipse(in: CGRect(x: DISC_C.x - DISC_R, y: DISC_C.y - DISC_R,
                            width: DISC_R * 2, height: DISC_R * 2))
    let r = small ? SM_EYE_R : EYE_R
    let lx = small ? SM_EYE_LX : EYE_LX
    for cx in [lx, GRID - lx] {
        p.addEllipse(in: CGRect(x: cx - r, y: EYE_Y - r, width: r * 2, height: r * 2))
    }
    p.addPath(nose(large: small))
    if !small { p.addPath(whiskers()) }
    return p
}

// MARK: - SVG emission

func num(_ v: CGFloat) -> String {
    let r = (v * 100).rounded() / 100
    return r == r.rounded() ? String(Int(r)) : String(format: "%g", Double(r))
}

func svgPath(_ path: CGPath, scale: CGFloat = 1, dx: CGFloat = 0, dy: CGFloat = 0,
             flipY: Bool = false, height: CGFloat = 0) -> String {
    var out = ""
    func pt(_ p: CGPoint) -> String {
        let y = flipY ? height - (p.y * scale + dy) : p.y * scale + dy
        return "\(num(p.x * scale + dx)) \(num(y))"
    }
    path.applyWithBlock { element in
        let e = element.pointee
        switch e.type {
        case .moveToPoint:       out += "M\(pt(e.points[0]))"
        case .addLineToPoint:    out += "L\(pt(e.points[0]))"
        case .addQuadCurveToPoint: out += "Q\(pt(e.points[0])) \(pt(e.points[1]))"
        case .addCurveToPoint:   out += "C\(pt(e.points[0])) \(pt(e.points[1])) \(pt(e.points[2]))"
        case .closeSubpath:      out += "Z"
        @unknown default: break
        }
    }
    return out
}

// MARK: - Raster

/// Draws into a bitmap with the CTM flipped so callers can add paths in SVG
/// coordinates (y down, origin top-left).
func render(width: Int, height: Int, _ body: (CGContext) -> Void) -> Data {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let ctx = NSGraphicsContext(bitmapImageRep: rep)?.cgContext else {
        fatalError("cannot allocate \(width)x\(height) bitmap")
    }
    ctx.translateBy(x: 0, y: CGFloat(height))
    ctx.scaleBy(x: 1, y: -1)
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    body(ctx)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("png encode failed")
    }
    return png
}

func render(size: Int, _ body: (CGContext) -> Void) -> Data {
    render(width: size, height: size, body)
}

/// Forest ground plus the lime face, sized so the disc is `discPx` across.
func drawIcon(_ ctx: CGContext, canvas: CGFloat, discPx: CGFloat,
              small: Bool, ground: NSColor?, face: NSColor, cornerRadius: CGFloat?) {
    if let ground {
        ctx.saveGState()
        if let cornerRadius {
            let rect = CGRect(x: 0, y: 0, width: canvas, height: canvas)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: cornerRadius,
                               cornerHeight: cornerRadius, transform: nil))
            ctx.clip()
        }
        ctx.setFillColor(ground.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: canvas, height: canvas))
        ctx.restoreGState()
    }
    let s = discPx / (DISC_R * 2)
    let offset = (canvas - GRID * s) / 2
    ctx.saveGState()
    ctx.translateBy(x: offset, y: offset)
    ctx.scaleBy(x: s, y: s)
    ctx.addPath(mark(small: small))
    ctx.setFillColor(face.cgColor)
    ctx.fillPath(using: .evenOdd)
    ctx.restoreGState()
}

// MARK: - Wordmark

/// Text set in the system font and converted to outlines, so nothing depends on
/// SF Pro being installed wherever the file is opened. Returns the glyph path in
/// y-up coordinates with its baseline at 0, plus the total advance.
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
    // trailing tracking is not part of the mark's width
    return (out, max(0, x - tracking))
}

func wordmark(_ text: String, size: CGFloat, weight: NSFont.Weight,
              tracking: CGFloat) -> CGPath {
    textPath(text, size: size, weight: weight, tracking: tracking).path
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

/// The wax stamp from seal-stamp.svg, drawn on a 240 grid scaled to `grid`
/// points and centred on (cx, cy). Wax red is deliberately not Theme.red.
func drawStamp(_ ctx: CGContext, cx: CGFloat, cy: CGFloat, grid: CGFloat) {
    let wax     = NSColor(srgbRed: 0xC9/255, green: 0x50/255, blue: 0x3C/255, alpha: 1)
    let pressed = NSColor(srgbRed: 0xB0/255, green: 0x3E/255, blue: 0x2E/255, alpha: 1)
    let emboss  = NSColor(srgbRed: 0xF2/255, green: 0xE4/255, blue: 0xD8/255, alpha: 1)
    let scallops: [(CGFloat, CGFloat)] = [
        (176, 135), (161, 161), (135, 176), (105, 176), (79, 161), (64, 135),
        (64, 105), (79, 79), (105, 64), (135, 64), (161, 79), (176, 105),
    ]
    let s = grid / GRID
    ctx.saveGState()
    ctx.translateBy(x: cx - grid / 2, y: cy - grid / 2)
    ctx.scaleBy(x: s, y: s)

    ctx.setFillColor(wax.cgColor)
    for (x, y) in scallops {
        ctx.fillEllipse(in: CGRect(x: x - 10, y: y - 10, width: 20, height: 20))
    }
    ctx.fillEllipse(in: CGRect(x: 120 - 64.8, y: 120 - 64.8, width: 129.6, height: 129.6))
    ctx.setFillColor(pressed.cgColor)
    ctx.fillEllipse(in: CGRect(x: 120 - 52.8, y: 120 - 52.8, width: 105.6, height: 105.6))

    // the impression carries only the small cut — whiskers are far too fine to emboss
    ctx.saveGState()
    ctx.translateBy(x: 66, y: 66)
    ctx.scaleBy(x: 0.45, y: 0.45)
    ctx.addPath(mark(small: true))
    ctx.setFillColor(emboss.cgColor)
    ctx.fillPath(using: .evenOdd)
    ctx.restoreGState()
    ctx.restoreGState()
}

// MARK: - Write

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
func write(_ data: Data, _ path: String) {
    let url = root.appendingPathComponent(path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                             withIntermediateDirectories: true)
    do { try data.write(to: url) } catch { fatalError("write \(path): \(error)") }
    print("  \(path)")
}
func write(_ text: String, _ path: String) { write(Data(text.utf8), path) }

print("Seal mark — Route B")

// 0. The flat glyph. One path, fill-rule evenodd, every feature a real hole —
//    so a single `fill` recolours it and the menu bar can use it as a template.
for (small, name) in [(false, "seal-mark-icon.svg"), (true, "seal-mark-icon-small.svg")] {
    let note = small
        ? "Small cut for 20 px and below: whiskers dropped, eyes and nose enlarged.\n       Below that size a 6-unit stroke is a fifth of a pixel and only muddies the face."
        : "Icon-grade mark: earless, mouthless seal face. Features punched through.\n       Recolour with a single fill."
    write("""
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 240 240" role="img" aria-label="Seal">
      <!-- \(note)
           Generated by Brand/gen-seal-mark.swift; do not hand-edit. -->
      <path fill="currentColor" fill-rule="evenodd" d="\(svgPath(mark(small: small)))"/>
    </svg>

    """, "Brand/\(name)")
}

// 2. Full-bleed 1024 render. Nothing in the build consumes it — the app icon
//    is the mascot set below — but a square, unmasked, full-resolution mark is
//    what press kits, directories and store listings keep asking for.
//    The disc is sized against the Big Sur squircle (824/1024) so it still
//    looks right if anything ever crops it to one.
write(render(size: 1024) { ctx in
    drawIcon(ctx, canvas: 1024, discPx: 442, small: false,
             ground: FOREST, face: LIME, cornerRadius: nil)
}, "Brand/out/appicon-source-1024.png")

// 3. Web cuts. The favicon is seen at 16–32 px, so it uses the small cut.
write(render(size: 48) { ctx in
    drawIcon(ctx, canvas: 48, discPx: 34, small: true,
             ground: FOREST, face: LIME, cornerRadius: 10)
}, "Brand/out/web/favicon.png")
write(render(size: 180) { ctx in
    drawIcon(ctx, canvas: 180, discPx: 108, small: false,
             ground: FOREST, face: LIME, cornerRadius: nil)   // iOS applies its own mask
}, "Brand/out/web/apple-touch-icon.png")
write(render(size: 206) { ctx in
    drawIcon(ctx, canvas: 206, discPx: 111, small: false,
             ground: FOREST, face: LIME, cornerRadius: 46)
}, "Brand/out/web/app-icon.png")

// 3b. App icon set. Per-size art, which is the whole reason this is an
//     .appiconset and not the layered Support/Seal.icon it replaced: the
//     mascot carries the icon everywhere there's room for a face, and at 32 px
//     and below — Finder lists, Spotlight, the ⌘-Tab strip — it hands over to
//     the mark's small cut, because a soft-shaded pup at that size is a pale
//     smudge with no edges. Measured before choosing: at 16 px the render is
//     indistinguishable from a blank rounded square.
let MASCOT_HANDOVER = 32

/// The macOS Big Sur icon grid: the art is a rounded square of 824/1024 of the
/// canvas, centred, leaving the margin the system expects for shadows.
let BODY_RATIO: CGFloat = 824.0 / 1024.0
let BODY_RADIUS_RATIO: CGFloat = 0.2237

guard let mascotImage = NSImage(contentsOfFile: "Brand/mascot-icon.png"),
      let mascot = mascotImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("Brand/mascot-icon.png missing — it is the keyed close-up render")
}

func iconBody(_ canvas: CGFloat) -> (rect: CGRect, radius: CGFloat) {
    let side = (canvas * BODY_RATIO).rounded()
    return (CGRect(x: ((canvas - side) / 2).rounded(), y: ((canvas - side) / 2).rounded(),
                   width: side, height: side), side * BODY_RADIUS_RATIO)
}

/// Forest field with the mascot rising out of the bottom edge. The render is
/// cropped mid-body, so the cut is dissolved into the field rather than left as
/// a straight seam — and the fade is what keeps the body out of the rounded
/// corners, where it used to poke through as two white wedges.
func drawMascotIcon(_ ctx: CGContext, canvas: CGFloat) {
    let (body, radius) = iconBody(canvas)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.clip()
    ctx.setFillColor(FOREST.cgColor)
    ctx.fill(body)

    let pupW = body.width * 0.93
    let pupH = pupW * CGFloat(mascot.height) / CGFloat(mascot.width)
    let pupRect = CGRect(x: body.midX - pupW / 2, y: body.maxY - pupH, width: pupW, height: pupH)

    // Drawn through a scratch context so the fade can erase the bottom of the
    // mascot alone, not the field behind it.
    if let layer = CGContext(data: nil, width: Int(canvas), height: Int(canvas),
                             bitsPerComponent: 8, bytesPerRow: 0,
                             space: CGColorSpaceCreateDeviceRGB(),
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
        layer.draw(mascot, in: CGRect(x: pupRect.minX, y: canvas - pupRect.maxY,
                                      width: pupRect.width, height: pupRect.height))
        layer.setBlendMode(.destinationOut)
        let fade = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [NSColor.black.withAlphaComponent(1).cgColor,
                                       NSColor.black.withAlphaComponent(0).cgColor] as CFArray,
                              locations: [0, 1])!
        layer.drawLinearGradient(fade,
                                 start: CGPoint(x: 0, y: canvas - pupRect.maxY),
                                 end: CGPoint(x: 0, y: canvas - pupRect.maxY + pupRect.height * 0.16),
                                 options: [])
        if let faded = layer.makeImage() {
            ctx.saveGState()
            ctx.translateBy(x: 0, y: canvas)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(faded, in: CGRect(x: 0, y: 0, width: canvas, height: canvas))
            ctx.restoreGState()
        }
    }
    ctx.restoreGState()
}

let ICON_SIZES: [(px: Int, size: String, scale: String)] = [
    (16, "16x16", "1x"), (32, "16x16", "2x"),
    (32, "32x32", "1x"), (64, "32x32", "2x"),
    (128, "128x128", "1x"), (256, "128x128", "2x"),
    (256, "256x256", "1x"), (512, "256x256", "2x"),
    (512, "512x512", "1x"), (1024, "512x512", "2x"),
]

var iconEntries: [String] = []
var writtenIcons = Set<Int>()
for entry in ICON_SIZES {
    let px = entry.px
    if !writtenIcons.contains(px) {
        writtenIcons.insert(px)
        write(render(size: px) { ctx in
            if px > MASCOT_HANDOVER {
                drawMascotIcon(ctx, canvas: CGFloat(px))
            } else {
                let (body, radius) = iconBody(CGFloat(px))
                ctx.saveGState()
                ctx.translateBy(x: body.minX, y: body.minY)
                drawIcon(ctx, canvas: body.width, discPx: body.width * 0.71,
                         small: true, ground: FOREST, face: LIME, cornerRadius: radius)
                ctx.restoreGState()
            }
        }, "Support/Assets.xcassets/AppIcon.appiconset/icon_\(px).png")
    }
    iconEntries.append("""
        {
          "filename" : "icon_\(px).png",
          "idiom" : "mac",
          "scale" : "\(entry.scale)",
          "size" : "\(entry.size)"
        }
    """)
}
write("""
{
  "images" : [
\(iconEntries.joined(separator: ",\n"))
  ],
  "info" : {
    "author" : "gen-seal-mark.swift",
    "version" : 1
  }
}

""", "Support/Assets.xcassets/AppIcon.appiconset/Contents.json")

// 4. Lockup: mark at cap height, wordmark outlined, optically centred.
let capSize: CGFloat = 100
let wm = wordmark("Seal", size: capSize, weight: .semibold, tracking: -capSize * 0.03)
let wmBox = wm.boundingBoxOfPath
let markSize = wmBox.height * 1.62          // mark reads smaller than its box; 1.62 balances it
let gap = wmBox.height * 0.42
let baseline = markSize / 2 + wmBox.midY    // centre the wordmark's own mass on the mark
let totalW = markSize + gap + wmBox.width
let markScale = markSize / GRID
write("""
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 \(num(totalW)) \(num(markSize))" role="img" aria-label="Seal">
  <!-- Seal horizontal lockup. Wordmark is the system font converted to outlines.
       Generated by Brand/gen-seal-mark.swift; do not hand-edit. -->
  <g fill="currentColor">
    <path fill-rule="evenodd" d="\(svgPath(mark(small: false), scale: markScale))"/>
    <path d="\(svgPath(wm, scale: 1, dx: markSize + gap, dy: 0, flipY: true, height: baseline))"/>
  </g>
</svg>

""", "Brand/seal-lockup.svg")

// 5. Open Graph card, 1200x630. The page's own hero in the same order: lockup,
//    the headline with its lime highlight, the credentials line — and the pup
//    sitting on the right, where the page puts it. It takes over the bottom
//    right from the wax stamp, which still has a job on the page (the sealed
//    note in the flow diagram) and doesn't need this one too. The type is a
//    size down from the page's so the mascot has a column to sit in.
let INK    = NSColor(srgbRed: 0x0E/255, green: 0x15/255, blue: 0x12/255, alpha: 1)
let MUTED  = NSColor(srgbRed: 0x4A/255, green: 0x54/255, blue: 0x4E/255, alpha: 1)

guard let ogSealImage = NSImage(contentsOfFile: "Brand/mascot-sitting.png"),
      let ogSeal = ogSealImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("Brand/mascot-sitting.png missing — it is the keyed sitting render")
}

write(render(width: 1200, height: 630) { ctx in
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: 1200, height: 630))

    let margin: CGFloat = 58

    // lockup
    let lockMark: CGFloat = 44
    ctx.saveGState()
    ctx.translateBy(x: margin, y: 48)
    ctx.scaleBy(x: lockMark / (DISC_R * 2), y: lockMark / (DISC_R * 2))
    ctx.translateBy(x: -40, y: -40)                       // disc starts at 40 on the grid
    ctx.addPath(mark(small: false))                       // 44 px is well above the 24 px whisker floor
    ctx.setFillColor(FOREST.cgColor)
    ctx.fillPath(using: .evenOdd)
    ctx.restoreGState()
    draw(ctx, "Seal", x: margin + lockMark + 18, baseline: 48 + lockMark * 0.72,
         size: 31, weight: .bold, tracking: -0.9, color: INK)

    // hero
    let hero: CGFloat = 74
    let track = -hero * 0.032
    draw(ctx, "Meeting notes that", x: margin, baseline: 292,
         size: hero, weight: .bold, tracking: track, color: INK)

    let base2: CGFloat = 376
    let pad: CGFloat = 13
    let hiW = textPath("never leave", size: hero, weight: .bold, tracking: track).width
    ctx.setFillColor(LIME.cgColor)
    ctx.addPath(CGPath(roundedRect: CGRect(x: margin, y: base2 - 62,
                                           width: hiW + pad * 2, height: 77),
                       cornerWidth: 7, cornerHeight: 7, transform: nil))
    ctx.fillPath()
    draw(ctx, "never leave", x: margin + pad, baseline: base2,
         size: hero, weight: .bold, tracking: track, color: INK)
    draw(ctx, "your Mac", x: margin + hiW + pad * 2 + 16, baseline: base2,
         size: hero, weight: .bold, tracking: track, color: INK)

    // credentials
    let credSize: CGFloat = 27
    let lead = "100% on-device  ·  macOS  ·  "
    let leadW = draw(ctx, lead, x: margin, baseline: 452,
                     size: credSize, weight: .semibold, tracking: -0.3, color: MUTED)
    draw(ctx, "sealformac.com", x: margin + leadW, baseline: 452,
         size: credSize, weight: .bold, tracking: -0.3, color: FOREST)

    // The mascot, bottom-aligned with the credentials line so the card has one
    // baseline running through it. Drawn through a local flip because this
    // context is set up for SVG coordinates.
    let sealW: CGFloat = 330
    let sealH = sealW * CGFloat(ogSeal.height) / CGFloat(ogSeal.width)
    let sealRect = CGRect(x: 1200 - margin - sealW + 12, y: 492 - sealH, width: sealW, height: sealH)
    ctx.saveGState()
    ctx.translateBy(x: 0, y: 630)
    ctx.scaleBy(x: 1, y: -1)
    ctx.draw(ogSeal, in: CGRect(x: sealRect.minX, y: 630 - sealRect.maxY,
                                width: sealRect.width, height: sealRect.height))
    ctx.restoreGState()
}, "Brand/out/web/og.png")

print("done")
