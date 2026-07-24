import SwiftUI

/// A small, always-visible signal of where data goes. Green dot when fully
/// local; amber dot when the opt-in cloud notes model is on (audio + the
/// transcript still stay on the Mac — only the notes text goes out).
/// The color lives in the dot; the text stays neutral. `compact` shows just
/// the dot + a two-word label (full sentence in the tooltip) for tight spots
/// like the recording control bar.
struct PrivacyBadge: View {
    let usingCloud: Bool
    var compact = false

    private var fullText: String {
        usingCloud
            ? "On-device transcription · notes use your cloud model"
            : "On-device · nothing leaves your Mac"
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(usingCloud ? Theme.amber : Theme.green)
                .frame(width: 6, height: 6)
            Text(compact ? (usingCloud ? "Cloud notes" : "On-device") : fullText)
                .font(Theme.metaMedium)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, compact ? 0 : 8)
        .padding(.vertical, compact ? 0 : 3.5)
        .background(compact ? Color.clear : Theme.surface,
                    in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5)
            .strokeBorder(compact ? Color.clear : Theme.border, lineWidth: 1))
        .help(fullText)
    }
}
