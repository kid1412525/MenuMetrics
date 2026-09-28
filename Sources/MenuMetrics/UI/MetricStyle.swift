import AppKit
import SwiftUI

/// 4 つのメトリクスの色と書式をここに集約する。
enum MetricStyle {
    static let cpu = NSColor.systemBlue
    static let memory = NSColor.systemGreen
    static let gpu = NSColor.systemPurple

    /// 温度は値そのもので色を変える (低い=緑 → 高い=赤)
    static func temperatureColor(_ celsius: Double) -> NSColor {
        switch celsius {
        case ..<55: return .systemGreen
        case ..<70: return .systemYellow
        case ..<85: return .systemOrange
        default: return .systemRed
        }
    }

    /// 使用率のバーの色 (高負荷ほど赤に寄せる)
    static func loadColor(_ ratio: Double, base: NSColor) -> NSColor {
        switch ratio {
        case ..<0.7: return base
        case ..<0.9: return .systemOrange
        default: return .systemRed
        }
    }
}

enum Format {
    static func percent(_ ratio: Double) -> String {
        "\(Int((ratio * 100).rounded()))%"
    }

    static func celsius(_ value: Double) -> String {
        "\(Int(value.rounded()))°"
    }

    static func celsiusPrecise(_ value: Double) -> String {
        String(format: "%.1f °C", value)
    }

    /// 12.3 GB のように単位つきで返す
    static func bytes(_ value: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var amount = Double(value)
        var unit = 0
        while amount >= 1024, unit < units.count - 1 {
            amount /= 1024
            unit += 1
        }
        if unit <= 1 { return "\(Int(amount.rounded())) \(units[unit])" }
        return String(format: amount >= 100 ? "%.0f %@" : "%.1f %@", amount, units[unit])
    }
}

extension Color {
    init(_ nsColor: NSColor) { self.init(nsColor: nsColor) }
}
