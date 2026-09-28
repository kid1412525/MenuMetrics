import Foundation
import Combine
import IOKit.ps

/// 全モニターを一定間隔で回して結果を配る。
/// 採取はバックグラウンドキュー、公開はメインスレッド。
final class MetricsEngine: ObservableObject {
    // MARK: - 詳細パネル (SwiftUI) が購読する値
    //
    // パネルを閉じている間は更新しない。閉じていても毎回更新すると、
    // 画面に出ていない SwiftUI ビューの再評価と観測の張り直しだけで
    // 1 コアの 30 % 近くを使ってしまう (実測)。
    @Published private(set) var snapshot = Snapshot()
    @Published private(set) var history = History()
    @Published private(set) var topCPU: [ProcessInfoRow] = []
    @Published private(set) var topMemory: [ProcessInfoRow] = []
    @Published private(set) var processCount = 0

    /// メニューバーへの通知。SwiftUI を通さず AppKit に直接渡す
    var onSample: ((Snapshot, History) -> Void)?

    /// 常に最新を保持する版。メニューバーはこちらを使う
    private var latest = Snapshot()
    private var latestHistory = History()

    /// ポップオーバーが開いている間だけプロセス一覧も採る
    var isDetailVisible = false {
        didSet {
            guard isDetailVisible != oldValue else { return }
            stateLock.lock()
            detailVisibleForSampling = isDetailVisible
            stateLock.unlock()
            if isDetailVisible {
                // 開いた瞬間は手持ちの最新値を流し込んでおく。
                // ここで即座に tick() すると直後のタイマー初回と連続し、
                // 差分が取れず CPU 0% / プロセス使用率が異常値になる。
                // プロセス一覧は前回開いたときの基準が古いので取り直し、
                // 少し間を空けてから最初の差分を取る。
                snapshot = latest
                history = latestHistory
                queue.async { [weak self] in _ = self?.processMonitor.sample() }
                applySchedule(initialDelay: 0.5)
            } else {
                applySchedule()
            }
        }
    }

    /// 誰も見ていないとき (画面が消えている、メニューバーが隠れている) は
    /// サンプリングそのものを止める
    var isVisible = true {
        didSet {
            guard isVisible != oldValue else { return }
            if isVisible {
                // 止まっていた間の差分は古すぎるので基準だけ取り直し、
                // すぐに最初の値を出す
                queue.async { [weak self] in _ = self?.cpuMonitor.sample() }
                applySchedule(initialDelay: 0.3)
            } else {
                applySchedule()
            }
        }
    }

    struct History {
        static let capacity = 60
        var cpu: [Double] = []
        var memory: [Double] = []
        var gpu: [Double] = []
        var temperature: [Double] = []

        mutating func append(_ snapshot: Snapshot) {
            Self.push(&cpu, snapshot.cpu.total)
            Self.push(&memory, snapshot.memory.usedRatio)
            Self.push(&gpu, snapshot.gpu.utilization)
            if let value = snapshot.thermal.headline { Self.push(&temperature, value) }
        }

        private static func push(_ array: inout [Double], _ value: Double) {
            array.append(value)
            if array.count > capacity { array.removeFirst(array.count - capacity) }
        }
    }

    private let cpuMonitor = CPUMonitor()
    private let memoryMonitor = MemoryMonitor()
    private let gpuMonitor = GPUMonitor()
    private let thermalMonitor = ThermalMonitor()
    private let processMonitor = ProcessMonitor()

    private let queue = DispatchQueue(label: "MenuMetrics.sampling", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var cancellables = Set<AnyCancellable>()
    private var isRunning = false
    /// 採取キューから isDetailVisible を読むための控え。
    /// 毎回メインスレッドに問い合わせると、そのたびに main を起こしてしまう
    private let stateLock = NSLock()
    private var detailVisibleForSampling = false

    init(settings: Settings = .shared) {
        settings.$interval
            .removeDuplicates()
            .sink { [weak self] _ in self?.applySchedule() }
            .store(in: &cancellables)

        // 低電力モードの切り替えに追従する
        NotificationCenter.default
            .publisher(for: NSNotification.Name.NSProcessInfoPowerStateDidChange)
            .sink { [weak self] _ in self?.applySchedule() }
            .store(in: &cancellables)
    }

    func start() {
        isRunning = true
        applySchedule()
    }

    func stop() {
        isRunning = false
        applySchedule()
    }

    // MARK: - 更新間隔

    /// 設定値に加えて、電源の状態で間隔を伸ばす。
    /// 低電力モード中や電池駆動中に毎秒起こす必要はない。
    private var effectiveInterval: Double {
        var interval = max(0.5, Settings.shared.interval)
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            interval = max(interval, 5)
        } else if !Self.isOnACPower {
            interval = max(interval, 3)
        }
        return interval
    }

    private static var isOnACPower: Bool {
        guard let type = IOPSGetProvidingPowerSourceType(nil)?.takeRetainedValue() as String? else { return true }
        return type == kIOPMACPowerKey
    }

    /// タイマーの生成と破棄はすべて採取キュー上で行う。
    /// メインスレッドから直接触ると、キュー側の代入と競合して
    /// 止めたはずのタイマーが動き続けることがある。
    private func applySchedule(initialDelay: Double = 0) {
        // パネルが開いているときは、隠れていても更新し続ける
        let shouldRun = isRunning && (isVisible || isDetailVisible)
        let interval = effectiveInterval

        queue.async { [weak self] in
            guard let self else { return }
            self.timer?.cancel()
            self.timer = nil
            guard shouldRun else { return }

            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            // leeway を大きく取ると、カーネルが他のタイマーと起床をまとめてくれる。
            // アイドルウェイクアップが減り、エネルギー影響度が下がる。
            let leeway = max(0.2, interval * 0.3)
            timer.schedule(deadline: .now() + initialDelay, repeating: interval, leeway: .milliseconds(Int(leeway * 1000)))
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
    }

    // MARK: - 採取

    private func tick() {
        stateLock.lock()
        let wantsProcesses = detailVisibleForSampling
        stateLock.unlock()

        var next = Snapshot()
        next.cpu = cpuMonitor.sample()
        next.memory = memoryMonitor.sample()
        next.gpu = gpuMonitor.sample()
        next.thermal = thermalMonitor.sample(detailed: wantsProcesses)
        next.date = Date()

        var cpuRows: [ProcessInfoRow] = []
        var memoryRows: [ProcessInfoRow] = []
        var total = 0
        if wantsProcesses {
            let rows = processMonitor.sample()
            total = rows.count
            cpuRows = processMonitor.topByCPU(rows)
            memoryRows = processMonitor.topByMemory(rows)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // 停止直後に走り終えた分は捨てる
            guard self.isRunning, self.isVisible || self.isDetailVisible else { return }
            self.latest = next
            self.latestHistory.append(next)
            // メニューバーは AppKit で直接描くので SwiftUI を起こさない
            self.onSample?(next, self.latestHistory)

            guard self.isDetailVisible else { return }
            self.snapshot = next
            self.history = self.latestHistory
            self.topCPU = cpuRows
            self.topMemory = memoryRows
            self.processCount = total
        }
    }
}
