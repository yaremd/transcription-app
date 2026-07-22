import SwiftUI

/// A small, always-visible signal of where data goes. Green lock when fully
/// local; amber cloud when the opt-in cloud notes model is on (audio + the
/// transcript still stay on the Mac — only the notes text goes out).
struct PrivacyBadge: View {
    let usingCloud: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: usingCloud ? "cloud" : "lock.fill")
            Text(usingCloud
                 ? "On-device transcription · notes use your cloud model"
                 : "On-device · nothing leaves your Mac")
        }
        .font(.caption2)
        .foregroundStyle(usingCloud ? Color.orange : Color.green)
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background((usingCloud ? Color.orange : Color.green).opacity(0.12), in: Capsule())
    }
}
