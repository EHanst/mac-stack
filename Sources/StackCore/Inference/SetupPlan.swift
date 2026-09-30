import Darwin
import Foundation

/// What this Mac is, as far as first-run setup cares.
public struct HardwareProfile: Sendable, Equatable {
    public let chipName: String
    public let physicalMemoryBytes: UInt64
    public let isAppleSilicon: Bool
    /// Free space on the volume that will hold the models (nil if unknown).
    public let freeDiskBytes: Int64?

    public init(chipName: String, physicalMemoryBytes: UInt64, isAppleSilicon: Bool, freeDiskBytes: Int64?) {
        self.chipName = chipName
        self.physicalMemoryBytes = physicalMemoryBytes
        self.isAppleSilicon = isAppleSilicon
        self.freeDiskBytes = freeDiskBytes
    }

    public static func current(installRoot: URL = ModelInstaller.defaultRoot()) -> HardwareProfile {
        func sysctlString(_ name: String) -> String {
            var size = 0
            sysctlbyname(name, nil, &size, nil, 0)
            var buffer = [CChar](repeating: 0, count: size)
            sysctlbyname(name, &buffer, &size, nil, 0)
            return String(cString: buffer)
        }
        var arm64: Int32 = 0
        var armSize = MemoryLayout<Int32>.size
        sysctlbyname("hw.optional.arm64", &arm64, &armSize, nil, 0)
        // The install folder may not exist yet; measure the nearest existing parent.
        var probe = installRoot
        while !FileManager.default.fileExists(atPath: probe.path), probe.path != "/" {
            probe = probe.deletingLastPathComponent()
        }
        return HardwareProfile(
            chipName: sysctlString("machdep.cpu.brand_string"),
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            isAppleSilicon: arm64 == 1,
            freeDiskBytes: ModelInstaller.volumeAvailableBytes(probe))
    }
}

/// The recommendation shown on first run: run a model on this Mac, or use a cloud provider —
/// with the reason in plain language and exactly what would be downloaded.
public struct SetupPlan: Sendable, Equatable {

    public enum Mode: Sendable, Equatable { case local, cloudOnly }

    public let mode: Mode
    public let headline: String
    public let detail: String
    /// Models still to download (empty if everything is installed, or cloud-only).
    public let downloads: [ModelCatalogEntry]
    public let downloadBytes: Int64
    /// Roughly how long a conversation the local model can hold on this Mac, in words.
    public let approximateContextWords: Int?
    /// Set when local setup can't proceed as things stand (e.g. not enough disk space).
    public let blocker: String?
    /// The chat model this plan installs or uses (nil when cloud-only).
    public var chat: ModelCatalogEntry? = nil

    /// Working set macOS gives the GPU, as a fraction of RAM. Measured 0.74 on an 18 GB M3 Pro;
    /// assumed for other sizes.
    static let assumedWorkingSetFraction = 0.74

    public static func make(
        for hardware: HardwareProfile,
        installed: Set<String> = [],
        chat chatOverride: ModelCatalogEntry? = nil,
        embedder: ModelCatalogEntry = ModelCatalog.bgeSmall,
        budget budgetOverride: ContextBudget? = nil,
        weightBytes weightOverride: Int? = nil
    ) -> SetupPlan {
        let chat = chatOverride
            ?? ModelCatalog.recommendedChat(forRAM: hardware.physicalMemoryBytes, installed: installed)
        let budget = budgetOverride ?? chat.contextBudget
        let weightBytes = weightOverride ?? chat.residentWeightBytes
        func cloud(_ headline: String, _ detail: String) -> SetupPlan {
            SetupPlan(mode: .cloudOnly, headline: headline, detail: detail, downloads: [],
                      downloadBytes: 0, approximateContextWords: nil, blocker: nil)
        }
        func gb(_ bytes: UInt64) -> String { String(format: "%.0f", Double(bytes) / 1_073_741_824) }

        guard hardware.isAppleSilicon else {
            return cloud("Use a cloud provider",
                         "Running a model on this Mac needs an Apple-silicon chip (M1 or newer).")
        }
        if let need = chat.minimumRAMBytes, hardware.physicalMemoryBytes < need {
            return cloud("Use a cloud provider",
                         "This Mac has \(gb(hardware.physicalMemoryBytes)) GB of memory. The local model needs \(gb(need)) GB, so it will use a cloud provider you choose instead.")
        }
        let workingSet = Int(Double(hardware.physicalMemoryBytes) * assumedWorkingSetFraction)
        guard case .ok(let tokens) = budget.verdict(workingSetBytes: workingSet, weightBytes: weightBytes) else {
            return cloud("Use a cloud provider",
                         "This Mac doesn't have enough free memory to run the local model comfortably, so it will use a cloud provider you choose instead.")
        }

        let downloads = [chat, embedder].filter { !installed.contains($0.id) }
        let bytes = downloads.reduce(Int64(0)) { $0 + $1.approximateBytes }
        var blocker: String?
        if let free = hardware.freeDiskBytes, free < bytes + ModelInstaller.diskMargin {
            let short = Double(bytes + ModelInstaller.diskMargin - free) / 1_000_000_000
            blocker = String(format: "Free up about %.1f GB of disk space to download the model.", short)
        }
        let words = tokens * 3 / 4
        let detail = downloads.isEmpty
            ? "The local model is already installed. It works offline and keeps your work on this Mac."
            : String(format: "One-time download of about %.1f GB. It then works offline and keeps your work on this Mac.",
                     Double(bytes) / 1_000_000_000)
        return SetupPlan(mode: .local, headline: "Run the AI on this Mac", detail: detail,
                         downloads: downloads, downloadBytes: bytes,
                         approximateContextWords: words, blocker: blocker, chat: chat)
    }

    /// Whole minutes a download of `downloadBytes` takes at `megabitsPerSecond`.
    public func estimatedMinutes(megabitsPerSecond: Double = 100) -> Int {
        guard downloadBytes > 0, megabitsPerSecond > 0 else { return 0 }
        return Int((Double(downloadBytes) * 8 / (megabitsPerSecond * 1_000_000) / 60).rounded(.up))
    }
}
