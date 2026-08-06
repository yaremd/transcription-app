import AppKit
import SwiftUI

/// "Report a problem" for one recording.
///
/// Shows the person the entire report before they send it — Seal's whole
/// promise is that nothing leaves the Mac without them, and a bug report is no
/// exception. The summary carries counts only; the log that quotes speech is a
/// separate switch, off by default.
struct ReportProblemView: View {
    let meeting: Meeting
    @EnvironmentObject private var store: MeetingStore
    @Environment(\.dismiss) private var dismiss

    @State private var description = ""
    @State private var attachLog = false
    @State private var diagnostics: ProblemReport.Diagnostics?
    @State private var loadedLog = false
    @State private var copied = false

    private let environment = ProblemReport.Environment.current()

    private var logURL: URL? {
        let url = store.diagnosticsURL(for: meeting.id)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private var report: String {
        ProblemReport.text(description: description, meeting: meeting,
                           diagnostics: diagnostics, environment: environment,
                           attachingLog: attachLog && logURL != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Report a problem")
                    .font(Theme.bodyMedium)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.linearQuietCompact)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            ThemeDivider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionLabel("What went wrong?")
                        TextEditor(text: $description)
                            .font(Theme.body)
                            .scrollContentBackground(.hidden)
                            .frame(height: 68)
                            .padding(6)
                            .insetPanel()
                        Text("A sentence is enough — \"the other side cut out around 20 minutes in\".")
                            .font(Theme.meta)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        SectionLabel("What gets sent")
                        ScrollView {
                            Text(report)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                        }
                        .frame(height: 210)
                        .insetPanel()
                    }

                    if let logURL {
                        Toggle(isOn: $attachLog) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Attach the full diagnostics log")
                                    .font(Theme.body)
                                Text("Much more useful for hard problems — but it quotes what was said in this meeting. \(byteSize(of: logURL)).")
                                    .font(Theme.meta)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .padding(16)
            }

            ThemeDivider()
            HStack(spacing: 8) {
                if logURL != nil {
                    Button("Show files") { revealFiles() }
                        .buttonStyle(.linearQuietCompact)
                        .help("Reveal this meeting's diagnostics and audio in Finder")
                }
                Spacer()
                Button(copied ? "Copied" : "Copy report") { copy() }
                    .buttonStyle(.linearQuietCompact)
                Button("Compose email…") { compose() }
                    .buttonStyle(.linearPrimaryCompact)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(width: 560, height: 560)
        .background(Theme.background)
        .task {
            guard !loadedLog else { return }
            loadedLog = true
            guard let logURL else { return }
            // Parsed off the main thread: a long meeting's log runs to megabytes.
            let url = logURL
            diagnostics = await Task.detached(priority: .userInitiated) { () -> ProblemReport.Diagnostics? in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return ProblemReport.diagnostics(fromLog: text)
            }.value
        }
    }

    // MARK: - Actions

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copied = false }
    }

    /// Opens a mail compose window with the report in it. `NSSharingService`
    /// is what lets an attachment ride along; a `mailto:` URL cannot carry one,
    /// so without a mail client configured we fall back to the body alone.
    private func compose() {
        var items: [Any] = [report]
        if attachLog, let logURL { items.append(logURL) }
        if let service = NSSharingService(named: .composeEmail), service.canPerform(withItems: items) {
            service.recipients = [Self.reportAddress]
            service.subject = "Seal problem report — \(environment.appVersion)"
            service.perform(withItems: items)
        } else {
            let subject = "Seal problem report — \(environment.appVersion)"
            var components = URLComponents(string: "mailto:\(Self.reportAddress)")
            components?.queryItems = [URLQueryItem(name: "subject", value: subject),
                                      URLQueryItem(name: "body", value: report)]
            if let url = components?.url { NSWorkspace.shared.open(url) }
            if attachLog { revealFiles() }   // so the log can be attached by hand
        }
        dismiss()
    }

    private func revealFiles() {
        let audio = store.existingAudioURLs(for: meeting.id)
        let urls = [logURL, audio.mic, audio.system].compactMap { $0 }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    private func byteSize(of url: URL) -> String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// Where reports go. Not a server — a mailbox, so a report is a message
    /// from a person and never a silent upload.
    static let reportAddress = "yaremchukdima@gmail.com"
}
