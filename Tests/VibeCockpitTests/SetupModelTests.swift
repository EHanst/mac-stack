import Testing
import Foundation
@testable import VibeCockpitCore
@testable import StackCore
@testable import StackMCP

private actor Calls {
    var installed: [String] = []
    var finished = 0
    var failuresLeft = 0
    func record(_ id: String) { installed.append(id) }
    func didFinish() { finished += 1 }
    func setFailures(_ n: Int) { failuresLeft = n }
    func shouldFail() -> Bool { if failuresLeft > 0 { failuresLeft -= 1; return true }; return false }
}

private struct Boom: LocalizedError { var errorDescription: String? { "disk on fire" } }

@MainActor
@Suite("SetupModel")
struct SetupModelTests {

    private var capableMac: HardwareProfile {
        HardwareProfile(chipName: "Apple M3 Pro", physicalMemoryBytes: 18 << 30, isAppleSilicon: true, freeDiskBytes: 500_000_000_000)
    }

    private func model(
        _ plan: SetupPlan, calls: Calls,
        install: (@Sendable (ModelCatalogEntry, @escaping @Sendable (ModelInstaller.Progress) -> Void) async throws -> Void)? = nil
    ) -> SetupModel {
        SetupModel(
            plan: plan, hardwareLine: "Apple M3 Pro · 18 GB memory",
            install: install ?? { entry, progress in
                await calls.record(entry.id)
                // Report in four steps, like a real download.
                for step in 1...4 {
                    progress(ModelInstaller.Progress(bytesDone: entry.approximateBytes * Int64(step) / 4,
                                                     bytesTotal: entry.approximateBytes, file: "f", fileIndex: 0, fileCount: 1))
                }
            },
            onFinished: { await calls.didFinish() })
    }

    @Test("installs each model in order, reports combined progress, then finishes exactly once")
    func happyPath() async {
        let calls = Calls()
        let m = model(SetupPlan.make(for: capableMac), calls: calls)
        #expect(m.phase == .ready && m.fraction == 0)
        m.start()
        #expect(m.phase == .installing)
        await m.waitUntilIdle()
        #expect(m.phase == .finished)
        #expect(m.fraction == 1)
        #expect(await calls.installed == ["bonsai-27b", "bge-small-en-v1.5"])
        #expect(await calls.finished == 1)
    }

    @Test("progress never goes backwards and stays below 100% until the models are in place")
    func monotonic() async {
        let calls = Calls()
        let seen = LockedFractions()
        let m = model(SetupPlan.make(for: capableMac), calls: calls)
        m.start()
        for _ in 0..<200 where m.phase == .installing { seen.add(m.fraction); try? await Task.sleep(for: .milliseconds(1)) }
        await m.waitUntilIdle()
        let values = seen.values
        #expect(values == values.sorted())
        #expect(values.allSatisfy { $0 < 1 })
    }

    @Test("a failed download shows the reason, does not finish, and can be retried")
    func failureAndRetry() async {
        let calls = Calls()
        await calls.setFailures(1)
        let m = model(SetupPlan.make(for: capableMac), calls: calls, install: { entry, progress in
            await calls.record(entry.id)
            if await calls.shouldFail() { throw Boom() }
        })
        m.start()
        await m.waitUntilIdle()
        #expect(m.phase == .failed("disk on fire"))
        #expect(await calls.finished == 0)

        m.start()                                   // "Try again"
        await m.waitUntilIdle()
        #expect(m.phase == .finished)
        #expect(await calls.finished == 1)
    }

    @Test("cancelling pauses without an error and does not finish; starting again resumes")
    func cancelAndResume() async {
        let calls = Calls()
        let m = model(SetupPlan.make(for: capableMac), calls: calls, install: { entry, progress in
            await calls.record(entry.id)
            if await calls.installed.count == 1 { try await Task.sleep(for: .seconds(30)) }   // first call hangs until cancelled
        })
        m.start()
        try? await Task.sleep(for: .milliseconds(50))
        m.cancel()
        await m.waitUntilIdle()
        #expect(m.phase == .ready)
        #expect(m.statusLine.contains("Paused"))
        #expect(await calls.finished == 0)

        m.start()
        await m.waitUntilIdle()
        #expect(m.phase == .finished)
    }

    @Test("with everything already installed there is nothing to download but setup still completes")
    func nothingToDownload() async {
        let calls = Calls()
        let plan = SetupPlan.make(for: capableMac, installed: ["bonsai-27b", "bge-small-en-v1.5"])
        let m = model(plan, calls: calls)
        m.start()
        await m.waitUntilIdle()
        #expect(m.phase == .finished)
        #expect(await calls.installed.isEmpty)
        #expect(await calls.finished == 1)
    }

    @Test("cloud-only and blocked plans never start an install")
    func noStart() async {
        let calls = Calls()
        let lowRAM = HardwareProfile(chipName: "Apple M1", physicalMemoryBytes: 8 << 30, isAppleSilicon: true, freeDiskBytes: 500_000_000_000)
        let cloud = model(SetupPlan.make(for: lowRAM), calls: calls)
        cloud.start(); await cloud.waitUntilIdle()
        #expect(cloud.phase == .ready)

        let lowDisk = HardwareProfile(chipName: "Apple M3", physicalMemoryBytes: 18 << 30, isAppleSilicon: true, freeDiskBytes: 2_000_000_000)
        let blocked = model(SetupPlan.make(for: lowDisk), calls: calls)
        blocked.start(); await blocked.waitUntilIdle()
        #expect(blocked.phase == .ready)
        #expect(await calls.installed.isEmpty)
    }

    @Test("start while already installing is ignored")
    func noDoubleStart() async {
        let calls = Calls()
        let m = model(SetupPlan.make(for: capableMac), calls: calls, install: { entry, _ in
            await calls.record(entry.id); try await Task.sleep(for: .milliseconds(40))
        })
        m.start(); m.start(); m.start()
        await m.waitUntilIdle()
        #expect(await calls.installed == ["bonsai-27b", "bge-small-en-v1.5"])
    }

    @Test("context description is a rounded, human-readable estimate")
    func contextDescription() {
        let m = model(SetupPlan.make(for: capableMac), calls: Calls())
        #expect(m.contextDescription?.hasPrefix("about ") == true)
        #expect(m.contextDescription?.hasSuffix(" words") == true)
        let cloud = model(SetupPlan.make(for: HardwareProfile(chipName: "x", physicalMemoryBytes: 8 << 30, isAppleSilicon: true, freeDiskBytes: nil)), calls: Calls())
        #expect(cloud.contextDescription == nil)
    }
}

private final class LockedFractions: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []
    func add(_ v: Double) { lock.withLock { storage.append(v) } }
    var values: [Double] { lock.withLock { storage } }
}

@Suite("Onboarding gate")
struct OnboardingGateTests {
    @Test("a registry holding only the embedder still needs onboarding: nothing to chat with")
    func embedderAloneIsNotEnough() async {
        let registry = ModelRegistry()
        await registry.register(LocalEmbedder(modelDirectory: URL(fileURLWithPath: "/nowhere"), scheduler: InferenceScheduler()))
        #expect(await registry.isEmpty == false)                                         // the old check would skip onboarding
        #expect(await registry.allProviders(with: .textGeneration).isEmpty)              // the new check asks for onboarding
    }
}
