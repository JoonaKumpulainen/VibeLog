import Darwin
import Foundation
import os

public enum SystemStatus {
    public static var deviceModel: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    public static var thermalName: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "SERIOUS"
        case .critical: return "CRITICAL"
        @unknown default: return "unknown"
        }
    }

    /// Bytes the app can still allocate before the OS kills it.
    public static var availableMemory: Int { os_proc_available_memory() }

    /// Physical footprint, the number the OS memory limit applies to.
    public static var footprint: Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    /// Space writable right now. The "important usage" figure also counts purgeable data,
    /// which read 30 GB on a disk that was already full.
    public static var freeDisk: Int64 {
        let values = try? Storage.documents.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return Int64(values?.volumeAvailableCapacity ?? 0)
    }
}
