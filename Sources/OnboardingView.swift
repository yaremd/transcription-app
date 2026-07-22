import SwiftUI

/// First-run welcome shown once. Sets expectations (private/on-device) and
/// primes the user for the Microphone + Screen Recording permission prompts.
struct OnboardingView: View {
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("Welcome to LocalScribe")
                .font(.title).bold()
            Text("A private meeting notepad. Recording, transcription, and notes all happen on your Mac — nothing leaves it unless you turn that on yourself.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 12) {
                row("mic.fill", "You'll be asked for Microphone and Screen Recording access — that's how it hears both you and the call, with no bot in the meeting.")
                row("square.and.pencil", "Jot rough notes while you talk; Generate Notes expands them using the transcript.")
                row("lock.fill", "Everything is saved locally. Add names and jargon in Settings (⌘,) so they transcribe correctly.")
            }
            .padding(.vertical, 6)

            Button("Get Started") { onDone() }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
        }
        .padding(32)
        .frame(width: 460)
    }

    private func row(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).frame(width: 22).foregroundStyle(.tint)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}
