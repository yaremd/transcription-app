import Foundation
import Combine

/// UI-facing status of the on-device notes model: ready, downloading (with
/// progress), unavailable, or failed. A single shared object the Settings screen
/// and the notes view observe; updates arrive from `MLXEngine`'s download
/// callbacks (whether the download was started explicitly or lazily on first use).
@MainActor
final class EmbeddedModelStatus: ObservableObject {
    static let shared = EmbeddedModelStatus()

    enum Phase: Equatable {
        case unsupported          // Intel Mac — MLX can't run here
        case idle                 // not downloaded yet (or unknown)
        case downloading(Double)  // 0…1
        case ready
        case failed(String)
    }

    @Published private(set) var phase: Phase

    private var attached = false

    private init() {
        phase = MLXEngine.isSupported ? .idle : .unsupported
    }

    /// Register for download progress and reflect whether the model is already
    /// loaded. Idempotent; call once at app startup. Does NOT start a download —
    /// it only observes, so a lazy first-use download still updates the UI.
    func attach() async {
        guard MLXEngine.isSupported else { return }
        if !attached {
            attached = true
            await MLXEngine.shared.setProgressObserver { fraction in
                Task { @MainActor in EmbeddedModelStatus.shared.apply(fraction: fraction) }
            }
        }
        if await MLXEngine.shared.isReady { phase = .ready }
    }

    /// Download / prepare the model now (the Settings "Download" button). Safe to
    /// call repeatedly; a second call while downloading is ignored.
    func downloadNow() {
        guard MLXEngine.isSupported else { return }
        if case .downloading = phase { return }
        phase = .downloading(0)
        Task {
            await attach()   // ensure progress callbacks flow
            do {
                try await MLXEngine.shared.prewarm()
                phase = .ready
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Start fetching the model in the background if it hasn't begun — used to
    /// kick the download off right after onboarding so notes are ready by the
    /// first meeting, instead of a cold blocking download on first use. No-op if
    /// the model is unsupported, already downloading, or already ready.
    func startIfNeeded() {
        guard MLXEngine.isSupported, case .idle = phase else { return }
        downloadNow()
    }

    private func apply(fraction: Double) {
        phase = fraction >= 1 ? .ready : .downloading(fraction)
    }
}
