import AppKit
import SwiftUI
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let engine = MetricsEngine()
    private let settings = Settings.shared

    private var statusItem: NSStatusItem!
    private let statusView = StatusItemView()
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        setUpPopover()

        // メニューバーの更新は SwiftUI を経由しない。
        // ObservableObject 経由にすると、閉じている詳細パネルまで
        // 毎回再評価されてしまう
        engine.onSample = { [weak self] snapshot, history in
            self?.updateStatusView(snapshot: snapshot, history: history)
        }
        observeVisibility()

        // 表示設定を変えたら即座に反映する
        settings.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                guard let self else { return }
                self.statusView.style = self.settings.style
                self.updateStatusView(snapshot: self.engine.snapshot, history: self.engine.history)
            }
            .store(in: &cancellables)

        engine.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.stop()
    }

    // MARK: - メニューバー

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }

        statusView.style = settings.style
        statusView.frame = button.bounds
        statusView.autoresizingMask = [.width, .height]
        button.addSubview(statusView)

        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "システムモニタ"
    }

    private func updateStatusView(snapshot: Snapshot, history: MetricsEngine.History) {
        var modules: [StatusItemView.Module] = []

        if settings.showCPU {
            modules.append(.init(
                label: "CPU",
                value: Format.percent(snapshot.cpu.total),
                ratio: snapshot.cpu.total,
                history: history.cpu,
                color: MetricStyle.cpu
            ))
        }
        if settings.showMemory {
            modules.append(.init(
                label: "MEM",
                value: Format.percent(snapshot.memory.usedRatio),
                ratio: snapshot.memory.usedRatio,
                history: history.memory,
                color: MetricStyle.memory
            ))
        }
        if settings.showGPU && snapshot.gpu.available {
            modules.append(.init(
                label: "GPU",
                value: Format.percent(snapshot.gpu.utilization),
                ratio: snapshot.gpu.utilization,
                history: history.gpu,
                color: MetricStyle.gpu
            ))
        }
        if settings.showTemperature, let temperature = snapshot.thermal.headline {
            modules.append(.init(
                label: "TEMP",
                value: Format.celsius(temperature),
                ratio: min(1, max(0, (temperature - 30) / 70)),
                history: history.temperature,
                color: MetricStyle.temperatureColor(temperature)
            ))
        }

        statusView.modules = modules
        // 表示項目が増減すると幅が変わるので追従させる
        let width = statusView.intrinsicContentSize.width
        if abs(statusItem.length - width) > 0.5 { statusItem.length = width }
        if let button = statusItem.button, statusView.frame != button.bounds {
            statusView.frame = button.bounds
        }
    }

    // MARK: - クリック

    @objc private func statusItemClicked() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func setUpPopover() {
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        // 初回表示のちらつきを抑えるための暫定サイズ。
        // 実際の高さは DetailView が中身を測って返してくる
        popover.contentSize = NSSize(width: 340, height: 700)
    }

    /// 中身は一度も開かれなければ作らない。
    /// SwiftUI のビュー階層は、画面に出ていなくても持っているだけで
    /// 観測のコストがかかるため
    private func makePopoverContentIfNeeded() {
        guard popover.contentViewController == nil else { return }
        popover.contentViewController = NSHostingController(
            rootView: DetailView(
                engine: engine,
                onQuit: { NSApp.terminate(nil) },
                onIdealHeightChange: { [weak self] height in
                    self?.resizePopover(to: height)
                }
            )
        )
    }

    // MARK: - 表示状態の監視

    /// メニューバーが隠れている (フルスクリーンなど) / 画面が消えている間は
    /// 誰も数字を見ていないので、サンプリングごと止める
    private func observeVisibility() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeOcclusionStateNotification,
            object: NSApp, queue: .main
        ) { [weak self] _ in self?.updateVisibility() }
        // メニューバーの項目そのものが見えているかを見る
        NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let self, notification.object as? NSWindow === self.statusItem.button?.window else { return }
            self.updateVisibility()
        }

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.willSleepNotification,
            NSWorkspace.didWakeNotification,
        ] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.updateVisibility()
            }
        }
        updateVisibility()
    }

    /// NSApp.occlusionState はアプリの全ウィンドウをまとめた値で、
    /// メニューバーにしか出ないアプリだとデスクトップ表示中などに
    /// 「見えていない」と判定され、更新が止まってしまうことがある。
    /// 実際に数字を出しているステータス項目のウィンドウで判定する。
    private func updateVisibility() {
        let visible: Bool
        if let window = statusItem.button?.window {
            visible = window.occlusionState.contains(.visible)
        } else {
            visible = NSApp.occlusionState.contains(.visible)
        }
        engine.isVisible = visible
    }

    /// 中身の高さに合わせてポップオーバーを伸縮させる。
    /// 高さを固定にすると、内容が多いときに行が途中で切れて見えてしまう。
    private func resizePopover(to height: CGFloat) {
        let size = NSSize(width: 340, height: ceil(height))
        guard abs(popover.contentSize.height - size.height) > 1 else { return }
        popover.contentSize = size
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem.button else { return }
        makePopoverContentIfNeeded()
        engine.isDetailVisible = true
        // Dock に出ないアプリなので、明示的に前面に出さないとパネル内の操作が効かない
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidClose(_ notification: Notification) {
        engine.isDetailVisible = false
    }

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "詳細を開く", action: #selector(togglePopoverFromMenu), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())

        let styleItem = NSMenuItem(title: "グラフ表示", action: #selector(toggleStyle), keyEquivalent: "")
        styleItem.target = self
        styleItem.state = settings.style == .graph ? .on : .off
        menu.addItem(styleItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "アクティビティモニタを開く", action: #selector(openActivityMonitor), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "終了", action: #selector(quit), keyEquivalent: "q").target = self

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        // メニューを出しっぱなしにすると左クリックが効かなくなるので外す
        statusItem.menu = nil
    }

    @objc private func togglePopoverFromMenu() { togglePopover() }

    @objc private func toggleStyle() {
        settings.style = settings.style == .graph ? .compact : .graph
    }

    @objc private func openActivityMonitor() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
