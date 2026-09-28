import AppKit

/// メニューバーに描くビュー。
/// モジュール (CPU / メモリ / GPU / 温度) を横に並べ、
/// 「数値」スタイルは 2 行テキスト、「グラフ」スタイルは
/// スパークラインの上に数値を重ねて描く。
final class StatusItemView: NSView {
    struct Module {
        let label: String
        let value: String
        let ratio: Double
        let history: [Double]
        let color: NSColor
    }

    var modules: [Module] = [] {
        didSet {
            invalidateIntrinsicContentSize()
            // 描かれる内容が変わっていなければ描き直さない。
            // 余計な再描画は WindowServer まで巻き込んで電力を食う
            if Self.needsRedraw(from: oldValue, to: modules, style: style) {
                needsDisplay = true
            }
        }
    }

    private static func needsRedraw(from old: [Module], to new: [Module], style: Settings.Style) -> Bool {
        guard style == .compact else { return true }   // 折れ線は毎回変わる
        guard old.count == new.count else { return true }
        for (before, after) in zip(old, new) where before.label != after.label || before.value != after.value {
            return true
        }
        return false
    }

    var style: Settings.Style = .compact {
        didSet {
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    private let labelFont = NSFont.systemFont(ofSize: 7.5, weight: .medium)
    private let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
    private let spacing: CGFloat = 7
    private let horizontalInset: CGFloat = 5

    override var intrinsicContentSize: NSSize {
        NSSize(width: totalWidth, height: NSStatusBar.system.thickness)
    }

    private var moduleWidths: [CGFloat] {
        modules.map { module in
            switch style {
            case .compact:
                let label = module.label.size(withAttributes: [.font: labelFont]).width
                let value = module.value.size(withAttributes: [.font: valueFont]).width
                return max(22, ceil(max(label, value)))
            case .graph:
                return 34
            }
        }
    }

    private var totalWidth: CGFloat {
        let widths = moduleWidths
        guard !widths.isEmpty else { return 24 }
        return widths.reduce(0, +) + spacing * CGFloat(widths.count - 1) + horizontalInset * 2
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !modules.isEmpty else {
            drawPlaceholder()
            return
        }
        var x = horizontalInset
        for (module, width) in zip(modules, moduleWidths) {
            let rect = NSRect(x: x, y: 0, width: width, height: bounds.height)
            switch style {
            case .compact: drawCompact(module, in: rect)
            case .graph: drawGraph(module, in: rect)
            }
            x += width + spacing
        }
    }

    private func drawPlaceholder() {
        let text = NSAttributedString(string: "—", attributes: [
            .font: valueFont, .foregroundColor: NSColor.labelColor,
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }

    // MARK: - 数値スタイル

    private func drawCompact(_ module: Module, in rect: NSRect) {
        let label = NSAttributedString(string: module.label, attributes: [
            .font: labelFont, .foregroundColor: NSColor.labelColor.withAlphaComponent(0.62),
        ])
        let value = NSAttributedString(string: module.value, attributes: [
            .font: valueFont, .foregroundColor: NSColor.labelColor,
        ])
        // 上段にラベル、下段に数値。メニューバーの高さに合わせて上下中央に寄せる
        let labelSize = label.size()
        let valueSize = value.size()
        let block = labelSize.height + valueSize.height - 1
        let top = rect.midY + block / 2

        label.draw(at: NSPoint(x: rect.midX - labelSize.width / 2, y: top - labelSize.height))
        value.draw(at: NSPoint(x: rect.midX - valueSize.width / 2, y: top - block))
    }

    // MARK: - グラフスタイル

    private func drawGraph(_ module: Module, in rect: NSRect) {
        drawSparkline(module, in: rect.insetBy(dx: 0, dy: 2.5))

        // 折れ線の上に数値を重ねるので、縁取りをつけて可読性を確保する
        let outline = NSShadow()
        outline.shadowColor = menuBarIsDark ? NSColor.black.withAlphaComponent(0.9) : NSColor.white.withAlphaComponent(0.9)
        outline.shadowBlurRadius = 3
        outline.shadowOffset = .zero

        let value = NSAttributedString(string: module.value, attributes: [
            .font: valueFont,
            .foregroundColor: NSColor.labelColor,
            .shadow: outline,
        ])
        let size = value.size()
        let origin = NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
        // 2 回重ねて縁取りを濃くする
        value.draw(at: origin)
        value.draw(at: origin)
    }

    private var menuBarIsDark: Bool {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private func drawSparkline(_ module: Module, in rect: NSRect) {
        let points = module.history
        guard points.count > 1 else {
            module.color.withAlphaComponent(0.25).setFill()
            NSBezierPath(rect: NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(1, rect.height * module.ratio))).fill()
            return
        }

        // サンプルが少ないうちも幅いっぱいに引き伸ばす
        let step = rect.width / CGFloat(points.count - 1)

        let lower = points.min() ?? 0
        let upper = points.max() ?? 1
        // 使用率は 0..100% 固定。温度のようにそれ以外の系列は自動スケールする
        let isRatio = upper <= 1.0001 && lower >= 0
        var minValue = 0.0
        var maxValue = 1.0
        if !isRatio {
            // 幅を最低 10 度は確保する。そうしないと 0.5 度の揺らぎが山に見えてしまう
            let span = max(upper - lower, 10)
            let center = (upper + lower) / 2
            minValue = center - span / 2
            maxValue = center + span / 2
        }

        func position(_ index: Int) -> NSPoint {
            let normalized = (points[index] - minValue) / (maxValue - minValue)
            return NSPoint(x: rect.minX + step * CGFloat(index),
                           y: rect.minY + rect.height * CGFloat(min(1, max(0, normalized))))
        }

        let line = NSBezierPath()
        line.move(to: position(0))
        for index in points.indices.dropFirst() { line.line(to: position(index)) }
        line.lineWidth = 1.3
        line.lineJoinStyle = .round
        module.color.setStroke()
        line.stroke()
    }
}
