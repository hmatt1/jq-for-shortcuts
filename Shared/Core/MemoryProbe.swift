import Foundation
#if canImport(Darwin)
import Darwin
#endif
#if os(iOS)
import os
#endif

/// Reads this process's memory use, which the engine checks while a filter
/// runs to enforce the memory cap (R9.6).
enum MemoryProbe {
    /// The physical footprint: the number iOS compares against the process's
    /// memory limit. Nil where the platform cannot report it.
    static func footprint() -> UInt64? {
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
        #else
        return nil
        #endif
    }

    /// How much more this process may allocate before iOS ends it. Nil where
    /// the platform cannot say, such as the Simulator, which reports 0.
    static func availableBytes() -> UInt64? {
        #if os(iOS)
        let available = os_proc_available_memory()
        return available > 0 ? UInt64(available) : nil
        #else
        return nil
        #endif
    }
}
