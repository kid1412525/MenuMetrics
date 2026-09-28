import SwiftUI

/// メニューバーをクリックしたときに開くパネル。
struct DetailView: View {
    @ObservedObject var engine: MetricsEngine
    @ObservedObject var settings = Settings.shared

    @State private var processSort: ProcessSort = .cpu
    @State private var showingSettings = false
    @State private var loginItemEnabled = LoginItem.isEnabled
    @State private var loginItemError: String?

    enum ProcessSort: String, CaseIterable {
        case cpu = "CPU"
        case memory = "メモリ"
    }

    private let coreLayout = CoreLayout()
    var onQuit: () -> Void = { NSApp.terminate(nil) }
    /// パネルの高さの上限。既定では画面に収まる範囲まで伸ばす
    var maxPanelHeight: CGFloat = DetailView.screenLimit
    /// 中身に必要な高さを親 (ポップオーバー) に伝える。
    /// SwiftUI 側で高さを決めるとポップオーバーが最小サイズに潰れるため、
    /// 実測した高さを AppKit 側に返してポップオーバーのサイズを更新する。
    var onIdealHeightChange: (CGFloat) -> Void = { _ in }

    @State private var contentHeight: CGFloat = 0
    @State private var chromeHeight: CGFloat = 0

    /// スクロールする中身の高さ
    private struct ContentHeightKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }

    /// ヘッダー・フッター・設定パネルの高さ (複数あるので合計する)
    fileprivate struct ChromeHeightKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value += nextValue()
        }
    }

    /// ポップオーバーはメニューバーの下から出るので、そこから画面下端までが上限
    private static var screenLimit: CGFloat {
        guard let screen = NSScreen.main else { return 620 }
        return max(320, screen.visibleFrame.height - 24)
    }

    var body: some View {
        VStack(spacing: 0) {
            header.measuredChrome()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 11) {
                    cpuSection
                    memorySection
                    if engine.snapshot.gpu.available { gpuSection }
                    if engine.snapshot.thermal.available { thermalSection }
                    processSection
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
                    }
                )
            }
            Divider()
            footer.measuredChrome()
            if showingSettings {
                Divider()
                settingsPanel.measuredChrome()
            }
        }
        .frame(width: 340)
        .onPreferenceChange(ContentHeightKey.self) { height in
            contentHeight = height
            reportIdealHeight(content: height, chrome: chromeHeight)
        }
        .onPreferenceChange(ChromeHeightKey.self) { height in
            chromeHeight = height
            reportIdealHeight(content: contentHeight, chrome: height)
        }
    }

    private func reportIdealHeight(content: CGFloat, chrome: CGFloat) {
        guard content > 0, chrome > 0 else { return }
        // 区切り線 3 本分を足して、画面に収まる高さで頭打ちにする
        onIdealHeightChange(min(content + chrome + 3, maxPanelHeight))
    }

    // MARK: - ヘッダー

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(MetricStyle.cpu))
            VStack(alignment: .leading, spacing: 1) {
                Text(Self.machineName)
                    .font(.system(size: 12, weight: .semibold))
                Text(Self.coreSummary)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if engine.snapshot.thermal.state != .nominal {
                Label(Self.thermalStateLabel(engine.snapshot.thermal.state), systemImage: "thermometer.high")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - CPU

    private var cpuSection: some View {
        let cpu = engine.snapshot.cpu
        return VStack(alignment: .leading, spacing: 5) {
            SectionHeader(title: "CPU", value: Format.percent(cpu.total), color: Color(MetricStyle.loadColor(cpu.total, base: MetricStyle.cpu)))
            MeterBar(ratio: cpu.total, color: Color(MetricStyle.loadColor(cpu.total, base: MetricStyle.cpu)))
            DetailRow(label: "ユーザー", value: Format.percent(cpu.user), swatch: Color(MetricStyle.cpu))
            DetailRow(label: "システム", value: Format.percent(cpu.system), swatch: Color(.systemIndigo))
            if coreLayout.isHeterogeneous {
                DetailRow(label: "高性能コア (\(coreLayout.performanceCount))", value: Format.percent(cpu.performance), swatch: Color(.systemBlue))
                DetailRow(label: "高効率コア (\(coreLayout.efficiencyCount))", value: Format.percent(cpu.efficiency), swatch: Color(.systemTeal))
            }
            if !cpu.perCore.isEmpty {
                CoreGrid(cores: cpu.perCore, efficiencyCount: coreLayout.efficiencyCount)
                    .padding(.top, 2)
            }
            DetailRow(label: "ロードアベレージ", value: cpu.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: "  "))
        }
    }

    // MARK: - メモリ

    private var memorySection: some View {
        let memory = engine.snapshot.memory
        let total = Double(max(1, memory.total))
        return VStack(alignment: .leading, spacing: 5) {
            SectionHeader(title: "メモリ", value: Format.percent(memory.usedRatio), color: Color(MetricStyle.loadColor(memory.usedRatio, base: MetricStyle.memory)))
            StackedBar(segments: [
                .init(ratio: Double(memory.app) / total, color: Color(.systemGreen)),
                .init(ratio: Double(memory.wired) / total, color: Color(.systemMint)),
                .init(ratio: Double(memory.compressed) / total, color: Color(.systemYellow)),
                .init(ratio: Double(memory.cached) / total, color: Color(.systemGray).opacity(0.5)),
            ])
            DetailRow(label: "アプリメモリ", value: Format.bytes(memory.app), swatch: Color(.systemGreen))
            DetailRow(label: "確保済みメモリ", value: Format.bytes(memory.wired), swatch: Color(.systemMint))
            DetailRow(label: "圧縮", value: Format.bytes(memory.compressed), swatch: Color(.systemYellow))
            DetailRow(label: "キャッシュファイル", value: Format.bytes(memory.cached), swatch: Color(.systemGray).opacity(0.5))
            DetailRow(label: "使用済み / 合計", value: "\(Format.bytes(memory.used)) / \(Format.bytes(memory.total))")
            DetailRow(label: "スワップ", value: memory.swapTotal == 0 ? "なし" : "\(Format.bytes(memory.swapUsed)) / \(Format.bytes(memory.swapTotal))")
            DetailRow(label: "メモリ圧力", value: Self.pressureLabel(memory.pressureLevel), color: Self.pressureColor(memory.pressureLevel))
        }
    }

    // MARK: - GPU

    private var gpuSection: some View {
        let gpu = engine.snapshot.gpu
        return VStack(alignment: .leading, spacing: 5) {
            SectionHeader(title: "GPU", value: Format.percent(gpu.utilization), color: Color(MetricStyle.loadColor(gpu.utilization, base: MetricStyle.gpu)))
            MeterBar(ratio: gpu.utilization, color: Color(MetricStyle.loadColor(gpu.utilization, base: MetricStyle.gpu)))
            DetailRow(label: "デバイス", value: gpu.name)
            DetailRow(label: "レンダラー", value: Format.percent(gpu.rendererUtilization), swatch: Color(.systemPurple))
            DetailRow(label: "タイラー", value: Format.percent(gpu.tilerUtilization), swatch: Color(.systemPink))
            DetailRow(
                label: "メモリ (使用中 / 確保済み)",
                value: "\(Format.bytes(gpu.inUseMemory)) / \(Format.bytes(gpu.allocatedMemory))"
            )
        }
    }

    // MARK: - 温度

    private var thermalSection: some View {
        let thermal = engine.snapshot.thermal
        return VStack(alignment: .leading, spacing: 5) {
            SectionHeader(
                title: "温度",
                value: thermal.headline.map { Format.celsiusPrecise($0) } ?? "—",
                color: Color(MetricStyle.temperatureColor(thermal.headline ?? 0))
            )
            if let average = thermal.cpuAverage {
                MeterBar(ratio: min(1, max(0, (average - 30) / 70)), color: Color(MetricStyle.temperatureColor(average)))
                let peak = thermal.cpuMax ?? average
                DetailRow(
                    label: "SoC ダイ (平均 / 最高)",
                    value: "\(Format.celsiusPrecise(average)) / \(Format.celsiusPrecise(peak))",
                    color: Color(MetricStyle.temperatureColor(peak))
                )
            }
            if let gpu = thermal.gpuAverage {
                DetailRow(label: "GPU 付近 (推定)", value: Format.celsiusPrecise(gpu), color: Color(MetricStyle.temperatureColor(gpu)))
            }
            if let ssd = thermal.ssdTemperature {
                DetailRow(label: "SSD", value: Format.celsiusPrecise(ssd))
            }
            if let battery = thermal.batteryTemperature {
                DetailRow(label: "バッテリー", value: Format.celsiusPrecise(battery))
            }
            DetailRow(label: "サーマル状態", value: Self.thermalStateLabel(thermal.state))
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(thermal.sensors.prefix(24), id: \.name) { sensor in
                        DetailRow(label: sensor.name, value: Format.celsiusPrecise(sensor.value))
                    }
                }
                .padding(.top, 4)
            } label: {
                Text("センサー一覧 (\(thermal.sensors.count))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - プロセス

    private var processSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("プロセス")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $processSort) {
                    ForEach(ProcessSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 120)
            }
            let rows = processSort == .cpu ? engine.topCPU : engine.topMemory
            if rows.isEmpty {
                Text("収集中…")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(rows) { row in
                    ProcessRow(
                        row: row,
                        trailing: processSort == .cpu ? String(format: "%.1f%%", row.cpu) : Format.bytes(row.memory),
                        color: processSort == .cpu ? Color(MetricStyle.cpu) : Color(MetricStyle.memory)
                    )
                }
            }
            Text("読み取れたプロセス: \(engine.processCount) 件 · 他ユーザー所有は権限上非表示")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - フッターと設定

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                showingSettings.toggle()
            } label: {
                Label("設定", systemImage: "gearshape")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)

            Button {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
            } label: {
                Label("アクティビティモニタ", systemImage: "arrow.up.forward.app")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)

            Spacer()

            Button(action: onQuit) {
                Label("終了", systemImage: "power")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("更新間隔").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $settings.interval) {
                    Text("1 秒").tag(1.0)
                    Text("2 秒").tag(2.0)
                    Text("3 秒").tag(3.0)
                    Text("5 秒").tag(5.0)
                }
                .labelsHidden()
                .frame(width: 90)
            }
            HStack {
                Text("表示").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $settings.style) {
                    ForEach(Settings.Style.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 120)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("メニューバーに表示する項目").font(.system(size: 11)).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Toggle("CPU", isOn: $settings.showCPU)
                    Toggle("メモリ", isOn: $settings.showMemory)
                    Toggle("GPU", isOn: $settings.showGPU)
                    Toggle("温度", isOn: $settings.showTemperature)
                }
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
            }
            Toggle("ログイン時に起動", isOn: Binding(
                get: { loginItemEnabled },
                set: { newValue in
                    loginItemError = LoginItem.set(newValue)
                    loginItemEnabled = LoginItem.isEnabled
                }
            ))
            .toggleStyle(.checkbox)
            .font(.system(size: 11))
            if let loginItemError {
                Text(loginItemError)
                    .font(.system(size: 9))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
    }

    // MARK: - 表示用の変換

    private static var machineName: String {
        CoreLayout.sysctlString("machdep.cpu.brand_string") ?? CoreLayout.sysctlString("hw.model") ?? "Mac"
    }

    private static var coreSummary: String {
        let layout = CoreLayout()
        let memory = (CoreLayout.sysctlInt("hw.memsize") ?? 0)
        let memoryText = Format.bytes(UInt64(memory))
        guard layout.isHeterogeneous else {
            return "\(CoreLayout.sysctlInt("hw.ncpu") ?? 0) コア · \(memoryText)"
        }
        return "\(layout.performanceCount)P + \(layout.efficiencyCount)E コア · \(memoryText)"
    }

    private static func pressureLabel(_ level: Int) -> String {
        switch level {
        case 4: return "逼迫"
        case 2: return "警告"
        default: return "正常"
        }
    }

    private static func pressureColor(_ level: Int) -> Color {
        switch level {
        case 4: return .red
        case 2: return .orange
        default: return .primary
        }
    }

    private static func thermalStateLabel(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "正常"
        case .fair: return "やや高い"
        case .serious: return "高い"
        case .critical: return "危険"
        @unknown default: return "不明"
        }
    }
}

private extension View {
    /// スクロールしない部分 (ヘッダー・フッター・設定) の高さを報告する
    func measuredChrome() -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(key: DetailView.ChromeHeightKey.self, value: proxy.size.height)
            }
        )
    }
}
