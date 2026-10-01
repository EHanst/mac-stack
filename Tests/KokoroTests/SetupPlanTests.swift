import Testing
import Foundation
@testable import KokoroCore
@testable import StackCore
@testable import StackMCP

@Suite("SetupPlan")
struct SetupPlanTests {

    private let gib: UInt64 = 1 << 30
    private func mac(ram: UInt64, silicon: Bool = true, disk: Int64? = 500_000_000_000) -> HardwareProfile {
        HardwareProfile(chipName: "Apple M3 Pro", physicalMemoryBytes: ram * gib, isAppleSilicon: silicon, freeDiskBytes: disk)
    }

    @Test("an 18 GB Apple-silicon Mac is offered the 4B with both downloads")
    func capableMac() {
        let plan = SetupPlan.make(for: mac(ram: 18))
        #expect(plan.mode == .local)
        #expect(plan.chat?.id == "qwen3.5-4b-optiq")
        #expect(plan.downloads.map(\.id) == ["qwen3.5-4b-optiq", "bge-small-en-v1.5"])
        #expect(plan.downloadBytes == 3_360_000_000 + 134_000_000)
        #expect(plan.blocker == nil)
        #expect((plan.approximateContextWords ?? 0) > 5_000)
    }

    @Test("24 GB and up get the 27B")
    func largeMac() {
        let plan = SetupPlan.make(for: mac(ram: 24))
        #expect(plan.chat?.id == "bonsai-27b")
        #expect(plan.downloads.map(\.id) == ["bonsai-27b", "bge-small-en-v1.5"])
    }

    @Test("a Mac that already has the 27B keeps it instead of downloading the 4B")
    func keepsInstalledLarge() {
        let plan = SetupPlan.make(for: mac(ram: 18), installed: ["bonsai-27b"])
        #expect(plan.chat?.id == "bonsai-27b")
        #expect(plan.downloads.map(\.id) == ["bge-small-en-v1.5"])
    }

    @Test("8 GB gets the 4B, with a smaller context than 32 GB")
    func floor() {
        let small = SetupPlan.make(for: mac(ram: 8))
        let big = SetupPlan.make(for: mac(ram: 32))
        #expect(small.mode == .local)
        #expect((small.approximateContextWords ?? 0) < (big.approximateContextWords ?? 0))
    }

    @Test("Macs below the 4B's floor are sent to a cloud provider with the reason in plain words")
    func lowMemory() {
        let plan = SetupPlan.make(for: mac(ram: 4))
        #expect(plan.mode == .cloudOnly)
        #expect(plan.downloads.isEmpty && plan.downloadBytes == 0)
        #expect(plan.detail.contains("4 GB") && plan.detail.contains("8 GB"))
        #expect(plan.approximateContextWords == nil)
    }

    @Test("Intel Macs are cloud-only")
    func intel() {
        let plan = SetupPlan.make(for: mac(ram: 32, silicon: false))
        #expect(plan.mode == .cloudOnly)
        #expect(plan.detail.contains("Apple-silicon"))
    }

    @Test("already-installed models are not downloaded again")
    func installed() {
        let some = SetupPlan.make(for: mac(ram: 18), installed: ["qwen3.5-4b-optiq"])
        #expect(some.downloads.map(\.id) == ["bge-small-en-v1.5"])
        let all = SetupPlan.make(for: mac(ram: 18), installed: ["qwen3.5-4b-optiq", "bge-small-en-v1.5"])
        #expect(all.downloads.isEmpty && all.downloadBytes == 0)
        #expect(all.detail.contains("already installed"))
        #expect(all.estimatedMinutes() == 0)
    }

    @Test("too little free disk space blocks setup and says how much to free")
    func lowDisk() {
        let plan = SetupPlan.make(for: mac(ram: 18, disk: 2_000_000_000))
        #expect(plan.mode == .local)
        #expect(plan.blocker?.contains("Free up") == true)
        #expect(SetupPlan.make(for: mac(ram: 18, disk: nil)).blocker == nil)     // unknown disk: don't block
    }

    @Test("download time estimate is in whole minutes and scales with speed")
    func eta() {
        let plan = SetupPlan.make(for: mac(ram: 18))
        #expect(plan.estimatedMinutes(megabitsPerSecond: 100) == 5)              // 3.49 GB at 100 Mbps ≈ 4.7 min
        #expect(plan.estimatedMinutes(megabitsPerSecond: 1000) < plan.estimatedMinutes(megabitsPerSecond: 100))
    }

    @Test("the current machine can be profiled")
    func currentMachine() {
        let hw = HardwareProfile.current()
        #expect(hw.physicalMemoryBytes > 0)
        #expect(!hw.chipName.isEmpty)
    }
}
