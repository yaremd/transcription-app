import SwiftUI

/// A small, always-visible signal of where data goes. Green dot when fully
/// local; amber dot when the opt-in cloud notes model is on (audio + the
/// transcript still stay on the Mac — only the notes text goes out).
/// The color lives in the dot; the text stays neutral.
struct PrivacyBadge: View {
    let usingCloud: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(usingCloud ? Theme.amber : Theme.green)
                .frame(width: 6, height: 6)
            Text(usingCloud
                 ? "On-device transcription · notes use your cloud model"
                 : "On-device · nothing leaves your Mac")
                .font(Theme.metaMedium)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.border, lineWidth: 1))
    }
}
