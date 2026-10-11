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
/// never an overlay that hides what it refers to. Live and saved differ only
/// in what they pour in, so there is nothing to learn twice.
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

/// The companion column's chrome — two tabs, Transcript and Ask, and a close
/// button — around whichever tab is on.
struct CompanionPanel<Transcript: View, Ask: View>: View {
    @Binding var tab: CompanionTab
    let close: () -> Void
    @ViewBuilder let transcript: () -> Transcript
    @ViewBuilder let ask: () -> Ask

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                tabButton(.transcript, "Transcript")
                tabButton(.ask, "Ask")
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Hide the panel")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            ThemeDivider()

            switch tab {
            case .transcript: transcript()
            case .ask: ask()
            }
        }
        .frame(maxHeight: .infinity)
        .background(Theme.background)
        .overlay(alignment: .leading) {
            Rectangle().fill(Theme.border).frame(width: 1)
        }
    }

    private func tabButton(_ value: CompanionTab, _ label: String) -> some View {
        let on = tab == value
        return Button {
            withAnimation(.easeOut(duration: 0.15)) { tab = value }
        } label: {
            HStack(spacing: 5) {
                Text(label)
                    .font(Theme.bodyMedium)
                    .foregroundStyle(on ? .primary : .secondary)
                if value == .ask { ProBadge() }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(on ? Theme.hover : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
