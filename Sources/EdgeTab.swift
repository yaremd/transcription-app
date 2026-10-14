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
    @Published var dragging = false
    /// The open face's width, measured, so the panel is sized to it before it
    /// opens and grows with the time's digits.
    @Published var openWidth: CGFloat = 230

    init(side: EdgeSide) { self.side = side }
}

/// How a drag on the tab is going.
enum EdgeTabDrag {
    case changed, ended
}

/// A borderless, non-activating panel: its buttons work without pulling Seal
/// in front of the call.
final class EdgeTabPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The edge tab while a recording runs in the background. Tucked against the
/// screen's edge it is the seal, peeking out with its ears up and the
/// recording dot beside its head (asleep while the recording is paused). Rest
/// the pointer on it and it slides out with the time and the quick actions —
/// pause, stop, snap, star — without leaving the call. The seal stays at the
/// edge as the tab's handle: click it to open Seal, or drag it anywhere and
/// let go — it settles on the nearer side.
struct EdgeTabView: View {
    @ObservedObject var model: EdgeTabModel
    @ObservedObject var monitor: AudioMonitor
    let openApp: () -> Void
    let hover: (Bool) -> Void
    let drag: (EdgeTabDrag) -> Void

    /// The press on the handle has travelled far enough to be a drag.
    @State private var moved = false

    static let faceHeight: CGFloat = 44
    /// The folded tab: the seal's head and the dot, the rest behind the edge.
    static let peekWidth: CGFloat = 44

    var body: some View {
        HStack(spacing: 0) {
            if model.side == .right { Spacer(minLength: 0) }
            face
            if model.side == .left { Spacer(minLength: 0) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            // The open face's width, off-screen (the seal's block stands in
            // for the seal), so the panel can be sized to it.
            HStack(spacing: 0) {
                Color.clear.frame(width: Self.peekWidth)
                timeLabel
                controls
            }
            .fixedSize()
            .hidden()
            .trackingWidth($model.openWidth)
        }
    }

    /// Rounded away from the screen's edge, square against it, so it reads as
    /// pulled out of the edge rather than floating near it.
    private var shape: UnevenRoundedRectangle {
        let r: CGFloat = model.expanded ? Self.faceHeight / 2 : 12
        return model.side == .right
            ? UnevenRoundedRectangle(topLeadingRadius: r, bottomLeadingRadius: r,
                                     bottomTrailingRadius: 0, topTrailingRadius: 0, style: .continuous)
            : UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 0,
                                     bottomTrailingRadius: r, topTrailingRadius: r, style: .continuous)
    }

    /// Laid out from the screen's edge outwards: the handle against it, then
    /// the quick actions.
    private var face: some View {
        HStack(spacing: 0) {
            if model.side == .left { handle }
            if model.expanded {
                controls
                    .transition(.opacity)
            }
            if model.side == .right { handle }
        }
        .frame(height: Self.faceHeight)
        // Open, it fills its panel so no clear margin sits over the app below.
        .frame(maxWidth: model.expanded ? .infinity : nil)
        .background(shape.fill(Theme.surface))
        // The seal is cut off by the screen's edge, as if behind it.
        .clipShape(shape)
        .overlay(shape.stroke(Theme.border, lineWidth: 1))
        .contentShape(shape)
        .onHover(perform: hover)
    }

    /// The seal and, open, the time beside it: a click opens Seal, a press
    /// that travels drags the tab.
    private var handle: some View {
        HStack(spacing: 0) {
            if model.side == .left { seal }
            if model.expanded {
                timeLabel
                    .transition(.opacity)
            }
            if model.side == .right { seal }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if !moved, hypot(value.translation.width, value.translation.height) > 3 { moved = true }
                    if moved { drag(.changed) }
                }
                .onEnded { _ in
                    if moved { drag(.ended) } else { openApp() }
                    moved = false
                }
        )
        .help(monitor.isPaused ? "Paused — click to open Seal, drag to move"
                               : "Recording — click to open Seal, drag to move")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(monitor.isPaused ? "Seal, recording paused" : "Seal, recording")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens Seal")
        .accessibilityAction { openApp() }
    }

    /// The seal peeking out of the screen's edge, facing into the screen:
    /// ears up while it listens, asleep while the recording is paused. Each
    /// render keeps its own proportions; the dot sits off its head.
    private var seal: some View {
        let paused = monitor.isPaused
        let width: CGFloat = paused ? 70 : 62
        let aspect: CGFloat = paused ? 260.0 / 122.0 : 300.0 / 175.0
        let towardEdge: CGFloat = model.side == .right ? 9 : -9
        return Image(paused ? "SealSleeping" : "SealListening")
            .resizable()
            .interpolation(.high)
            .frame(width: width, height: width / aspect)
            .scaleEffect(x: model.side == .left ? -1 : 1, y: 1)
            .offset(x: towardEdge)
            .padding(.bottom, 3)
            .frame(width: Self.peekWidth, height: Self.faceHeight,
                   alignment: model.side == .right ? .bottomLeading : .bottomTrailing)
            .clipped()
            .overlay(alignment: model.side == .right ? .topLeading : .topTrailing) {
                BreathingDot(levels: monitor.levels, active: !paused, size: 5)
                    .padding(3)
            }
            .accessibilityHidden(true)
    }

    private var timeLabel: some View {
        Group {
            if monitor.isPaused {
                Text("Paused")
                    .font(Theme.metaMedium)
                    .foregroundStyle(.secondary)
            } else if let start = monitor.recordingStart {
                RecordingTimerLabel(start: start)
            }
        }
        .padding(model.side == .right ? .leading : .trailing, 6)
    }

    /// From the handle outwards: pause, stop, snap, star.
    private var controls: some View {
        HStack(spacing: 4) {
            if model.side == .right {
                starButton
                snapButton
                stopButton
                pauseButton
                divider
            } else {
                divider
                pauseButton
                stopButton
                snapButton
                starButton
            }
        }
        .padding(model.side == .right ? .leading : .trailing, 8)
    }

    private var pauseButton: some View {
        icon(monitor.isPaused ? "play.fill" : "pause.fill",
             label: monitor.isPaused ? "Resume" : "Pause") { monitor.pauseResume() }
    }

    private var stopButton: some View {
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
    }

    private var starButton: some View {
        icon("star", label: "Star this moment") { monitor.addHighlight() }
    }

    private var snapButton: some View {
        icon("camera.viewfinder", label: "Snap the screen") { monitor.snapScreen() }
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
}
