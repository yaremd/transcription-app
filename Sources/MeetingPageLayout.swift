import SwiftUI

/// Which half of the companion panel is showing.
enum CompanionTab: String {
    case transcript, ask
}

/// The companion panel's remembered state — a preference, not per-session
/// state, shared by the live page and every saved meeting, so the choice
/// survives Stop, new recordings, and relaunches.
enum CompanionPrefs {
    static let visibleKey = "companionVisible"
    static let tabKey = "companionTab"
}

/// The meeting page's skeleton, shared by the live recording and every saved
/// meeting: one document column, and beside it the companion — the
/// transcript or Ask — as a full-height column the page reflows next to,
/// never an overlay that hides what it refers to. The column runs from the
/// window's top edge like the sidebar opposite it: its divider reaches up
/// through the toolbar, and its tabs are the toolbar's stretch above it (see
/// `CompanionToolbar`). Live and saved differ only in what they pour in, so
/// there is nothing to learn twice.
struct MeetingPageLayout<Document: View, Companion: View>: View {
    let companionVisible: Bool
    @ViewBuilder let document: () -> Document
    @ViewBuilder let companion: () -> Companion

    static var spring: Animation { .spring(response: 0.3, dampingFraction: 1.0) }

    /// The companion's width for a page this wide: 360 when there is room,
    /// narrowing to 280 so the document keeps at least ~350 of its own at the
    /// window's minimum size — a squeezed document column once wrapped the
    /// control bar's timer onto three lines.
    static func companionWidth(for pageWidth: CGFloat) -> CGFloat {
        min(360, max(280, pageWidth - 420))
    }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                document()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // The document's text stays out of the toolbar strip when it
                    // scrolls; the companion's divider is let through.
                    .clipped()
                if companionVisible {
                    companion()
                        .frame(width: Self.companionWidth(for: geo.size.width))
                        .frame(maxHeight: .infinity)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
    }
}

/// The document column: a scrolling page on a readable measure, centred when
/// there is room and flush left when there isn't.
struct DocumentColumn<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .frame(maxWidth: Theme.docMeasure, alignment: .leading)
            .padding(.horizontal, 36)
            .padding(.top, 24)
            .padding(.bottom, 96)
            .frame(maxWidth: .infinity)
        }
    }
}

/// The companion column: whichever tab is on, on the page's background,
/// with a hairline divider that runs up through the toolbar to the window's
/// top edge. Its tabs and close button are toolbar items (`CompanionToolbar`),
/// not a row inside it, so the column starts at the top.
struct CompanionPanel<Transcript: View, Ask: View>: View {
    let tab: CompanionTab
    @ViewBuilder let transcript: () -> Transcript
    @ViewBuilder let ask: () -> Ask

    var body: some View {
        Group {
            switch tab {
            case .transcript: transcript()
            case .ask: ask()
            }
        }
        .frame(maxHeight: .infinity)
        .background(Theme.background)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Theme.border)
                .frame(width: 1)
                .ignoresSafeArea(edges: .top)
        }
    }
}

/// The companion's tabs and close button, in the toolbar right above the
/// column: plain text tabs, the one that's on resting on a soft wash, and a
/// bare ✕ — no glass behind either, so the column's top reads as the column's
/// own header. The tabs span the column's width, so whatever the page puts
/// in the toolbar before them (Share) ends at the column's edge, over the
/// document it belongs to.
struct CompanionToolbar: ToolbarContent {
    let visible: Bool
    @Binding var tab: CompanionTab
    let width: CGFloat
    let close: () -> Void

    var body: some ToolbarContent {
        if visible {
            if #available(macOS 26.0, *) {
                ToolbarItem { tabs }
                    .sharedBackgroundVisibility(.hidden)
                ToolbarItem { closeButton }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem { tabs }
                ToolbarItem { closeButton }
            }
        }
    }

    private var tabs: some View {
        HStack(spacing: 4) {
            tabButton(.transcript, "Transcript")
            tabButton(.ask, "Ask")
        }
        // Off the divider by the column's own 12pt inset, so the tabs line
        // up with the transcript's header and the Ask feed below them.
        .padding(.leading, 12)
        // The column, less the close button and the margins, so Share ends
        // clear of the column's divider.
        .frame(width: max(160, width - 52), alignment: .leading)
    }

    private func tabButton(_ value: CompanionTab, _ label: String) -> some View {
        let on = tab == value
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { tab = value }
        } label: {
            Text(label)
                .font(Theme.bodyMedium)
                .foregroundStyle(on ? .primary : .secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(on ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private var closeButton: some View {
        Button(action: close) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                // Glyph to the trailing side, over the column's own trailing
                // icons (the transcript's copy), the target still 24pt.
                .frame(width: 24, height: 24, alignment: .trailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Hide the panel")
        .accessibilityLabel("Hide the panel")
    }
}

/// The 11pt label that heads a block of the document (action items, the
/// follow-up): quieter than the page, louder than its contents.
struct DocumentSectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        SectionLabel(text)
            .padding(.top, 28)
            .padding(.bottom, 10)
    }
}

extension View {
    /// The meeting page's toolbar: the page's own control (Share, on a saved
    /// meeting) and then the companion's tabs above its column. On macOS 26
    /// the toolbar has no title in it (see RootView), and with nothing to
    /// push against, items would sit at the leading edge, so a flexible
    /// spacer goes first.
    @ViewBuilder
    func meetingPageToolbar(share: AnyView?, companion: CompanionToolbar) -> some View {
        if #available(macOS 26.0, *) {
            toolbar {
                ToolbarSpacer(.flexible)
                if let share {
                    ToolbarItem { share }
                }
                companion
            }
        } else {
            toolbar {
                if let share {
                    ToolbarItem { share }
                }
                companion
            }
        }
    }

    /// Reports this view's width as it changes.
    func trackingWidth(_ width: Binding<CGFloat>) -> some View {
        background {
            GeometryReader { geo in
                Color.clear.onChange(of: geo.size.width, initial: true) { _, new in width.wrappedValue = new }
            }
        }
    }
}
