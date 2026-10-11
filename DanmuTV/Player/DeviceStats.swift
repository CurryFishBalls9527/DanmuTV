import Foundation

/// CPU / memory / thermal state for the debug panel.
enum DeviceStats {
    static func summary() -> String {
        var parts: [String] = []
        if let cpu = cpuUsage() { parts.append(String(format: "CPU %.0f%%", cpu)) }
        if let mem = memoryFootprintMB() { parts.append(String(format: "内存 %.0f MB", mem)) }
        parts.append("温度 " + thermal())
        return "设备  " + parts.joined(separator: " · ")
    }

    /// Sum of this process's thread CPU usage (100% = one core).
    static func cpuUsage() -> Double? {
        var threads: thread_act_array_t?
        var count = mach_msg_type_number_t(0)
        guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS, let threads else { return nil }
        defer {
            // task_threads hands out a send right per thread and an array to free.
            for i in 0 ..< Int(count) { mach_port_deallocate(mach_task_self_, threads[i]) }
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threads)), vm_size_t(Int(count) * MemoryLayout<thread_t>.stride))
        }
        var total = 0.0
        for i in 0 ..< Int(count) {
            var info = thread_basic_info()
            var infoCount = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
                    thread_info(threads[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &infoCount)
                }
            }
            if result == KERN_SUCCESS, info.flags & TH_FLAGS_IDLE == 0 {
                total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100
            }
        }
        return total
    }

    static func memoryFootprintMB() -> Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : nil
    }

    static func thermal() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "正常"
        case .fair: return "略高"
        case .serious: return "高"
        case .critical: return "过热"
        @unknown default: return "未知"
        }
    }
}
