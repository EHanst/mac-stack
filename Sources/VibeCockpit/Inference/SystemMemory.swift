import Darwin

enum SystemMemory {
    /// Bytes the system could give a new allocation right now (free + inactive pages).
    /// GPU memory is unified with system memory, so another app's model (Ollama, another MLX
    /// app) shows up as memory that is no longer available here.
    static func availableBytes() -> Int? {
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        var stats = vm_statistics64_data_t()
        let status = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        return Int(stats.free_count + stats.inactive_count) * Int(getpagesize())
    }
}
