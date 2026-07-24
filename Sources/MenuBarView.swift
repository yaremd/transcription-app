import SwiftUI
import AppKit

/// Contents of the menu-bar item — start/stop a meeting without bringing the
/// main window forward, see that it's alive (state + elapsed time), pause it,
/// and get back to the app. The elapsed time is stamped when the menu opens;
/// menus are glanced at, not watched.
struct MenuBarView: View {
    @ObservedObject var monitor: AudioMonitor

    var body: some View {
        if monitor.isRunning {
            Text(statusLine)

            Button("Stop & Save") {
                monitor.toggle()
            }

            Button(monitor.isPaused ? "Resume" : "Pause") {
                monitor.pauseResume()
            }
        } else {
            Button("New Meeting — starts listening") {
                monitor.toggle()
            }
        }

        Divider()

        Button("Open Seal") {
            NSApp.activate()
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }

        Button("Quit Seal") {
            NSApp.terminate(nil)
        }
    }

    private var statusLine: String {
        let state = monitor.isPaused ? "Paused" : "Recording"
        guard let start = monitor.recordingStart else { return state }
        return "\(state) · \(RecordingTimerLabel.format(Date().timeIntervalSince(start)))"
    }
}
