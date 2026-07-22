import SwiftUI
import AppKit

/// Contents of the menu-bar item — start/stop recording without bringing the
/// main window forward, plus a way back to it.
struct MenuBarView: View {
    @ObservedObject var monitor: AudioMonitor

    var body: some View {
        Button(monitor.isRunning ? "Stop Recording" : "Start Recording") {
            monitor.toggle()
        }

        if monitor.isRunning {
            Text(monitor.isPaused ? "Paused" : "Recording…")
        }

        Divider()

        Button("Open LocalScribe") {
            NSApp.activate()
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }

        Button("Quit LocalScribe") {
            NSApp.terminate(nil)
        }
    }
}
