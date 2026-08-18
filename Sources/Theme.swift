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

    /// Others / system audio / success.
    ///
    /// Both values are in the accent's *hue family*, which is what the rebrand
    /// missed. The forest/lime commit rewrote the neutrals and the accent and
    /// left this token alone, so the dark value stayed #53B57F — the green
    /// from the Linear palette, unchanged since the original restyle. At hue
    /// 157° against lime's 121° it is a cool, blue-leaning green sitting next
    /// to a warm yellow-green accent, and the two read as unrelated colours
    /// rather than one family. That is the "old colour" the transcript's
    /// speaker labels were showing.
    ///
    /// Moving to ~141° puts both on the same side of green. Measured, against
    /// the grounds each is actually drawn on:
    ///
    ///   light #2A8128 — 4.92:1 white, 4.65 inset, 4.60 sidebar; 0.167 OKLab
    ///                   from the forest accent (was 4.91 / 4.64 / 4.60 at
    ///                   0.151, so contrast holds and separation improves)
    ///   dark  #58B24C — 6.60:1 on `surface`; 0.237 from the lime accent
    ///                   (was 6.93 at 0.236 — well clear of AA either way)
    ///
    /// The squeeze the light value has always been under is unchanged: every
    /// green dark enough to clear AA lands ~0.15–0.17 OKLab from an accent
    /// that is itself green, in normal vision and under both dichromacies.
    /// Disambiguation still leans on the speaker's name, which is always drawn
    /// beside the colour.
    static let green = dynamic(light: 0x2A8128, dark: 0x58B24C)
    static let red = dynamic(light: 0xDC3E42, dark: 0xEB5757)
    static let amber = dynamic(light: 0xBF7A18, dark: 0xE2A336)

    /// Chip label text — a fixed neutral, deliberately NOT a semantic label
    /// color: inside a selected, accent-filled sidebar row macOS flips semantic
    /// labels to white, which then vanishes against the chip's own light
    /// surface. A fixed gray stays legible on the chip in every row state.
    static let chipText = dynamic(light: 0x565A63, dark: 0x9DA1AA)

    /// The categorical set: one colour per *category*, where the categories
    /// have no order and no meaning beyond "not each other" — tag chips, and
    /// the far-side voices in a transcript.
    ///
    /// Brand restraint is the wrong instinct here and this is the one place it
    /// is. A tag dot and a speaker label are data encodings: their whole job is
    /// to be told apart, and six shades of one hue cannot do that. What the
    /// brand gets instead is a set that looks *designed* — generated in OKLCH
    /// at a single lightness and chroma per appearance, hues 60° apart, and
    /// anchored on `green` so the first member is the brand's own colour and
    /// every sibling is its equal in weight. Nothing here shouts over anything
    /// else, which is what the old set did wrong.
    ///
    /// The old set was inherited, not chosen: its first two entries were
    /// #5E6AD2 and #2F9E68 — the Linear accent and the Linear green, still
    /// shipping as tag dots long after the rebrand replaced both.
    ///
    /// Every entry clears AA on the grounds it is drawn on (light: 4.96–5.66
    /// on white, 4.68–5.35 on `inset`; dark: 5.75–6.61 on `surface`) and sits
    /// 0.15–0.40 OKLab from the accent, so no category is ever mistaken for a
    /// selected or accented control. Chroma is reduced per hue only where sRGB
    /// cannot hold it — teal and ochre — which is why those two are duller.
    static let categoricalPalette: [Color] = [
        green,                                     // 141° — the brand green
        dynamic(light: 0x027C82, dark: 0x04AFB7),  // 201° teal
        dynamic(light: 0x3768C2, dark: 0x5D97FE),  // 261° blue
        dynamic(light: 0x924AA0, dark: 0xC774D7),  // 321° magenta
        dynamic(light: 0xB33F45, dark: 0xEE696D),  // 21° red
        dynamic(light: 0x8D6400, dark: 0xC68F00),  // 81° ochre
    ]

    /// Dot colors for tag chips, assigned deterministically per tag.
    static let tagPalette: [Color] = categoricalPalette

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

    /// The colour for one far-side voice, by its position in the meeting's
    /// ordered voices. "You" is not in here — it is always `accent`.
    ///
    /// Index 0 is `green`, so a meeting with one far-side voice — which is
    /// most of them — looks exactly as it always has. Only a diarized
    /// transcript reaches past it, and only as far as it has voices.
    ///
    /// Before this existed the tint was a boolean, `isYou ? accent : green`,
    /// so every identified voice drew in the same colour: "Speaker 1" and
    /// "Speaker 2" were both green and the colour distinguished nothing, in
    /// the one feature sold as "who said what, every voice named".
    static func speakerColor(voiceIndex: Int) -> Color {
        categoricalPalette[max(0, voiceIndex) % categoricalPalette.count]
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
