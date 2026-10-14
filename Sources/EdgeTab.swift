import SwiftUI
import AppKit

/// Which side of the screen the edge tab lives on.
enum EdgeSide: String {
    case left, right
}

/// The edge tab's state, shared by the panel that holds it and the face that
/// draws it.
final class EdgeTabModel: ObservableObject {
    @Published var expanded = false
    @Published var side: EdgeSide
    /// The note box has the cursor: the tab stays open until it lets go.
    @Published var noteFocused = false
    @Published var dragging = false

    init(side: EdgeSide) { self.side = side }
}

/// How a drag on the tab is going.
enum EdgeTabDrag {
    case changed, ended
}

/// A borderless, non-activating panel that can still take typing, so the note
/// box works without pulling Seal in front of the call.
final class EdgeTabPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The edge tab while a recording runs in the background: tucked against the
/// screen's edge it is a sliver with the recording dot; under the pointer it
/// slides out with the time, pause, stop, star, snap and a box to jot a note
/// into the meeting without leaving the call. The dot and the time open Seal.
/// Drag it anywhere; let go and it settles on the nearer side.
struct EdgeTabView: View {
    @ObservedObject var model: EdgeTabModel
    @ObservedObject var monitor: AudioMonitor
    let openApp: () -> Void
    let hover: (Bool) -> Void
    let drag: (EdgeTabDrag) -> Void
    /// Escape in the note box: give the keyboard back.
    let endNote: () -> Void

    @State private var note = ""
    @State private var saved = false
    @FocusState private var noteFocus: Bool

    static let faceHeight: CGFloat = 44

    var body: some View {
        HStack(spacing: 0) {
            if model.side == .right { Spacer(minLength: 0) }
            face
            if model.side == .left { Spacer(minLength: 0) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: noteFocus) { _, focused in model.noteFocused = focused }
    }

    /// Rounded away from the screen's edge, square against it, so it reads as
    /// pulled out of the edge rather than floating near it.
    private var shape: UnevenRoundedRectangle {
        let r: CGFloat = model.expanded ? Self.faceHeight / 2 : 10
        return model.side == .right
            ? UnevenRoundedRectangle(topLeadingRadius: r, bottomLeadingRadius: r,
                                     bottomTrailingRadius: 0, topTrailingRadius: 0, style: .continuous)
            : UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0,
                                     bottomTrailingRadius: r, topTrailingRadius: r, style: .continuous)
    }

    private var face: some View {
        Group {
            if model.expanded {
                expandedContent
                    .transition(.opacity)
            } else {
                BreathingDot(levels: monitor.levels, active: !monitor.isPaused, size: 6)
                    .frame(width: 18)
                    .transition(.opacity)
            }
        }
        .frame(height: Self.faceHeight)
        // Open, it fills its panel so no clear margin sits over the app below.
        .frame(maxWidth: model.expanded ? .infinity : nil)
        .background(shape.fill(Theme.surface))
        .overlay(shape.stroke(Theme.border, lineWidth: 1))
        .contentShape(shape)
        .onHover(perform: hover)
        .gesture(
            DragGesture(minimumDistance: 3)
                .onChanged { _ in drag(.changed) }
                .onEnded { _ in drag(.ended) }
        )
        .help(model.expanded ? "" : "Seal is recording")
    }

    private var expandedContent: some View {
        HStack(spacing: 4) {
            Button(action: openApp) {
                HStack(spacing: 4) {
                    BreathingDot(levels: monitor.levels, active: !monitor.isPaused)
                    if monitor.isPaused {
                        Text("Paused")
                            .font(Theme.metaMedium)
                            .foregroundStyle(.secondary)
                    } else if let start = monitor.recordingStart {
                        RecordingTimerLabel(start: start)
                    }
                }
                .padding(.trailing, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open Seal")

            divider
            icon(monitor.isPaused ? "play.fill" : "pause.fill",
                 label: monitor.isPaused ? "Resume" : "Pause") { monitor.pauseResume() }
            Button { monitor.toggle() } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Theme.red))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Stop and save")
            .accessibilityLabel("Stop and save")
            icon("star", label: "Star this moment") { monitor.addHighlight() }
            icon("camera.viewfinder", label: "Snap the screen") { monitor.snapScreen() }
            divider
            noteBox
        }
        .padding(.leading, model.side == .right ? 12 : 10)
        .padding(.trailing, model.side == .right ? 10 : 12)
    }

    private var noteBox: some View {
        HStack(spacing: 4) {
            TextField("Jot a note", text: $note)
                .textFieldStyle(.plain)
                .font(Theme.sub)
                .focused($noteFocus)
                .onSubmit(save)
                .onExitCommand {
                    note = ""
                    noteFocus = false
                    endNote()
                }
            if saved {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.green)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 8)
        .frame(minWidth: 140, maxWidth: .infinity)
        .frame(height: 26)
        .background(Theme.inset, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border, lineWidth: 1))
        .help("Type a note and press Return: it lands in the meeting at this moment")
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.divider)
            .frame(width: 1, height: 16)
            .padding(.horizontal, 3)
    }

    private func icon(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    /// Return files the note at this moment and keeps the cursor for the next.
    private func save() {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        monitor.addNoteBlock(text)
        note = ""
        withAnimation(.easeOut(duration: 0.15)) { saved = true }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            withAnimation(.easeOut(duration: 0.3)) { saved = false }
        }
    }
}
