import Foundation
import Combine

/// メニューバーに何をどう出すか。UserDefaults に永続化する。
final class Settings: ObservableObject {
    static let shared = Settings()

    enum Style: String, CaseIterable, Identifiable {
        /// 「CPU / 23%」のように 2 行で並べる
        case compact
        /// 折れ線グラフ + 数値
        case graph
        var id: String { rawValue }
        var label: String { self == .compact ? "数値" : "グラフ" }
    }

    @Published var interval: Double { didSet { store(interval, "interval") } }
    @Published var style: Style { didSet { store(style.rawValue, "style") } }
    @Published var showCPU: Bool { didSet { store(showCPU, "showCPU") } }
    @Published var showMemory: Bool { didSet { store(showMemory, "showMemory") } }
    @Published var showGPU: Bool { didSet { store(showGPU, "showGPU") } }
    @Published var showTemperature: Bool { didSet { store(showTemperature, "showTemperature") } }

    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            "interval": 2.0,
            "style": Style.compact.rawValue,
            "showCPU": true,
            "showMemory": true,
            "showGPU": true,
            "showTemperature": true,
        ])
        interval = defaults.double(forKey: "interval")
        style = Style(rawValue: defaults.string(forKey: "style") ?? "") ?? .compact
        showCPU = defaults.bool(forKey: "showCPU")
        showMemory = defaults.bool(forKey: "showMemory")
        showGPU = defaults.bool(forKey: "showGPU")
        showTemperature = defaults.bool(forKey: "showTemperature")
    }


    private func store(_ value: Any, _ key: String) { defaults.set(value, forKey: key) }
}
