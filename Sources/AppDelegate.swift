import AppKit
import SwiftUI

/// 可以成为 key window 的无边框面板（borderless NSPanel 默认不能成为 key，
/// 不子类化的话滑块交互和 Esc 关闭会不正常）。
final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private lazy var panel: NSPanel = {
        let panel = KeyablePanel(contentRect: .zero,
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered,
                                 defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentViewController = NSHostingController(rootView: PanelView(model: model))
        return panel
    }()
    private lazy var model = PanelModel()
    private var eventMonitors: [Any] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 先清理上次异常退出可能遗留的聚合设备，再初始化面板
        AudioDeviceManager.shared.cleanupStaleAggregates()
        _ = model

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "hifispeaker.2",
                                   accessibilityDescription: "MultiOut 多设备同播")
            button.target = self
            button.action = #selector(togglePanel(_:))
        }
        statusItem = item

        // 隐藏调试入口：./MultiOut --debug-show 启动后自动弹出面板，便于截图验证位置
        if CommandLine.arguments.contains("--debug-show") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.showPanel()
            }
        }
    }

    @objc private func togglePanel(_ sender: AnyObject?) {
        if panel.isVisible { hidePanel() } else { showPanel() }
    }

    private func showPanel() {
        guard let button = statusItem?.button, let buttonWindow = button.window else { return }
        model.refresh()

        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let contentSize = panel.contentViewController?.view.fittingSize ?? NSSize(width: 380, height: 240)
        panel.setContentSize(contentSize)

        var originX = buttonFrame.midX - contentSize.width / 2
        if let screen = buttonWindow.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            originX = min(max(originX, visible.minX + 4), visible.maxX - contentSize.width - 4)
        }
        // 面板顶边固定在菜单栏图标底边之下，永远不会盖住菜单栏
        panel.setFrameTopLeftPoint(NSPoint(x: originX, y: buttonFrame.minY - 6))
        panel.makeKeyAndOrderFront(nil)
        installMonitorsIfNeeded()
    }

    private func hidePanel() {
        panel.orderOut(nil)
        removeMonitors()
    }

    private func installMonitorsIfNeeded() {
        guard eventMonitors.isEmpty else { return }
        // 点击面板外任意位置关闭
        eventMonitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hidePanel()
        } as Any)
        eventMonitors.append(NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.panel.isVisible else { return event }
            // 状态栏图标上的点击交给按钮自己的 action 处理开关，这里跳过避免“关了又开”
            let isStatusBarClick = event.window === self.statusItem?.button?.window
            if !isStatusBarClick && event.window !== self.panel {
                self.hidePanel()
            }
            return event
        } as Any)
        // Esc 关闭
        eventMonitors.append(NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isVisible, event.keyCode == 53 else { return event }
            self.hidePanel()
            return nil
        } as Any)
    }

    private func removeMonitors() {
        eventMonitors.forEach { NSEvent.removeMonitor($0) }
        eventMonitors.removeAll()
    }

    func applicationWillTerminate(_ notification: Notification) {
        removeMonitors()
        model.shutdown()
    }
}
