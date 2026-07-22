import SwiftUI

@main
struct LocalScribeApp: App {
    @StateObject private var store: MeetingStore
    @StateObject private var vocabulary: VocabularyStore
    @StateObject private var settings: AppSettings
    @StateObject private var monitor: AudioMonitor

    init() {
        let store = MeetingStore()
        let vocabulary = VocabularyStore()
        let settings = AppSettings()
        _store = StateObject(wrappedValue: store)
        _vocabulary = StateObject(wrappedValue: vocabulary)
        _settings = StateObject(wrappedValue: settings)
        _monitor = StateObject(wrappedValue: AudioMonitor(store: store, vocabulary: vocabulary, settings: settings))
    }

    var body: some Scene {
        WindowGroup {
            RootView(monitor: monitor)
                .environmentObject(store)
                .environmentObject(settings)
                .frame(minWidth: 860, minHeight: 620)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button(monitor.isRunning ? "Stop Recording" : "Start Recording") {
                    monitor.toggle()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra("LocalScribe", systemImage: monitor.isRunning ? "record.circle" : "mic") {
            MenuBarView(monitor: monitor)
        }

        Settings {
            SettingsView(vocabulary: vocabulary, settings: settings)
        }
    }
}
