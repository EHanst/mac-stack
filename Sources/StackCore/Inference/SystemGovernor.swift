import Dispatch
import Foundation

/// How hard this Mac is being pushed right now.
public struct SystemLoad: Sendable, Equatable {
    public enum Memory: Int, Sendable, Comparable { case normal, warning, critical
        public static func < (a: Memory, b: Memory) -> Bool { a.rawValue < b.rawValue } }
    public enum Thermal: Int, Sendable, Comparable { case nominal, fair, serious, critical
        public static func < (a: Thermal, b: Thermal) -> Bool { a.rawValue < b.rawValue } }

    public var memory: Memory = .normal
    public var thermal: Thermal = .nominal
    public var lowPowerMode = false

    public init(memory: Memory = .normal, thermal: Thermal = .nominal, lowPowerMode: Bool = false) {
        self.memory = memory; self.thermal = thermal; self.lowPowerMode = lowPowerMode
    }

    /// Reasons to keep heavy local work light; used to route to the cloud when the user allows it.
    public var isStrained: Bool { memory != .normal || thermal >= .serious || lowPowerMode }

    /// Plain-language reason for the menu and logs, or nil when all is well.
    public var explanation: String? {
        var reasons: [String] = []
        if memory == .critical { reasons.append("this Mac is very short on memory") }
        else if memory == .warning { reasons.append("this Mac is low on memory") }
        if thermal >= .serious { reasons.append("it is running hot") }
        if lowPowerMode { reasons.append("Low Power Mode is on") }
        guard !reasons.isEmpty else { return nil }
        let text = reasons.joined(separator: " and ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    public static func thermal(from state: ProcessInfo.ThermalState) -> Thermal {
        switch state {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .fair
        }
    }
}

/// Watches memory pressure, thermal state and Low Power Mode. `InferenceService` asks it whether
/// to prefer the cloud (when allowed); the app shows the reason and frees caches on critical pressure.
public actor SystemGovernor {

    public private(set) var current = SystemLoad()
    private var handlers: [@Sendable (SystemLoad) -> Void] = []
    private var memorySource: DispatchSourceMemoryPressure?
    private var observers: [NSObjectProtocol] = []

    public init() {}

    /// Called (from any thread) whenever the load changes.
    public func onChange(_ handler: @escaping @Sendable (SystemLoad) -> Void) { handlers.append(handler) }

    public func start() {
        guard memorySource == nil else { return }
        current.thermal = SystemLoad.thermal(from: ProcessInfo.processInfo.thermalState)
        current.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled

        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler { [weak self, weak source] in
            guard let event = source?.data else { return }
            let level: SystemLoad.Memory = event.contains(.critical) ? .critical : event.contains(.warning) ? .warning : .normal
            Task { await self?.update { $0.memory = level } }
        }
        source.resume()
        memorySource = source

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil) { [weak self] _ in
            let t = SystemLoad.thermal(from: ProcessInfo.processInfo.thermalState)
            Task { await self?.update { $0.thermal = t } }
        })
        observers.append(center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: nil) { [weak self] _ in
            let low = ProcessInfo.processInfo.isLowPowerModeEnabled
            Task { await self?.update { $0.lowPowerMode = low } }
        })
    }

    public func stop() {
        memorySource?.cancel(); memorySource = nil
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
    }

    /// Applies a change and tells listeners if anything differs (also the hook tests use).
    public func update(_ change: (inout SystemLoad) -> Void) {
        var next = current
        change(&next)
        guard next != current else { return }
        current = next
        for h in handlers { h(next) }
    }
}
