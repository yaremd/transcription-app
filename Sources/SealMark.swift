import SwiftUI

/// The brand mark as a live shape: the struck-impression seal face, features
/// punched clean through the disc (fill it even-odd, in one colour).
///
/// The geometry is the same 240-unit grid `Brand/gen-seal-mark.swift` emits
/// every export from — disc r80 at (120,120), eyes r18 at y104, the dipped
/// two-lobe nose, four drooping whiskers stroked 6 wide. Keep the numbers here
/// in step with that generator; it stays the source of truth for the SVG, the
/// app icon, and the website, and this is the one place they're re-typed so
/// the mark can move (blink) instead of being a flat asset.
struct SealMark: Shape {
    /// 0 = eyes wide open, 1 = eyes shut.
    var blink: CGFloat = 0

    var animatableData: CGFloat {
        get { blink }
        set { blink = newValue }
    }

    func path(in rect: CGRect) -> Path {
        // Scaled by the disc (160 units), not the grid (240): every feature,
        // whiskers included, is drawn inside the disc, so the extra 40 a side
        // is padding the exports want and a laid-out view does not — left in,
        // it reads as a mark that mysteriously refuses to fill its own frame.
        let side = min(rect.width, rect.height)
        let scale = side / 160
        let transform = CGAffineTransform(translationX: rect.midX - 120 * scale,
                                          y: rect.midY - 120 * scale)
            .scaledBy(x: scale, y: scale)

        let path = CGMutablePath()
        path.addEllipse(in: CGRect(x: 40, y: 40, width: 160, height: 160), transform: transform)

        // A blink squashes the eye holes to slits rather than closing them
        // entirely — a hole that vanishes makes the face read as a blank disc
        // for those two frames, which looks like a glitch rather than a blink.
        let radiusY = max(2.0, 18 * (1 - blink))
        for centerX in [81.0, 159.0] {
            path.addEllipse(in: CGRect(x: centerX - 18, y: 104 - radiusY,
                                       width: 36, height: radiusY * 2),
                            transform: transform)
        }

        path.addPath(Self.nose, transform: transform)
        path.addPath(Self.whiskers, transform: transform)
        return Path(path)
    }

    /// Two lobes, a dipped bridge, a rounded point. The dip is what stops it
    /// reading as a cat — a plain triangle tested as unmistakably feline.
    private static let nose: CGPath = {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 104, y: 142))
        p.addQuadCurve(to: CGPoint(x: 112.5, y: 134), control: CGPoint(x: 104, y: 134))
        p.addQuadCurve(to: CGPoint(x: 120, y: 139), control: CGPoint(x: 117, y: 134))
        p.addQuadCurve(to: CGPoint(x: 127.5, y: 134), control: CGPoint(x: 123, y: 134))
        p.addQuadCurve(to: CGPoint(x: 136, y: 142), control: CGPoint(x: 136, y: 134))
        p.addQuadCurve(to: CGPoint(x: 125.5, y: 156.5), control: CGPoint(x: 136, y: 150.5))
        p.addQuadCurve(to: CGPoint(x: 114.5, y: 156.5), control: CGPoint(x: 120, y: 159.5))
        p.addQuadCurve(to: CGPoint(x: 104, y: 142), control: CGPoint(x: 104, y: 150.5))
        p.closeSubpath()
        return p
    }()

    /// Two a side, drooping down and out — whiskers that angle upward read cat.
    /// Expanded to outlines so the whole mark is one even-odd path.
    private static let whiskers: CGPath = {
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
        return strokes.copy(strokingWithWidth: 6, lineCap: .round,
                            lineJoin: .round, miterLimit: 10)
    }()
}

/// The mascot: the mark, sitting still, over a soft accent halo.
///
/// Nothing here loops. A mascot that moves the whole time you're on the screen
/// is something you end up watching instead of working — it earns attention it
/// hasn't asked for, and it wears out by the fifth launch. So the idle state is
/// genuinely still, and the life is in three moments: it settles into place
/// when the screen appears, it blinks now and then (rarely enough that catching
/// one feels like catching it), and it perks up and winks when the pointer
/// reaches it. All three stop under Reduce Motion, where it simply sits there.
struct SealMascot: View {
    var size: CGFloat = 96

    @State private var blink: CGFloat = 0
    @State private var settled = false
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        SealMark(blink: blink)
            .fill(Theme.accent, style: FillStyle(eoFill: true))
            .frame(width: size, height: size)
            .scaleEffect(hovering ? 1.05 : (settled ? 1 : 0.94))
            .opacity(settled ? 1 : 0)
            .background {
                RadialGradient(colors: [Theme.accent.opacity(hovering ? 0.19 : 0.13), .clear],
                               center: .center,
                               startRadius: size * 0.48,
                               endRadius: size * 0.92)
                    .frame(width: size * 2.0, height: size * 2.0)
                    .opacity(settled ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .animation(.spring(response: 0.55, dampingFraction: 0.72), value: settled)
            .animation(.spring(response: 0.3, dampingFraction: 0.62), value: hovering)
            .onHover { inside in
                guard !reduceMotion else { return }
                hovering = inside
                if inside { Task { await wink() } }
            }
            .task {
                guard !reduceMotion else {
                    settled = true
                    return
                }
                settled = true
                while !Task.isCancelled {
                    // Long enough apart that a blink reads as a moment, not as
                    // a screen element that flickers.
                    try? await Task.sleep(nanoseconds: UInt64(Double.random(in: 6...13) * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    await wink()
                    // Every so often, the second blink that makes it look like
                    // it's actually paying attention.
                    if Bool.random() {
                        try? await Task.sleep(nanoseconds: 170_000_000)
                        await wink()
                    }
                }
            }
            .accessibilityHidden(true)
    }

    @MainActor
    private func wink() async {
        withAnimation(.easeIn(duration: 0.07)) { blink = 1 }
        try? await Task.sleep(nanoseconds: 90_000_000)
        withAnimation(.easeOut(duration: 0.12)) { blink = 0 }
    }
}
