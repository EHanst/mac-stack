#if SWIFT_PACKAGE
import StackCore
#endif
import Foundation
import Observation

/// Drives the first-run screen: shows what will happen, runs the downloads one after another
/// with a single combined progress bar, and can be cancelled and resumed. The installer and the
/// "finished" hook are injected so the behaviour is testable without a network or a model.
@MainActor
@Observable
public final class SetupModel {

    public typealias Install = @Sendable (
        ModelCatalogEntry, @escaping @Sendable (ModelInstaller.Progress) -> Void
    ) async throws -> Void

    public enum Phase: Equatable {
        case ready
        case installing
        case failed(String)
        case finished
    }

    public private(set) var plan: SetupPlan
    public let hardwareLine: String
    public private(set) var phase: Phase = .ready
    /// 0…1 across every model still to download; never goes backwards.
    public private(set) var fraction: Double = 0
    public private(set) var statusLine = ""

    private let install: Install
    private let finish: @MainActor () async -> Void
    private var task: Task<Void, Never>?

    public init(
        plan: SetupPlan, hardwareLine: String,
        install: @escaping Install,
        onFinished: @escaping @MainActor () async -> Void
    ) {
        self.plan = plan
        self.hardwareLine = hardwareLine
        self.install = install
        self.finish = onFinished
    }

    public var isInstalling: Bool { phase == .installing }

    /// "about 12,000 words", rounded so the number reads as an estimate.
    public var contextDescription: String? {
        guard let words = plan.approximateContextWords else { return nil }
        let rounded = max(1_000, (words / 1_000) * 1_000)
        return "about \(rounded.formatted()) words"
    }

    public func start() {
        guard plan.mode == .local, phase != .installing, plan.blocker == nil else { return }
        phase = .installing
        statusLine = "Starting…"
        let downloads = plan.downloads
        let expectedTotal = max(1, downloads.reduce(Int64(0)) { $0 + $1.approximateBytes })
        let install = self.install

        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                var completed: Int64 = 0
                for entry in downloads {
                    let base = completed
                    let name = entry.displayName
                    self.statusLine = "Downloading \(name)…"
                    try await install(entry) { progress in
                        Task { @MainActor in
                            self.apply(done: base + progress.bytesDone, total: expectedTotal, label: name)
                        }
                    }
                    completed += entry.approximateBytes
                    self.apply(done: completed, total: expectedTotal, label: name)
                }
                self.statusLine = "Finishing up…"
                await self.finish()
                self.fraction = 1
                self.phase = .finished
                self.statusLine = "Ready"
            } catch is CancellationError {
                self.phase = .ready
                self.statusLine = "Paused. Your progress is kept, so you can pick up where you left off."
            } catch {
                self.phase = .failed(error.localizedDescription)
                self.statusLine = ""
            }
        }
    }

    public func cancel() { task?.cancel() }

    /// Wait for the current install task (used by tests and by callers that need completion).
    public func waitUntilIdle() async { await task?.value }

    private func apply(done: Int64, total: Int64, label: String) {
        guard phase == .installing else { return }
        fraction = max(fraction, min(0.99, Double(done) / Double(total)))
        let doneGB = Double(min(done, total)) / 1_000_000_000
        let totalGB = Double(total) / 1_000_000_000
        statusLine = String(format: "Downloading %@ — %.1f of %.1f GB", label, doneGB, totalGB)
    }
}
