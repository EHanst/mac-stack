import Testing
import Foundation
@testable import VibeCockpitCore
@testable import StackCore
@testable import StackMCP

@Suite("SetupPlan")
struct SetupPlanTests {

    private let gib: UInt64 = 1 << 30
    private func mac(ram: UInt64, silicon: Bool = true, disk: Int64? = 500_000_000_000) -> HardwareProfile {
        HardwareProfile(chipName: "Apple M3 Pro", physicalMemoryBytes: ram * gib, isAppleSilicon: silicon, freeDiskBytes: disk)
    }

    @Test("an 18 GB Apple-silicon Mac is offered the local model with both downloads")
    func capableMac() {
        let plan = SetupPlan.make(for: mac(ram: 18))
        #expect(plan.mode == .local)
        #expect(plan.downloads.map(\.id) == ["bonsai-27b", "bge-small-en-v1.5"])
        #expect(plan.downloadBytes == 8_610_000_000 + 134_000_000)
        #expect(plan.blocker == nil)
        #expect((plan.approximateContextWords ?? 0) > 5_000)
    }

    @Test("16 GB is the floor and still gets the local model, with a smaller context than 32 GB")
    func floor() {
        let small = SetupPlan.make(for: mac(ram: 16))
        let big = SetupPlan.make(for: mac(ram: 32))
        #expect(small.mode == .local)
        #expect((small.approximateContextWords ?? 0) < (big.approximateContextWords ?? 0))
    }

    @Test("8 GB Macs are sent to a cloud provider with the reason in plain words")
    func lowMemory() {
        let plan = SetupPlan.make(for: mac(ram: 8))
        #expect(plan.mode == .cloudOnly)
        #expect(plan.downloads.isEmpty && plan.downloadBytes == 0)
        #expect(plan.detail.contains("8 GB") && plan.detail.contains("16 GB"))
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
        let some = SetupPlan.make(for: mac(ram: 18), installed: ["bonsai-27b"])
        #expect(some.downloads.map(\.id) == ["bge-small-en-v1.5"])
        let all = SetupPlan.make(for: mac(ram: 18), installed: ["bonsai-27b", "bge-small-en-v1.5"])
        #expect(all.downloads.isEmpty && all.downloadBytes == 0)
        #expect(all.detail.contains("already installed"))
        #expect(all.estimatedMinutes() == 0)
    }

    @Test("too little free disk space blocks setup and says how much to free")
    func lowDisk() {
        let plan = SetupPlan.make(for: mac(ram: 18, disk: 5_000_000_000))
        #expect(plan.mode == .local)
        #expect(plan.blocker?.contains("Free up") == true)
        #expect(SetupPlan.make(for: mac(ram: 18, disk: nil)).blocker == nil)     // unknown disk: don't block
    }

    @Test("download time estimate is in whole minutes and scales with speed")
    func eta() {
        let plan = SetupPlan.make(for: mac(ram: 18))
        #expect(plan.estimatedMinutes(megabitsPerSecond: 100) == 12)             // 8.74 GB at 100 Mbps ≈ 11.7 min
        #expect(plan.estimatedMinutes(megabitsPerSecond: 1000) < plan.estimatedMinutes(megabitsPerSecond: 100))
    }

    @Test("the current machine can be profiled")
    func currentMachine() {
        let hw = HardwareProfile.current()
        #expect(hw.physicalMemoryBytes > 0)
        #expect(!hw.chipName.isEmpty)
    }
}
