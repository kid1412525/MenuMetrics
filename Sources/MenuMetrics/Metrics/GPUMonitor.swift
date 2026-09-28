import Foundation
import IOKit
import Metal

/// IORegistry の IOAccelerator から GPU の使用率を読む。
/// AGXAccelerator (Apple Silicon) / AMD・Intel の各ドライバが同じ
/// PerformanceStatistics 辞書を公開しているため、機種を問わず動く。
final class GPUMonitor {
    /// Metal のデバイス名 (registryID → 名前)。IORegistry 側の名前は
    /// "sgx" のような内部名なので、表示には Metal の名前を使う。
    private lazy var deviceNames: [UInt64: String] = {
        var map: [UInt64: String] = [:]
        for device in MTLCopyAllDevices() { map[device.registryID] = device.name }
        return map
    }()

    private lazy var fallbackDeviceName: String? = {
        deviceNames.count == 1 ? deviceNames.values.first : MTLCreateSystemDefaultDevice()?.name
    }()

    /// IOAccelerator のサービスは使い回す。毎回 IOServiceGetMatchingServices を
    /// 呼ぶと 1 回 1.8 ms かかるので、常駐アプリでは無視できない
    private var accelerators: [io_registry_entry_t] = []
    private var cachedName: String?

    deinit {
        for entry in accelerators { IOObjectRelease(entry) }
    }

    func sample() -> GPUSample {
        var result = GPUSample()
        if accelerators.isEmpty { connect() }
        guard !accelerators.isEmpty else { return result }

        for entry in accelerators {
            // 全プロパティを複製すると重いので、必要な 1 つだけを読む
            guard let statistics = IORegistryEntryCreateCFProperty(
                entry, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? [String: Any] else { continue }

            func percent(_ key: String) -> Double? {
                guard let value = statistics[key] as? NSNumber else { return nil }
                return min(1, max(0, value.doubleValue / 100))
            }
            func size(_ key: String) -> UInt64 {
                (statistics[key] as? NSNumber).map { UInt64(max(0, $0.int64Value)) } ?? 0
            }

            // 内蔵 GPU が複数見つかった場合は使用率が高いほうを採用する
            let utilization = percent("Device Utilization %") ?? percent("GPU Core Utilization") ?? 0
            if result.available && utilization <= result.utilization { continue }

            result.available = true
            result.utilization = utilization
            result.rendererUtilization = percent("Renderer Utilization %") ?? 0
            result.tilerUtilization = percent("Tiler Utilization %") ?? 0
            result.inUseMemory = size("In use system memory")
            result.allocatedMemory = size("Alloc system memory")
            if cachedName == nil {
                cachedName = metalName(for: entry) ?? Self.gpuName(for: entry)
            }
            result.name = cachedName ?? result.name
        }

        if !result.available {
            // スリープ復帰などでサービスが無効になることがあるので張り直す
            for entry in accelerators { IOObjectRelease(entry) }
            accelerators = []
            cachedName = nil
        }
        return result
    }

    private func connect() {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else {
            return
        }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            accelerators.append(entry)   // 解放せずに保持する
        }
    }

    /// IOAccelerator (またはその親) の registryID を Metal のデバイスと突き合わせる。
    private func metalName(for entry: io_registry_entry_t) -> String? {
        var entryID: UInt64 = 0
        if IORegistryEntryGetRegistryEntryID(entry, &entryID) == KERN_SUCCESS, let name = deviceNames[entryID] {
            return name
        }
        var parent = io_registry_entry_t()
        if IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS {
            defer { IOObjectRelease(parent) }
            var parentID: UInt64 = 0
            if IORegistryEntryGetRegistryEntryID(parent, &parentID) == KERN_SUCCESS, let name = deviceNames[parentID] {
                return name
            }
        }
        return fallbackDeviceName
    }

    /// IOAccelerator の親 (IOGraphicsAccelerator / AGXAccelerator) からモデル名を拾う。
    private static func gpuName(for entry: io_registry_entry_t) -> String? {
        var parent = io_registry_entry_t()
        guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(parent) }

        if let model = IORegistryEntryCreateCFProperty(parent, "model" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() {
            if let string = model as? String { return string }
            if let data = model as? Data, let string = String(data: data, encoding: .utf8) {
                return string.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
            }
        }
        // io_name_t は char[128]
        var name = [CChar](repeating: 0, count: 128)
        guard IORegistryEntryGetName(parent, &name) == KERN_SUCCESS else { return nil }
        return String(cString: name)
    }
}
