import Foundation
import Darwin

struct ProcessInfoRow: Identifiable, Equatable {
    let id: pid_t
    let name: String
    /// 100% = 1 コア分 (アクティビティモニタと同じ基準)
    let cpu: Double
    let memory: UInt64
}

/// libproc で各プロセスの CPU 時間とメモリを読む。
///
/// 他ユーザー (root など) 所有のプロセスは権限が無いため読めない。
/// アクティビティモニタは特権ヘルパーを使ってこれを回避しているが、
/// このアプリは権限昇格をしないので、読めた分だけを表示する。
final class ProcessMonitor {
    private var previousCPUTime: [pid_t: UInt64] = [:]
    private var previousDate = Date()
    private var nameCache: [pid_t: String] = [:]

    /// 権限が無くて読めなかったプロセス数
    private(set) var inaccessibleCount = 0

    private var lastRows: [ProcessInfoRow] = []

    func sample() -> [ProcessInfoRow] {
        let now = Date()
        let elapsed = now.timeIntervalSince(previousDate)
        // 間隔が短すぎると、わずかな CPU 時間を極小の経過時間で割って
        // 数百 % のような値になる。前回の結果をそのまま返す
        if elapsed < 0.25, !lastRows.isEmpty { return lastRows }
        defer { previousDate = now }

        let pids = Self.allPIDs()
        var currentCPUTime: [pid_t: UInt64] = [:]
        currentCPUTime.reserveCapacity(pids.count)
        var rows: [ProcessInfoRow] = []
        rows.reserveCapacity(pids.count)
        var denied = 0

        for pid in pids {
            guard let usage = Self.resourceUsage(pid) else { denied += 1; continue }

            let cpuTime = usage.ri_user_time &+ usage.ri_system_time
            currentCPUTime[pid] = cpuTime

            var cpuPercent = 0.0
            if let previous = previousCPUTime[pid], cpuTime >= previous, elapsed > 0 {
                // 経過実時間で割ると 1 コア = 100% になる
                let nanoseconds = Self.nanoseconds(fromMachTicks: cpuTime - previous)
                cpuPercent = nanoseconds / (elapsed * 1_000_000_000) * 100
            }
            rows.append(ProcessInfoRow(id: pid, name: name(for: pid), cpu: cpuPercent, memory: usage.ri_phys_footprint))
        }

        previousCPUTime = currentCPUTime
        lastRows = rows
        inaccessibleCount = denied
        // 消えたプロセスの名前をキャッシュから落とす
        if nameCache.count > pids.count * 2 {
            nameCache = nameCache.filter { currentCPUTime[$0.key] != nil }
        }
        return rows
    }

    /// CPU 使用率の高い順
    func topByCPU(_ rows: [ProcessInfoRow], limit: Int = 5) -> [ProcessInfoRow] {
        Array(rows.sorted { $0.cpu > $1.cpu }.prefix(limit))
    }

    /// メモリ使用量の多い順
    func topByMemory(_ rows: [ProcessInfoRow], limit: Int = 5) -> [ProcessInfoRow] {
        Array(rows.sorted { $0.memory > $1.memory }.prefix(limit))
    }

    private func name(for pid: pid_t) -> String {
        if let cached = nameCache[pid] { return cached }
        let resolved = Self.executableName(pid)
        nameCache[pid] = resolved
        return resolved
    }

    /// ri_user_time / ri_system_time は mach absolute time 単位で返る。
    /// Apple Silicon では 1 tick = 125/3 ns、Intel では 1 tick = 1 ns なので
    /// timebase を掛けないと ARM で実際の 1/41.7 の値になってしまう。
    private static let timebase: (numerator: Double, denominator: Double) = {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom != 0 else { return (1, 1) }
        return (Double(info.numer), Double(info.denom))
    }()

    private static func nanoseconds(fromMachTicks ticks: UInt64) -> Double {
        Double(ticks) * timebase.numerator / timebase.denominator
    }

    private static func allPIDs() -> [pid_t] {
        let byteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard byteCount > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(byteCount) / MemoryLayout<pid_t>.size + 16)
        let written = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard written > 0 else { return [] }
        return Array(pids.prefix(Int(written) / MemoryLayout<pid_t>.size)).filter { $0 > 0 }
    }

    private static func resourceUsage(_ pid: pid_t) -> rusage_info_v4? {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
            }
        }
        return status == 0 ? info : nil
    }

    private static func executableName(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 4096)
        if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
            let path = String(cString: buffer)
            if !path.isEmpty { return (path as NSString).lastPathComponent }
        }
        var short = [CChar](repeating: 0, count: 256)
        if proc_name(pid, &short, UInt32(short.count)) > 0 { return String(cString: short) }
        return "PID \(pid)"
    }
}
