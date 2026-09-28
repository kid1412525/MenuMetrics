import Foundation
import Darwin

/// host_processor_info の tick 差分から CPU 使用率を求める。
final class CPUMonitor {
    private var previousTicks: [[UInt32]] = []
    private var previousDate = Date.distantPast
    private var lastResult = CPUSample()
    private let coreLayout = CoreLayout()

    /// これより短い間隔で呼ばれたら差分を取らない。
    /// tick の刻みより短いと全コア 0% になってしまうため
    private static let minimumInterval: TimeInterval = 0.25

    func sample() -> CPUSample {
        let now = Date()
        if now.timeIntervalSince(previousDate) < Self.minimumInterval, !previousTicks.isEmpty {
            var result = lastResult
            result.loadAverage = Self.loadAverage()
            return result
        }

        var result = CPUSample()
        result.loadAverage = Self.loadAverage()

        guard let ticks = Self.readTicks() else { return result }
        defer {
            previousTicks = ticks
            previousDate = now
            lastResult = result
        }

        guard previousTicks.count == ticks.count, !previousTicks.isEmpty else {
            // 初回は差分が取れないので 0 のまま返す
            result.perCore = Array(repeating: 0, count: ticks.count)
            return result
        }

        var totalUser = 0.0, totalSystem = 0.0, totalIdle = 0.0, totalAll = 0.0
        var perCore: [Double] = []
        perCore.reserveCapacity(ticks.count)

        for (index, current) in ticks.enumerated() {
            let previous = previousTicks[index]
            let user = Double(current[0] &- previous[0])
            let system = Double(current[1] &- previous[1])
            let idle = Double(current[2] &- previous[2])
            let nice = Double(current[3] &- previous[3])
            let sum = user + system + idle + nice

            perCore.append(sum > 0 ? (user + system + nice) / sum : 0)
            totalUser += user + nice
            totalSystem += system
            totalIdle += idle
            totalAll += sum
        }

        result.perCore = perCore
        if totalAll > 0 {
            result.user = totalUser / totalAll
            result.system = totalSystem / totalAll
            result.idle = totalIdle / totalAll
            result.total = min(1, max(0, (totalUser + totalSystem) / totalAll))
        }

        let (efficiency, performance) = coreLayout.split(perCore)
        result.efficiency = efficiency
        result.performance = performance
        return result
    }

    /// [user, system, idle, nice] × コア数
    private static func readTicks() -> [[UInt32]]? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0

        let status = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount)
        guard status == KERN_SUCCESS, let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        let stride = Int(CPU_STATE_MAX)
        var ticks: [[UInt32]] = []
        ticks.reserveCapacity(Int(cpuCount))
        for core in 0..<Int(cpuCount) {
            let base = core * stride
            ticks.append([
                UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]),
                UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]),
                UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]),
                UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]),
            ])
        }
        return ticks
    }

    private static func loadAverage() -> [Double] {
        var values = [Double](repeating: 0, count: 3)
        guard getloadavg(&values, 3) == 3 else { return [0, 0, 0] }
        return values
    }
}

/// Apple Silicon の高効率/高性能コアの並び。
/// host_processor_info は高効率コアを先頭に並べて返す。
struct CoreLayout {
    let efficiencyCount: Int
    let performanceCount: Int
    let isHeterogeneous: Bool

    init() {
        let level0 = CoreLayout.sysctlInt("hw.perflevel0.logicalcpu") ?? 0
        let level1 = CoreLayout.sysctlInt("hw.perflevel1.logicalcpu") ?? 0
        // perflevel0 = 高性能、perflevel1 = 高効率 (Apple Silicon)
        performanceCount = level0
        efficiencyCount = level1
        isHeterogeneous = level1 > 0 && level0 > 0
    }

    /// (高効率コア平均, 高性能コア平均)
    func split(_ perCore: [Double]) -> (Double, Double) {
        guard isHeterogeneous, perCore.count == efficiencyCount + performanceCount else {
            let average = perCore.isEmpty ? 0 : perCore.reduce(0, +) / Double(perCore.count)
            return (average, average)
        }
        let efficiencySlice = perCore.prefix(efficiencyCount)
        let performanceSlice = perCore.suffix(performanceCount)
        let efficiency = efficiencySlice.reduce(0, +) / Double(max(1, efficiencySlice.count))
        let performance = performanceSlice.reduce(0, +) / Double(max(1, performanceSlice.count))
        return (efficiency, performance)
    }

    static func sysctlInt(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}
