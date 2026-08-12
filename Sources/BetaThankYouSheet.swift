import SwiftUI
import AppKit

/// A one-time note for installs that used Seal before the Free/Pro line
/// existed (YAR-101). The paywall reached the public beta quietly in v0.17;
/// this repairs that: what stays free (everything they rely on), what moved
/// to Pro, and their thank-you code — free Pro, because they tested the
/// rough builds. Shown once, never to licensed installs, never to fresh ones
/// (RootView decides eligibility).
struct BetaThankYouSheet: View {
    let dismiss: () -> Void

    @State private var copied = false

    static let code = "SEALBETA"
    /// The code's advertised end date — keep in sync with the Freemius coupon.
    static let validThrough = "November 10, 2026"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    Text("FOR EARLY SEAL USERS")
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.9)
                        .foregroundStyle(.secondary)
                }
                Text("You were here first. Thank you.")
                    .font(.system(size: 25, weight: .semibold))
                    .tracking(-0.4)
                Text("Recent updates drew the line between free Seal and Seal Pro. Nothing you rely on moved — recording, full-accuracy transcription, notes, folders, search, and export stay free forever, and your meetings are never locked.")
                    .font(Theme.body)
                    .lineSpacing(2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
            .background(
                LinearGradient(colors: [Theme.accent.opacity(0.07), .clear],
                               startPoint: .top, endPoint: .bottom)
            )

            ThemeDivider()

            VStack(alignment: .leading, spacing: 14) {
                Text("The assistant extras — speaker names, ask-the-meeting, follow-up drafts, action tracking, transcript polish — are now Seal Pro. Yours is free: you tested Seal when it was rough, and that counts.")
                    .font(Theme.body)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Text(Self.code)
                        .font(.system(size: 17, weight: .semibold, design: .monospaced))
                        .tracking(1.0)
                    Button {
                        copyToPasteboard(Self.code)
                        copied = true
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 1_400_000_000)
                            copied = false
                        }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11))
                            .foregroundStyle(copied ? Theme.green : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy the code")
                    Spacer()
                    Text("100% off at checkout · through \(Self.validThrough)")
                        .font(Theme.sub)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .insetPanel(radius: 8)

                HStack(spacing: 8) {
                    Button("Claim free Pro") { claim() }
                        .buttonStyle(.linearPrimary)
                        .keyboardShortcut(.defaultAction)
                    Button("Later") { dismiss() }
                        .buttonStyle(.linearQuiet)
                        .keyboardShortcut(.cancelAction)
                    Spacer()
                }

                Text("This note shows once — copy the code somewhere handy. Free Seal never expires either way.")
                    .font(Theme.meta)
                    .foregroundStyle(.tertiary)
            }
            .padding(24)
        }
        .frame(width: 480)
        .background(Theme.background)
    }

    /// Copies the code (belt) and opens checkout with it applied (suspenders),
    /// then lets the note retire.
    private func claim() {
        copyToPasteboard(Self.code)
        let base = SealStore.checkoutPro ?? Pricing.pricingURL
        let url = base.appending(queryItems: [URLQueryItem(name: "coupon", value: Self.code)])
        NSWorkspace.shared.open(url)
        dismiss()
    }
}
