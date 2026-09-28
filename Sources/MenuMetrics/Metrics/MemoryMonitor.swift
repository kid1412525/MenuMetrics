import Foundation
import Darwin

/// host_statistics64 から、アクティビティモニタと同じ区分でメモリを読む。
final class MemoryMonitor {
    private let pageSize: UInt64 = {
        var size: vm_size_t = 0
        guard host_page_size(mach_host_self(), &size) == KERN_SUCCESS else { return 16384 }
        return UInt64(size)
    }()

    private let totalMemory: UInt64 = {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname("hw.memsize", &value, &size, nil, 0) == 0 else { return 0 }
        return value
    }()

    func sample() -> MemorySample {
        var result = MemorySample()
        result.total = totalMemory
        result.pressureLevel = Self.pressureLevel()

        let swap = Self.swapUsage()
        result.swapUsed = swap.used
        result.swapTotal = swap.total

        guard let vm = Self.vmStatistics() else { return result }
        func bytes(_ pages: natural_t) -> UInt64 { UInt64(pages) * pageSize }

        // アクティビティモニタの「メモリ」タブと同じ区分
        //   アプリメモリ = internal - purgeable / 使用済み = アプリ + 確保済み + 圧縮
        let purgeable = bytes(vm.purgeable_count)
        let internalPages = bytes(vm.internal_page_count)
        result.app = internalPages > purgeable ? internalPages - purgeable : internalPages
        result.wired = bytes(vm.wire_count)
        result.compressed = bytes(vm.compressor_page_count)
        result.cached = bytes(vm.external_page_count) + purgeable

        let free = bytes(vm.free_count)
        let speculative = bytes(vm.speculative_count)
        result.free = free > speculative ? free - speculative : free
        result.used = result.app + result.wired + result.compressed
        return result
    }

    private static func vmStatistics() -> vm_statistics64_data_t? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        return status == KERN_SUCCESS ? stats : nil
    }

    /// 1 = 正常, 2 = 警告, 4 = 逼迫
    private static func pressureLevel() -> Int {
        var value: Int32 = 1
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &value, &size, nil, 0) == 0 else { return 1 }
        return Int(value)
    }

    private static func swapUsage() -> (used: UInt64, total: UInt64) {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return (0, 0) }
        return (usage.xsu_used, usage.xsu_total)
    }
}
