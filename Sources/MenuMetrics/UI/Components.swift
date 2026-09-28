import SwiftUI

/// 単色の進捗バー
struct MeterBar: View {
    let ratio: Double
    let color: Color
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.09))
                Capsule()
                    .fill(color)
                    .frame(width: max(0, min(1, ratio)) * geometry.size.width)
            }
        }
        .frame(height: height)
    }
}

/// 内訳を積み上げて見せるバー (メモリの app / wired / compressed など)
struct StackedBar: View {
    struct Segment: Identifiable {
        let id = UUID()
        let ratio: Double
        let color: Color
    }

    let segments: [Segment]
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 1) {
                ForEach(segments) { segment in
                    Rectangle()
                        .fill(segment.color)
                        .frame(width: max(0, segment.ratio) * geometry.size.width)
                }
                Rectangle().fill(Color.primary.opacity(0.09))
            }
            .clipShape(Capsule())
        }
        .frame(height: height)
    }
}

/// セクションの見出し + 右肩の主要数値
struct SectionHeader: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
        }
    }
}

/// 「ラベル ……… 値」の 1 行
struct DetailRow: View {
    let label: String
    let value: String
    var color: Color = .primary
    var swatch: Color?

    var body: some View {
        HStack(spacing: 6) {
            if let swatch {
                RoundedRectangle(cornerRadius: 2)
                    .fill(swatch)
                    .frame(width: 7, height: 7)
            }
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(color)
        }
    }
}

/// コアごとの使用率を並べた小さなバーの列
struct CoreGrid: View {
    let cores: [Double]
    let efficiencyCount: Int

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(cores.enumerated()), id: \.offset) { index, value in
                let isEfficiency = index < efficiencyCount
                VStack(spacing: 2) {
                    GeometryReader { geometry in
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(Color(MetricStyle.loadColor(value, base: isEfficiency ? .systemTeal : .systemBlue)))
                                .frame(height: max(1.5, geometry.size.height * value))
                        }
                    }
                    .frame(height: 22)
                    .background(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.primary.opacity(0.08))
                            .frame(height: 22)
                    }
                    Text("\(index)")
                        .font(.system(size: 7))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

/// プロセス一覧の 1 行
struct ProcessRow: View {
    let row: ProcessInfoRow
    let trailing: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Text(row.name)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            Text(trailing)
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(color)
        }
    }
}
