import Cocoa
import Carbon.HIToolbox

// MARK: - 面板窗口（可成为 key，但不抢激活）

final class PanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - 屏幕边缘的提示条（可拖动定位 / 右键菜单）

final class HotZoneView: NSView {
    var onPress: (() -> Void)?
    var onDrag: ((NSPoint) -> Void)?
    var onRelease: ((NSPoint) -> Void)?
    var onMenu: ((NSEvent) -> Void)?

    private var pressPoint: NSPoint?
    private var didMove = false

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // 上下各留 1pt，做成贴边的胶囊，视觉上像一条"拉手"
        let r = bounds.insetBy(dx: 0, dy: 1)
        let radius = min(r.width, r.height) / 2
        let path = NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius)

        // 中性灰：浅色外观用深灰，深色外观用浅灰，两种壁纸下都能看见
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        NSColor(white: isDark ? 0.86 : 0.28, alpha: isHot ? 0.75 : 0.55).setFill()
        path.fill()

        // 1pt 反向描边，压出边界感
        NSColor(white: isDark ? 0.0 : 1.0, alpha: 0.22).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    /// 悬停/拖动时加深，给一点"可抓"的反馈
    private var isHot = false {
        didSet { if isHot != oldValue { needsDisplay = true } }
    }

    private func screenPoint(_ event: NSEvent) -> NSPoint {
        window?.convertPoint(toScreen: event.locationInWindow) ?? .zero
    }

    override func mouseDown(with event: NSEvent) {
        pressPoint = screenPoint(event)
        didMove = false
        isHot = true
        onPress?()
    }

    override func mouseDragged(with event: NSEvent) {
        let p = screenPoint(event)
        if let o = pressPoint, !didMove, hypot(p.x - o.x, p.y - o.y) > 2 {
            didMove = true
        }
        if didMove { onDrag?(p) }
    }

    override func mouseUp(with event: NSEvent) {
        let p = screenPoint(event)
        isHot = false
        onRelease?(p)
        pressPoint = nil
        didMove = false
    }

    override func rightMouseDown(with event: NSEvent) {
        onMenu?(event)
    }
}

/// 提示条窗口：不抢焦点，但能收到鼠标（用于拖动）
final class StripWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - 开机自启

enum LoginItem {
    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.tangbonze.edgetodo.plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func setEnabled(_ enabled: Bool) {
        if enabled {
            guard let exec = Bundle.main.executablePath else { return }
            let plist: [String: Any] = [
                "Label": "com.tangbonze.edgetodo",
                "ProgramArguments": [exec],
                "RunAtLoad": true,
                "KeepAlive": false
            ]
            do {
                try FileManager.default.createDirectory(
                    at: plistURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                try data.write(to: plistURL)
            } catch {
                NSLog("写入 LaunchAgent 失败: %@", error.localizedDescription)
            }
        } else {
            try? FileManager.default.removeItem(at: plistURL)
        }
    }
}

// MARK: - 热键回调

func edgeTodoHotKeyHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData = userData else { return noErr }
    let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
    DispatchQueue.main.async { delegate.togglePanel() }
    return noErr
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var panel: PanelWindow!
    private var hotWindows: [NSWindow] = []
    private var hotKeyRef: EventHotKeyRef?
    private var ticker: Timer?
    private var outsideSince: Date?
    private var lastHiddenAt = Date.distantPast
    private var suppressHover = false
    private var busy = false
    private var stripDragging = false
    private var stripEnteredAt: Date?
    /// 鼠标进入面板本体后，延时接管键盘（面板是非激活窗口，
    /// 不提前激活的话第一次点击会被系统拿去激活 App，到不了视图）
    private var enterActivateAt: Date?

    private let controller = PanelController()
    private let store = TodoStore.shared
    private let panelSize = NSSize(width: 380, height: 600)   // 玻璃卡片即窗口本身，阴影沿圆角走
    private let edgeStripWidth: CGFloat = 7
    private let edgeStripHeight: CGFloat = 52
    private let hideDelay: TimeInterval = 0.32
    private let hoverDwell: TimeInterval = 0.28     // 停在提示条上多久才弹出（留出拖动窗口）
    private let stripMargin: CGFloat = 24           // 提示条离屏幕上/下的最小距离

    private var side: String {
        get { UserDefaults.standard.string(forKey: "dockSide") ?? "right" }
        set { UserDefaults.standard.set(newValue, forKey: "dockSide") }
    }

    /// 提示条在边缘上的相对位置：0 = 最上，1 = 最下
    private var stripFraction: CGFloat {
        get {
            guard UserDefaults.standard.object(forKey: "stripFraction") != nil else { return 0.5 }
            return CGFloat(min(max(UserDefaults.standard.double(forKey: "stripFraction"), 0), 1))
        }
        set {
            UserDefaults.standard.set(Double(min(max(newValue, 0), 1)), forKey: "stripFraction")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if UserDefaults.standard.bool(forKey: "forceDark") {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        setupStatusItem()
        setupPanel()
        rebuildHotZones()
        registerHotKey()
        startHoverTicker()

        // 面板是非激活窗口：点一下先激活 App，右键菜单才弹得出来
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self = self else { return event }
            if event.window === self.panel, !NSApp.isActive {
                NSApp.activate(ignoringOtherApps: true)
                self.panel.makeKey()
            }
            return event
        }

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            if event.keyCode == 53, self.panel.isVisible {   // ESC
                if !self.controller.dismissEditorIfNeeded() {
                    self.hidePanel()
                }
                return nil
            }
            return event
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )

        // 开发用：启动即展开（配合 EDGETODO_DEMO 预览样式）
        if ProcessInfo.processInfo.environment["EDGETODO_SHOW"] != nil
            || UserDefaults.standard.bool(forKey: "showOnLaunch") {
            showPanel(focus: false)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// 点到别的 App 就收起（编辑提醒时保留）
    func applicationDidResignActive(_ notification: Notification) {
        if !busy { hidePanel() }
    }

    // MARK: 状态栏

    private var dockRightItem: NSMenuItem?
    private var dockLeftItem: NSMenuItem?
    private var loginMenuItem: NSMenuItem?

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "checklist", accessibilityDescription: "侧边待办")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "侧边待办（⌥⌘T）"
        }
        let menu = NSMenu()
        menu.delegate = self
        addItem(menu, "显示 / 隐藏", #selector(togglePanelAction))
        addItem(menu, "打开提醒事项", #selector(openReminders))
        addItem(menu, "重新加载", #selector(reloadAction))
        menu.addItem(.separator())
        dockRightItem = addItem(menu, "停靠在屏幕右侧", #selector(dockRight))
        dockLeftItem = addItem(menu, "停靠在屏幕左侧", #selector(dockLeft))
        addItem(menu, "提示条位置复位到中间", #selector(resetStripPosition))
        menu.addItem(.separator())
        loginMenuItem = addItem(menu, "开机自动启动", #selector(toggleLogin))
        menu.addItem(.separator())
        addItem(menu, "退出侧边待办", #selector(quit))
        statusItem.menu = menu
    }

    @discardableResult
    private func addItem(_ menu: NSMenu, _ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    func menuWillOpen(_ menu: NSMenu) {
        dockRightItem?.state = side == "right" ? .on : .off
        dockLeftItem?.state = side == "left" ? .on : .off
        loginMenuItem?.state = LoginItem.isEnabled ? .on : .off
    }

    @objc private func togglePanelAction() { togglePanel() }
    @objc private func openReminders() { store.openRemindersApp() }
    @objc private func reloadAction() { store.reload() }
    @objc private func dockRight() { side = "right"; rebuildHotZones() }
    @objc private func dockLeft() { side = "left"; rebuildHotZones() }
    @objc private func toggleLogin() { LoginItem.setEnabled(!LoginItem.isEnabled) }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func screensChanged() { rebuildHotZones() }

    @objc private func resetStripPosition() {
        stripFraction = 0.5
        rebuildHotZones()
    }

    // MARK: 面板

    private func setupPanel() {
        panel = PanelWindow(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.acceptsMouseMovedEvents = true

        controller.onRequestHide = { [weak self] in self?.hidePanel() }
        controller.onBusyChange = { [weak self] value in self?.busy = value }

        let container = NSView(frame: NSRect(origin: .zero, size: panelSize))
        container.autoresizingMask = [.width, .height]
        let view = controller.root
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        panel.contentView = container
        panel.setContentSize(panelSize)
    }

    private func targetScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        for screen in NSScreen.screens where NSMouseInRect(mouse, screen.frame, false) {
            return screen
        }
        return NSScreen.main ?? NSScreen.screens[0]
    }

    func togglePanel() {
        if panel.isVisible {
            if panel.frame.contains(NSEvent.mouseLocation) { suppressHover = true }
            hidePanel()
        } else {
            showPanel(focus: true)
        }
    }

    func showPanel(focus: Bool) {
        outsideSince = nil
        let screen = targetScreen()
        let vf = screen.visibleFrame
        let size = panelSize
        let isRight = side == "right"

        // 面板跟着提示条走：垂直居中对齐提示条，超出可视区再夹回来
        let strip = stripRect(for: screen)
        let wanted = strip.midY - size.height / 2
        let y = min(max(vf.minY + 12, wanted), vf.maxY - size.height - 12)
        let x = isRight ? vf.maxX - size.width : vf.minX
        let target = NSRect(x: x, y: y, width: size.width, height: size.height)

        if !panel.isVisible || panel.frame != target {
            panel.setFrame(target, display: true)
            panel.orderFrontRegardless()
        }
        panel.alphaValue = 1
        // 窗口透明、形状来自卡片圆角：布局完成后再重算一次阴影，
        // 否则可能沿用上一次的方形轮廓，在透明圆角处显出一块"方角"。
        panel.invalidateShadow()
        DispatchQueue.main.async { [weak panel] in panel?.invalidateShadow() }

        if focus {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.controller.focusInput()
            }
        }
        store.reload()
        setStripsVisible(false)   // 面板盖住拉手，别让它叠在玻璃上
    }

    /// 边缘拉手窗口的显隐（悬停判定靠轮询，不依赖窗口）
    /// 提前把键盘接过来。面板是非激活窗口，若不提前激活，
    /// 第一次点击只会用来激活 App，被系统吞掉，表现就是要连点两下。
    private func takeKeyboard() {
        enterActivateAt = nil
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKey()
        panel?.orderFrontRegardless()
    }

    private func setStripsVisible(_ visible: Bool) {
        for w in hotWindows {
            if visible { w.orderFrontRegardless() } else { w.orderOut(nil) }
        }
    }

    func hidePanel() {
        guard panel.isVisible else { return }
        outsideSince = nil
        enterActivateAt = nil
        busy = false
        if controller.isEditing { return }
        controller.cancelDraftIfNeeded()   // 收起时把没写完的草稿存下
        panel.makeFirstResponder(nil)
        panel.orderOut(nil)
        setStripsVisible(true)
        lastHiddenAt = Date()
    }

    // MARK: 边缘悬停检测（轮询鼠标位置，比 tracking area 稳定）

    private func startHoverTicker() {
        ticker?.invalidate()
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func stripRect(for screen: NSScreen) -> NSRect {
        let vf = screen.visibleFrame
        let h = min(edgeStripHeight, vf.height - 120)   // 热区长度 = 提示条长度
        let x = side == "right" ? vf.maxX - edgeStripWidth : vf.minX

        // 可拖动范围：上下各留 stripMargin
        let low = vf.minY + stripMargin
        let high = max(low, vf.maxY - h - stripMargin)
        let y = low + stripFraction * (high - low)
        return NSRect(x: x, y: y, width: edgeStripWidth, height: h)
    }

    /// 拖动时把屏幕坐标换算成新的相对位置
    private func setStripPosition(mouseY: CGFloat, on screen: NSScreen) {
        let vf = screen.visibleFrame
        let h = min(edgeStripHeight, vf.height - 120)
        let low = vf.minY + stripMargin
        let high = max(low, vf.maxY - h - stripMargin)
        guard high > low else { return }
        stripFraction = (mouseY - h / 2 - low) / (high - low)
    }

    private func tick() {
        guard let panel = panel else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let sc = screen else { return }
        let strip = stripRect(for: sc)

        if panel.isVisible {
            // 面板本身 + 边缘热区都算"仍在里面"，否则会隐藏又被热区立刻唤出
            if panel.frame.insetBy(dx: -1, dy: -1).contains(mouse) || strip.contains(mouse) {
                outsideSince = nil
                // 鼠标真的挪进面板本体（不是只停在拉手上）就准备接管键盘：
                // 悬停拉手 0.28s 才弹面板，再等 0.15s 才激活，快速划过不会抢焦点。
                let inBody = panel.frame.contains(mouse) && !strip.contains(mouse)
                if inBody, !NSApp.isActive {
                    if let at = enterActivateAt {
                        if Date() >= at { takeKeyboard() }
                    } else {
                        enterActivateAt = Date().addingTimeInterval(0.15)
                    }
                } else {
                    enterActivateAt = nil
                }
                return
            }
            enterActivateAt = nil
            if busy { return }                                 // 正在编辑提醒
            if UserDefaults.standard.bool(forKey: "freezeHover") { return }   // 截图调试用
            if panel.isKeyWindow && NSApp.isActive { return }   // 正在输入
            if let since = outsideSince {
                if Date().timeIntervalSince(since) >= hideDelay { hidePanel() }
            } else {
                outsideSince = Date()
            }
            return
        }

        if !strip.contains(mouse) {
            suppressHover = false
            stripEnteredAt = nil
            return
        }
        if stripDragging { stripEnteredAt = nil; return }   // 正在拖动提示条
        if suppressHover { return }
        if Date().timeIntervalSince(lastHiddenAt) < 0.25 { return }  // 刚收起，别马上又弹

        // 先停留一小会儿再弹，给拖动留出手感
        if let since = stripEnteredAt {
            if Date().timeIntervalSince(since) >= hoverDwell { showPanel(focus: false) }
        } else {
            stripEnteredAt = Date()
        }
    }

    // MARK: 边缘提示条

    private func rebuildHotZones() {
        hotWindows.forEach { $0.orderOut(nil) }
        hotWindows.removeAll()

        for screen in NSScreen.screens {
            let rect = stripRect(for: screen)
            let win = StripWindow(
                contentRect: rect,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            win.isOpaque = false
            win.backgroundColor = .clear
            win.hasShadow = false
            win.level = .statusBar
            win.isMovable = false
            win.isMovableByWindowBackground = false
            win.isReleasedWhenClosed = false
            win.hidesOnDeactivate = false
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
            win.setFrame(rect, display: true)

            let view = HotZoneView(frame: NSRect(origin: .zero, size: rect.size))
            view.wantsLayer = true
            view.onPress = { [weak self, weak win] in
                guard let self = self else { return }
                self.stripDragging = false
                self.stripEnteredAt = nil
                self.suppressHover = true
                if self.panel.isVisible { self.hidePanel() }
                _ = win
            }
            view.onDrag = { [weak self, weak win] point in
                guard let self = self, let win = win else { return }
                self.stripDragging = true
                guard let sc = win.screen ?? NSScreen.main else { return }
                self.setStripPosition(mouseY: point.y, on: sc)
                win.setFrame(self.stripRect(for: sc), display: true)
            }
            view.onRelease = { [weak self, weak win] _ in
                guard let self = self else { return }
                let moved = self.stripDragging
                self.stripDragging = false
                self.suppressHover = true
                self.stripEnteredAt = nil
                if let win = win, let sc = win.screen {
                    win.setFrame(self.stripRect(for: sc), display: true)
                }
                // 单纯点一下（没拖动）就直接打开面板
                if !moved { self.showPanel(focus: false) }
            }
            view.onMenu = { [weak self] event in
                guard let self = self, let v = event.window?.contentView else { return }
                self.showStripMenu(with: event, for: v)
            }

            win.contentView = view
            win.orderFrontRegardless()
            hotWindows.append(win)
        }

        // 提示条窗口重新建过之后，别把已展开的面板压住
        if panel.isVisible { panel.orderFrontRegardless() }
    }

    /// 右键提示条：切换左右边缘 / 复位
    private func showStripMenu(with event: NSEvent, for view: NSView) {
        suppressHover = true
        stripEnteredAt = nil

        let menu = NSMenu()
        let right = NSMenuItem(title: "停靠在屏幕右侧", action: #selector(dockRight), keyEquivalent: "")
        right.target = self
        right.state = side == "right" ? .on : .off
        menu.addItem(right)

        let left = NSMenuItem(title: "停靠在屏幕左侧", action: #selector(dockLeft), keyEquivalent: "")
        left.target = self
        left.state = side == "left" ? .on : .off
        menu.addItem(left)

        menu.addItem(.separator())
        let reset = NSMenuItem(title: "位置复位到中间", action: #selector(resetStripPosition), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)

        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    // MARK: 全局快捷键 ⌥⌘T

    private func registerHotKey() {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            edgeTodoHotKeyHandler,
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            nil
        )
        let hotKeyID = EventHotKeyID(signature: OSType(0x4554_4F44), id: 1)  // 'ETOD'
        RegisterEventHotKey(
            UInt32(kVK_ANSI_T),
            UInt32(cmdKey | optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }
}
