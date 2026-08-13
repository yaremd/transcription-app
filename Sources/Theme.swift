import SwiftUI
import AppKit

/// Seal's design language: quiet surfaces, hairline borders, compact
/// typography, and a single restrained forest/lime accent shared with the
/// website. Every color adapts to light and dark appearance on its own —
/// nothing here needs a colorScheme check at the call site.
enum Theme {

    // MARK: - Surfaces
    //
    // Neutrals carry a faint green bias so they sit under the forest accent
    // rather than fighting it — the same warm-neutral trick the site uses.

    /// App and detail-pane background.
    static let background = dynamic(light: 0xFCFDFB, dark: 0x0C0F0E)
    /// Sidebar, one small step apart from the content pane.
    static let sidebar = dynamic(light: 0xF6F8F4, dark: 0x0F1211)
    /// Raised surfaces: sheets, tiles, buttons at rest.
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x161A18)
    /// Sunken wells: the transcript area, editors, result blocks.
    static let inset = dynamic(light: 0xF7F9F6, dark: 0x0F1312)

    // MARK: - Lines

    /// Hairline drawn around panels, chips, and controls.
    static let border = dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.09, darkAlpha: 0.10)
    /// Quieter line for horizontal dividers.
    static let divider = dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.06, darkAlpha: 0.07)
    /// Empty track behind level meters.
    static let track = dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.07, darkAlpha: 0.09)
    /// Wash behind a hovered control.
    static let hover = dynamic(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.045, darkAlpha: 0.06)

    // MARK: - Color

    /// The one saturated color in the app, shared with the website: deep
    /// forest on light, lime on dark. It inverts rather than lightening
    /// because the middle of the green range collides with `green` below —
    /// a mid-green accent is indistinguishable from the "Others" speaker
    /// label under red-green color blindness. Staying at the extremes keeps
    /// the two apart on luminance alone.
    ///
    /// Anything filled with `accent` must draw its content in `onAccent`.
    /// Never `.white` — that vanishes on lime.
    static let accent = dynamic(light: 0x14513C, dark: 0xD3F36B)

    /// Foreground for content sitting on an `accent` fill. Flips with the
    /// appearance because the accent itself does.
    static let onAccent = dynamic(light: 0xFFFFFF, dark: 0x0E1512)

    /// Tint for surfaces macOS draws itself — List selection, `.tint(…)`,
    /// toggle tracks — where the system hard-codes a white foreground we
    /// can't override. Always dark enough to carry white, in both
    /// appearances, so a lime accent never strands a white toggle knob.
    ///
    /// **Keep `Support/Assets.xcassets/AccentColor.colorset` equal to these
    /// two values.** Info.plist names that asset as `NSAccentColorName`, and
    /// when the user's system accent is "multicolour" (the default) AppKit
    /// resolves sidebar List selection from the ASSET, not from any SwiftUI
    /// `.tint(…)` — so a stale asset survives every change made here. That is
    /// exactly what shipped in v0.22: Theme went forest, the asset stayed
    /// Linear indigo, and the sidebar selection alone stayed purple. Match
    /// `selection`, never `accent` — the asset also drives white-on-accent
    /// system chrome, and white on lime is unreadable.
    static let selection = dynamic(light: 0x14513C, dark: 0x1E5C46)

    /// Others / system audio / success. The light value was #2F9E68, which
    /// sat at 3.38:1 on white and 3.19:1 on `inset` — under AA on every ground
    /// it is actually drawn on, both as the speaker label and beneath the
    /// white checkmark in the meeting-detected prompt.
    ///
    /// Darkening it is squeezed from the other side now that `accent` is a
    /// green too: a sweep of the whole green band says every value dark enough
    /// to clear AA lands ~0.15 OKLab from the accent, in normal vision and
    /// under both dichromacies. There is no green that gets both, so this
    /// takes the best contrast available (4.91:1 white, 4.64 inset, 4.60
    /// sidebar) and leaves disambiguation to the speaker's name, which is
    /// always drawn beside the colour. Dark appearance has no such squeeze:
    /// #53B57F is 6.93:1 on `surface` and 0.21 from the lime accent.
    static let green = dynamic(light: 0x238050, dark: 0x53B57F)
    static let red = dynamic(light: 0xDC3E42, dark: 0xEB5757)
    static let amber = dynamic(light: 0xBF7A18, dark: 0xE2A336)

    /// Chip label text — a fixed neutral, deliberately NOT a semantic label
    /// color: inside a selected, accent-filled sidebar row macOS flips semantic
    /// labels to white, which then vanishes against the chip's own light
    /// surface. A fixed gray stays legible on the chip in every row state.
    static let chipText = dynamic(light: 0x565A63, dark: 0x9DA1AA)

    /// Dot colors for tag chips, assigned deterministically per tag.
    static let tagPalette: [Color] = [
        dynamic(light: 0x5E6AD2, dark: 0x6E79D6),  // indigo
        dynamic(light: 0x2F9E68, dark: 0x53B57F),  // green
        dynamic(light: 0xBF7A18, dark: 0xE2A336),  // amber
        dynamic(light: 0x9C5ACD, dark: 0xB07CD8),  // purple
        dynamic(light: 0x2E7DD1, dark: 0x58A6E8),  // blue
        dynamic(light: 0xC1417B, dark: 0xD9629B),  // pink
    ]

    // MARK: - Type scale

    /// 20pt document titles (a saved meeting's title).
    static let pageTitle = Font.system(size: 20, weight: .semibold)
    /// 15pt pane titles.
    static let title = Font.system(size: 15, weight: .semibold)
    /// 13pt standard UI text.
    static let body = Font.system(size: 13)
    static let bodyMedium = Font.system(size: 13, weight: .medium)
    /// 12pt supporting text.
    static let sub = Font.system(size: 12)
    /// 11pt metadata.
    static let meta = Font.system(size: 11)
    static let metaMedium = Font.system(size: 11, weight: .medium)

    // MARK: - Helpers

    /// Deterministic dot color for a tag name (stable across launches).
    static func tagColor(_ tag: String) -> Color {
        let hash = tag.lowercased().unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }
        return tagPalette[abs(hash) % tagPalette.count]
    }

    private static func dynamic(light: UInt32, dark: UInt32,
                                lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark ? nsColor(dark, darkAlpha) : nsColor(light, lightAlpha)
        })
    }

    private static func nsColor(_ hex: UInt32, _ alpha: CGFloat) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: alpha)
    }
}

// MARK: - Section label

/// The 11pt uppercase tracked label that heads each content section.
struct SectionLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.7)
            .foregroundStyle(.secondary)
    }
}

// MARK: - Divider

/// Hairline divider quieter than the system one.
struct ThemeDivider: View {
    var body: some View {
        Rectangle().fill(Theme.divider).frame(height: 1)
    }
}

// MARK: - Panels

extension View {
    /// A sunken, hairline-bordered well (transcript area, editors, results).
    func insetPanel(radius: CGFloat = 8) -> some View {
        background(Theme.inset, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Theme.border, lineWidth: 1))
    }

    /// A raised, hairline-bordered surface (tiles, sheets' inner panels).
    func surfacePanel(radius: CGFloat = 8) -> some View {
        background(Theme.surface, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Theme.border, lineWidth: 1))
    }
}

// MARK: - Chips

/// A small bordered chip with a colored dot: tags, statuses.
struct TagChip: View {
    let text: String
    var dotColor: Color? = nil
    var onRemove: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(dotColor ?? Theme.tagColor(text))
                .frame(width: 5, height: 5)
            Text(text)
                .font(Theme.meta)
                .foregroundStyle(Theme.chipText)
                .lineLimit(1)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.border, lineWidth: 1))
    }
}

// MARK: - Buttons

/// Linear-style buttons: 13pt medium text, 6pt radius, hairline border,
/// subtle hover wash. `primary` fills with the accent; `quiet` is a bordered
/// surface; `destructive` is quiet with red text.
struct LinearButtonStyle: ButtonStyle {
    enum Kind { case primary, quiet, destructive }
    var kind: Kind = .quiet
    /// Fill color for `primary` (defaults to the accent).
    var tint: Color = Theme.accent
    /// Foreground drawn on that fill. Defaults to `onAccent`, which flips to
    /// ink in dark appearance where the accent is lime; a caller supplying
    /// its own dark `tint:` passes `.white` instead.
    var onTint: Color = Theme.onAccent
    var compact = false
    /// Fully rounded (pill) ends instead of the 6pt radius.
    var capsule = false

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, kind: kind, tint: tint,
               onTint: onTint, compact: compact, capsule: capsule)
    }

    private struct Styled: View {
        let configuration: Configuration
        let kind: Kind
        let tint: Color
        let onTint: Color
        let compact: Bool
        let capsule: Bool
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        // A large radius is clamped to a true capsule by RoundedRectangle.
        private var radius: CGFloat { capsule ? 100 : 6 }
        private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: radius) }

        var body: some View {
            configuration.label
                .font(.system(size: compact ? 12 : 13, weight: .medium))
                .foregroundStyle(foreground)
                .padding(.horizontal, capsule ? (compact ? 12 : 16) : (compact ? 9 : 12))
                .padding(.vertical, compact ? 3.5 : 5.5)
                .background(background, in: shape)
                .overlay(shape.strokeBorder(kind == .primary ? Color.clear : Theme.border, lineWidth: 1))
                .opacity(isEnabled ? 1 : 0.45)
                .contentShape(shape)
                // A small dip on press so the button feels like it hears the
                // click — the single cheapest bit of "this is alive" there is.
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }

        private var foreground: Color {
            switch kind {
            case .primary: return onTint
            case .quiet: return .primary
            case .destructive: return Theme.red
            }
        }

        private var background: Color {
            if kind == .primary {
                if configuration.isPressed { return tint.opacity(0.8) }
                return hovering ? tint.opacity(0.9) : tint
            }
            if configuration.isPressed { return Theme.hover }
            return hovering ? Theme.hover : Theme.surface
        }
    }
}

extension ButtonStyle where Self == LinearButtonStyle {
    static var linearPrimary: LinearButtonStyle { .init(kind: .primary) }
    static var linearQuiet: LinearButtonStyle { .init(kind: .quiet) }
    static var linearDestructive: LinearButtonStyle { .init(kind: .destructive) }
    static var linearQuietCompact: LinearButtonStyle { .init(kind: .quiet, compact: true) }
    static var linearDestructiveCompact: LinearButtonStyle { .init(kind: .destructive, compact: true) }
    /// A caller-supplied tint is a saturated semantic color (red, green),
    /// dark enough for white in both appearances.
    static func linearPrimary(tint: Color) -> LinearButtonStyle {
        .init(kind: .primary, tint: tint, onTint: .white)
    }
    static var linearPrimaryCompact: LinearButtonStyle { .init(kind: .primary, compact: true) }
}

// MARK: - Text fields

/// Linear-style bordered input: plain field inside a hairline surface box.
struct LinearFieldModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(Theme.body)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border, lineWidth: 1))
    }
}

extension View {
    func linearField() -> some View { modifier(LinearFieldModifier()) }
}
