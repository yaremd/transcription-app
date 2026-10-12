import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// What Return does in the question box. Plain Return sends — a question is
/// one thought and the box is a chat, not a document — and Return with
/// Shift, Option, or Control breaks the line instead. Command-Return sends
/// too, for anyone who has that in their fingers.
enum ComposerKey {
    enum Action: Equatable { case send, newline }

    static func action(forReturnWith modifiers: NSEvent.ModifierFlags) -> Action {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.shift) || flags.contains(.option) || flags.contains(.control) { return .newline }
        return .send
    }
}

/// The question box: one line that grows with what is typed, up to eight
/// lines and then scrolls, with the files that go with the question listed
/// above the text. Files come in by the paperclip, by paste, or by drop.
struct AskComposer: View {
    @Binding var text: String
    @Binding var attachments: [AskAttachment]
    let placeholder: String
    let canSend: Bool
    /// Bumped by ⌘J so the box takes focus.
    var focusPulse = 0
    let onSend: () -> Void
    let onAttachFiles: ([URL]) -> Void
    let onAttachImage: (CGImage) -> Void
    let onAttachScreen: () -> Void
    /// The last question asked, for ↑ in an empty box.
    let lastQuestion: () -> String?

    @State private var height: CGFloat = 17
    @State private var focused = false
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !attachments.isEmpty {
                VStack(spacing: 4) {
                    ForEach(attachments) { attachment in
                        AttachmentRow(attachment: attachment) {
                            attachments.removeAll { $0.id == attachment.id }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)
            }
            GrowingTextView(text: $text, height: $height, focused: $focused, dragTargeted: $dropTargeted,
                            placeholder: placeholder, focusPulse: focusPulse, maxLines: 8,
                            onSend: onSend, onFiles: onAttachFiles, onImage: onAttachImage, onRecall: lastQuestion)
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 2)
            HStack(spacing: 6) {
                attachMenu
                Spacer(minLength: 0)
                if !text.isEmpty {
                    Text("⇧↩ new line")
                        .font(Theme.meta)
                        .foregroundStyle(.tertiary)
                        .transition(.opacity)
                }
                Button(action: onSend) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 19))
                        .foregroundStyle(canSend ? Theme.accent : Color.secondary.opacity(0.4))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .help("Send (Return)")
            }
            .padding(.leading, 6)
            .padding(.trailing, 8)
            .padding(.vertical, 4)
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(borderColor, lineWidth: 1))
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted, perform: drop)
        .animation(.easeOut(duration: 0.12), value: focused)
        .animation(.easeOut(duration: 0.12), value: dropTargeted)
        .animation(.easeOut(duration: 0.12), value: height)
        .animation(.easeOut(duration: 0.12), value: text.isEmpty)
    }

    private var borderColor: Color {
        if dropTargeted { return Theme.accent }
        return focused ? Theme.accent.opacity(0.45) : Theme.border
    }

    private var attachMenu: some View {
        Menu {
            Button("Attach a file…", action: chooseFiles)
            Button("What's on the screen", action: onAttachScreen)
        } label: {
            Image(systemName: "paperclip")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Put a file beside your question — or paste one, or drop it here. \(AskAttachmentReader.readableSummary)")
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = AskAttachmentReader.openableTypes
        panel.message = "Files to put beside your question. Their text is read on this Mac and goes nowhere else."
        panel.begin { response in
            guard response == .OK, !panel.urls.isEmpty else { return }
            onAttachFiles(panel.urls)
        }
    }

    /// Files dropped on the box outside the text itself; the text view takes
    /// its own drops (see `ComposerTextView`).
    private func drop(_ providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }
        for provider in fileProviders {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                else { url = item as? URL }
                guard let url else { return }
                DispatchQueue.main.async { onAttachFiles([url]) }
            }
        }
        return true
    }
}

/// One file beside the question: what it is, how much of it will go, and a
/// way to take it off. A file that couldn't be read says why, in place.
private struct AttachmentRow: View {
    let attachment: AskAttachment
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if attachment.isReading {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 14)
            } else {
                Image(systemName: attachment.failure == nil ? attachment.kind.symbol : "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(attachment.failure == nil ? Color.secondary : Theme.red)
                    .frame(width: 14)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.name)
                    .font(Theme.sub)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let failure = attachment.failure {
                    Text(failure)
                        .font(Theme.meta)
                        .foregroundStyle(Theme.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            Text(detail)
                .font(Theme.meta)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove")
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(Theme.inset, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border, lineWidth: 1))
    }

    private var detail: String {
        switch attachment.state {
        case .reading: return "Reading…"
        case .ready(let text): return Self.size(text.count)
        case .failed: return ""
        }
    }

    static func size(_ characters: Int) -> String {
        characters >= 1000 ? String(format: "%.1fk chars", Double(characters) / 1000) : "\(characters) chars"
    }
}

// MARK: - The text view

/// An AppKit text view that tells SwiftUI how tall it wants to be, and
/// turns Return, paste, and drops into the composer's own actions — the
/// things a SwiftUI text field cannot be asked to do.
struct GrowingTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    @Binding var focused: Bool
    @Binding var dragTargeted: Bool
    let placeholder: String
    var focusPulse: Int
    var maxLines: Int = 8
    let onSend: () -> Void
    let onFiles: ([URL]) -> Void
    let onImage: (CGImage) -> Void
    let onRecall: () -> String?

    static let font = NSFont.systemFont(ofSize: 13)

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        // TextKit 1 on purpose: its layout manager answers "how tall is the
        // text" directly, which is the one question this view exists to ask.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)

        let view = ComposerTextView(frame: .zero, textContainer: container)
        view.delegate = context.coordinator
        view.font = Self.font
        view.textColor = .labelColor
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.isContinuousSpellCheckingEnabled = true
        view.drawsBackground = false
        view.focusRingType = .none
        view.textContainerInset = .zero
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.placeholder = placeholder
        view.string = text
        context.coordinator.wire(view)

        let scroll = NSScrollView()
        scroll.documentView = view
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.focusRingType = .none
        scroll.verticalScrollElasticity = .none
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? ComposerTextView else { return }
        view.placeholder = placeholder
        if view.string != text {
            view.string = text
            context.coordinator.remeasure(view)
        }
        if context.coordinator.focusPulse != focusPulse {
            context.coordinator.focusPulse = focusPulse
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: GrowingTextView
        var focusPulse = 0
        private var lastWidth: CGFloat = 0
        private var observer: NSObjectProtocol?

        init(_ parent: GrowingTextView) { self.parent = parent }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        func wire(_ view: ComposerTextView) {
            view.onSend = { [weak self] in self?.parent.onSend() }
            view.onFiles = { [weak self] in self?.parent.onFiles($0) }
            view.onImage = { [weak self] in self?.parent.onImage($0) }
            view.onRecall = { [weak self] in self?.parent.onRecall() }
            view.onFocusChange = { [weak self] in self?.parent.focused = $0 }
            view.onDragTargeted = { [weak self] in self?.parent.dragTargeted = $0 }
            // The panel is 280–360 wide and the text rewraps with it.
            observer = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: view, queue: .main
            ) { [weak self, weak view] _ in
                guard let self, let view, view.bounds.width != self.lastWidth else { return }
                self.remeasure(view)
            }
            DispatchQueue.main.async { [weak self, weak view] in
                if let view { self?.remeasure(view) }
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? ComposerTextView else { return }
            parent.text = view.string
            remeasure(view)
        }

        /// One line at least, `maxLines` at most; past that the box scrolls.
        func remeasure(_ view: ComposerTextView) {
            guard let layout = view.layoutManager, let container = view.textContainer else { return }
            lastWidth = view.bounds.width
            layout.ensureLayout(for: container)
            let line = layout.defaultLineHeight(for: GrowingTextView.font)
            let used = layout.usedRect(for: container).height
            let wanted = ceil(min(max(used, line), line * CGFloat(parent.maxLines)))
            guard wanted != parent.height else { return }
            DispatchQueue.main.async { [weak self] in self?.parent.height = wanted }
        }
    }
}

/// The text view inside the composer. Return sends; ↑ in an empty box
/// brings the last question back; a pasted or dropped file becomes an
/// attachment instead of a path in the text.
final class ComposerTextView: NSTextView {
    var placeholder = "" { didSet { needsDisplay = true } }
    var onSend: () -> Void = {}
    var onFiles: ([URL]) -> Void = { _ in }
    var onImage: (CGImage) -> Void = { _ in }
    var onRecall: () -> String? = { nil }
    var onFocusChange: (Bool) -> Void = { _ in }
    var onDragTargeted: (Bool) -> Void = { _ in }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocusChange(false) }
        return accepted
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? GrowingTextView.font,
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        (placeholder as NSString).draw(at: textContainerOrigin, withAttributes: attributes)
    }

    override func doCommand(by selector: Selector) {
        if selector == #selector(insertNewline(_:)) {
            switch ComposerKey.action(forReturnWith: NSApp.currentEvent?.modifierFlags ?? []) {
            case .send: onSend()
            case .newline: insertText("\n", replacementRange: selectedRange())
            }
            return
        }
        if selector == #selector(moveUp(_:)), string.isEmpty, let last = onRecall(), !last.isEmpty {
            insertText(last, replacementRange: NSRange(location: 0, length: 0))
            return
        }
        super.doCommand(by: selector)
    }

    override func keyDown(with event: NSEvent) {
        // ⌘↩ sends as well. No key binding covers it, so it would only beep.
        if event.keyCode == 36, event.modifierFlags.contains(.command) {
            onSend()
            return
        }
        super.keyDown(with: event)
    }

    // A file on the pasteboard attaches; a picture with no text beside it
    // attaches; anything else lands as plain text.
    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        if let urls = Self.fileURLs(on: pasteboard) {
            onFiles(urls)
            return
        }
        if pasteboard.string(forType: .string) == nil,
           let image = NSImage(pasteboard: pasteboard)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            onImage(image)
            return
        }
        pasteAsPlainText(sender)
    }

    // Files dropped on the text attach; dragged text still lands as text.
    override func updateDragTypeRegistration() {
        super.updateDragTypeRegistration()
        registerForDraggedTypes(registeredDraggedTypes + [.fileURL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard Self.fileURLs(on: sender.draggingPasteboard) != nil else { return super.draggingEntered(sender) }
        onDragTargeted(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.fileURLs(on: sender.draggingPasteboard) != nil ? .copy : super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onDragTargeted(false)
        super.draggingExited(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onDragTargeted(false)
        if let urls = Self.fileURLs(on: sender.draggingPasteboard) {
            onFiles(urls)
            return true
        }
        return super.performDragOperation(sender)
    }

    private static func fileURLs(on pasteboard: NSPasteboard) -> [URL]? {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                          options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.isEmpty ? nil : urls
    }
}
