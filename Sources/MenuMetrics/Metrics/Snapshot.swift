import Foundation

/// 1 回のサンプリングで取れた全メトリクス。UI 側はこれだけを見る。
struct Snapshot {
    var cpu = CPUSample()
    var memory = MemorySample()
    var gpu = GPUSample()
    var thermal = ThermalSample()
    var date = Date()
}

struct CPUSample {
    /// 0...1
    var total: Double = 0
    var user: Double = 0
    var system: Double = 0
    var idle: Double = 1
    /// コアごとの使用率 (0...1)
    var perCore: [Double] = []
    /// 高効率コアの平均 (0...1)
    var efficiency: Double = 0
    /// 高性能コアの平均 (0...1)
    var performance: Double = 0
    var loadAverage: [Double] = [0, 0, 0]
}

struct MemorySample {
    var total: UInt64 = 0
    /// Activity Monitor の「使用済みメモリ」相当 (app + wired + compressed)
    var used: UInt64 = 0
    var app: UInt64 = 0
    var wired: UInt64 = 0
    var compressed: UInt64 = 0
    var cached: UInt64 = 0
    var free: UInt64 = 0
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0
    /// 1 = 正常, 2 = 警告, 4 = 逼迫
    var pressureLevel: Int = 1

    var usedRatio: Double { total == 0 ? 0 : Double(used) / Double(total) }
}

struct GPUSample {
    var name: String = "GPU"
    /// 0...1
    var utilization: Double = 0
    var rendererUtilization: Double = 0
    var tilerUtilization: Double = 0
    /// GPU が確保しているシステムメモリ
    var inUseMemory: UInt64 = 0
    var allocatedMemory: UInt64 = 0
    var available: Bool = false
}

struct ThermalSample {
    /// SoC ダイ (CPU/GPU クラスタ) の平均・最大
    var cpuAverage: Double?
    var cpuMax: Double?
    var gpuAverage: Double?
    var batteryTemperature: Double?
    var ssdTemperature: Double?
    /// 名前つきの生センサー一覧 (降順)
    var sensors: [(name: String, value: Double)] = []
    /// ProcessInfo.thermalState
    var state: ProcessInfo.ThermalState = .nominal
    var available: Bool = false

    /// メニューバーに出す代表温度。
    /// 常時表示ではセンサーを間引いて読むので、間引きの影響を受けにくい
    /// 平均値を使う (最高値だとパネルの開閉で数字が跳ねる)
    var headline: Double? { cpuAverage ?? gpuAverage ?? cpuMax }
}
