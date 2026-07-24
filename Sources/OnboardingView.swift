import SwiftUI

/// First-run welcome shown once. Sets expectations (private/on-device) and
/// primes the user for the Microphone + Screen Recording permission prompts.
struct OnboardingView: View {
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 26))
                .foregroundStyle(Theme.accent)
                .frame(width: 56, height: 56)
                .surfacePanel(radius: 14)

            VStack(spacing: 6) {
                Text("Welcome to Seal")
                    .font(.system(size: 17, weight: .semibold))
                Text("A private meeting notepad. Recording, transcription, and notes all happen on your Mac — nothing leaves it unless you turn that on yourself.")
                    .font(Theme.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 10) {
                row("mic.fill", "You'll be asked for Microphone and Screen Recording access — that's how it hears both you and the call, with no bot in the meeting.")
                row("square.and.pencil", "Jot rough notes while you talk; Generate Notes expands them using the transcript.")
                row("lock.fill", "Everything is saved locally. Add names and jargon in Settings (⌘,) so they transcribe correctly.")
            }
            .padding(.vertical, 8)

            Button("Get Started") { onDone() }
                .buttonStyle(.linearPrimary)
                .keyboardShortcut(.defaultAction)
        }
        .padding(32)
        .frame(width: 460)
        .background(Theme.background)
    }

    private func row(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(Theme.accent)
                .frame(width: 26, height: 26)
                .surfacePanel(radius: 7)
            Text(text)
                .font(Theme.body)
                .lineSpacing(2)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
