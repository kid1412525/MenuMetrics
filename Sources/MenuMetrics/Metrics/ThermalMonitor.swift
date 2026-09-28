import Foundation

/// Apple Silicon / Intel Mac の温度センサーを IOHIDEventSystem 経由で読む。
///
/// 温度センサーは公開 API では取れないため、IOKit の非公開シンボルを
/// dlsym で引いて使う (root 権限は不要)。シンボルが無い環境では
/// `available == false` になり、UI 側は温度表示を隠す。
///
/// センサー名の分類は M2 Pro 実機で CPU 負荷・GPU 負荷をかけて
/// 反応を計測した結果に基づく:
///   PMU tdie* / PMU TP*  … SoC ダイ (CPU/GPU クラスタ)。両方の負荷で上昇
///   PMU tdev7            … GPU 負荷でのみ強く上昇 (GPU 寄りセンサー)
///   PMU tcal             … 常に一定の校正値。除外する
///   NAND CH*             … 内蔵 SSD
///   gas gauge battery    … バッテリー
final class ThermalMonitor {
    private typealias CreateClient = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatching = @convention(c) (AnyObject?, CFDictionary?) -> Int32
    private typealias CopyServices = @convention(c) (AnyObject?) -> Unmanaged<CFArray>?
    private typealias CopyProperty = @convention(c) (AnyObject?, CFString) -> Unmanaged<CFTypeRef>?
    private typealias CopyEvent = @convention(c) (AnyObject?, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias GetFloatValue = @convention(c) (AnyObject?, Int32) -> Double

    private struct Bridge {
        let createClient: CreateClient
        let setMatching: SetMatching
        let copyServices: CopyServices
        let copyProperty: CopyProperty
        let copyEvent: CopyEvent
        let getFloatValue: GetFloatValue

        init?() {
            guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY) else { return nil }
            func symbol(_ name: String) -> UnsafeMutableRawPointer? { dlsym(handle, name) }
            guard let create = symbol("IOHIDEventSystemClientCreate"),
                  let match = symbol("IOHIDEventSystemClientSetMatching"),
                  let services = symbol("IOHIDEventSystemClientCopyServices"),
                  let property = symbol("IOHIDServiceClientCopyProperty"),
                  let event = symbol("IOHIDServiceClientCopyEvent"),
                  let float = symbol("IOHIDEventGetFloatValue") else { return nil }
            createClient = unsafeBitCast(create, to: CreateClient.self)
            setMatching = unsafeBitCast(match, to: SetMatching.self)
            copyServices = unsafeBitCast(services, to: CopyServices.self)
            copyProperty = unsafeBitCast(property, to: CopyProperty.self)
            copyEvent = unsafeBitCast(event, to: CopyEvent.self)
            getFloatValue = unsafeBitCast(float, to: GetFloatValue.self)
        }
    }

    /// kIOHIDEventTypeTemperature
    private static let temperatureEventType: Int64 = 15
    private static let temperatureField = Int32(truncatingIfNeeded: temperatureEventType << 16)
    /// 温度センサーだけを拾う HID マッチング条件
    private static let matching: CFDictionary = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary

    private let bridge = Bridge()
    private var client: AnyObject?
    private var services: [AnyObject] = []
    private var names: [String] = []
    /// 常時読む代表センサーの添字 (全件読むと 1 回 60 ms かかるため)
    private var representativeIndices: [Int] = []
    private var cached: ThermalSample?
    private var cachedDate = Date.distantPast
    private var cachedWasDetailed = false

    /// 温度は急には変わらないので、これより短い間隔では読み直さない
    private static let minimumReadInterval: TimeInterval = 3.5

    var isAvailable: Bool { bridge != nil }

    /// - Parameter detailed: true なら全センサーを読む (詳細パネルを開いている間)。
    ///   false のときは代表センサーだけを読んで負荷を抑える。
    func sample(detailed: Bool = false) -> ThermalSample {
        var result = ThermalSample()
        result.state = ProcessInfo.processInfo.thermalState

        guard let bridge else { return result }
        if let cached, cachedWasDetailed == detailed,
           Date().timeIntervalSince(cachedDate) < Self.minimumReadInterval {
            var reused = cached
            reused.state = result.state
            return reused
        }
        if services.isEmpty { connect(bridge) }
        guard !services.isEmpty else { return result }

        // 同じ名前のセンサーが複数出てくるので平均をとる
        var sums: [String: (total: Double, count: Int)] = [:]
        var order: [String] = []
        var readCount = 0

        let indices = detailed ? Array(services.indices) : representativeIndices
        for index in indices {
            guard let event = bridge.copyEvent(services[index], Self.temperatureEventType, 0, 0)?.takeRetainedValue() else { continue }
            let value = bridge.getFloatValue(event, Self.temperatureField)
            let name = names[index]
            guard value.isFinite, value > -20, value < 150, !Self.isExcluded(name) else { continue }

            readCount += 1
            if let existing = sums[name] {
                sums[name] = (existing.total + value, existing.count + 1)
            } else {
                sums[name] = (value, 1)
                order.append(name)
            }
        }

        guard readCount > 0 else {
            // スリープ復帰などでサービスが無効化されることがあるので次回張り直す
            services = []
            names = []
            representativeIndices = []
            client = nil
            cached = nil
            return result
        }

        var averages: [String: Double] = [:]
        for (name, entry) in sums { averages[name] = entry.total / Double(entry.count) }

        var dieValues: [Double] = []
        var gpuValues: [Double] = []
        for (name, value) in averages {
            if Self.isDieSensor(name) { dieValues.append(value) }
            if Self.isGPUSensor(name) { gpuValues.append(value) }
            if name.contains("NAND") { result.ssdTemperature = max(result.ssdTemperature ?? -.infinity, value) }
            if name.contains("battery") { result.batteryTemperature = max(result.batteryTemperature ?? -.infinity, value) }
        }

        if !dieValues.isEmpty {
            result.cpuAverage = dieValues.reduce(0, +) / Double(dieValues.count)
            result.cpuMax = dieValues.max()
        }
        if !gpuValues.isEmpty {
            result.gpuAverage = gpuValues.reduce(0, +) / Double(gpuValues.count)
        }
        result.sensors = order.compactMap { name in averages[name].map { (name: name, value: $0) } }
            .sorted { $0.value > $1.value }
        result.available = true
        cached = result
        cachedDate = Date()
        cachedWasDetailed = detailed
        return result
    }

    private func connect(_ bridge: Bridge) {
        guard let newClient = bridge.createClient(kCFAllocatorDefault)?.takeRetainedValue() else { return }
        _ = bridge.setMatching(newClient, Self.matching)
        guard let list = bridge.copyServices(newClient)?.takeRetainedValue() as? [AnyObject] else { return }
        client = newClient
        services = list
        names = list.map { service in
            (bridge.copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String) ?? "不明なセンサー"
        }
        representativeIndices = Self.selectRepresentative(names)
    }

    /// 1 センサーの読み取りに約 1 ms かかるので、常時表示では代表だけを読む。
    /// ダイのセンサーは互いに 1 度以内に収まるため、間引いても平均値は変わらない。
    private static func selectRepresentative(_ names: [String]) -> [Int] {
        var dieIndices: [Int] = []
        var othersByName: [String: Int] = [:]

        for (index, name) in names.enumerated() where !isExcluded(name) {
            if isDieSensor(name) {
                dieIndices.append(index)
            } else if isGPUSensor(name) || name.contains("NAND") || name.contains("battery") {
                // 同名センサーは重複しているので最初の 1 つだけでよい
                if othersByName[name] == nil { othersByName[name] = index }
            }
        }

        let wanted = 6
        let step = max(1, dieIndices.count / wanted)
        let sampledDie = dieIndices.enumerated()
            .filter { $0.offset % step == 0 }
            .map(\.element)
            .prefix(wanted)
        return Array(sampledDie) + othersByName.values.sorted()
    }

    // MARK: - センサー名の分類

    /// 校正用センサーは常に一定値を返すので温度としては使わない
    private static func isExcluded(_ name: String) -> Bool {
        name.hasPrefix("PMU tcal")
    }

    /// SoC ダイ (CPU/GPU クラスタ) のセンサー
    private static func isDieSensor(_ name: String) -> Bool {
        name.hasPrefix("PMU tdie") || name.hasPrefix("PMU TP") || name.hasPrefix("SOC MTR Temp")
            || name.hasPrefix("TCXC") || name.hasPrefix("TC0") // Intel Mac の SMC 名
    }

    /// GPU 負荷に強く反応するセンサー (実測で特定。Apple の公式資料は無い)
    private static func isGPUSensor(_ name: String) -> Bool {
        name.hasPrefix("PMU tdev7") || name.hasPrefix("TG0") // Intel Mac の GPU ダイ
    }
}
