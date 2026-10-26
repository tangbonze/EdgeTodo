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

// MARK: - 显示器标识

extension NSScreen {
    /// 稳定的显示器标识：优先用 ColorSync 的 UUID，拔插、重启、换坞站之后
    /// 仍然能对上同一台显示器；拿不到时退回 displayID，最后退回名字。
    var displayUUID: String {
        let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        if let displayID = number?.uint32Value,
           let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() {
            return (CFUUIDCreateString(nil, uuid) as String).uppercased()
        }
        if let displayID = number?.uint32Value { return "display-\(displayID)" }
        return "name-\(localizedName)"
    }
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
    /// 提示条窗口，按显示器 UUID 索引：一块屏幕一条，互不干扰
    private var stripWindows: [String: StripWindow] = [:]
    /// 当前面板所在的屏幕；「从哪里激活就在哪里显示」靠它记住来源
    private var activeScreen: NSScreen?
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

    private var controller = PanelController()
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

    /// 不显示提示条的显示器（UUID）。空集合 = 所有显示器都显示，
    /// 这样新插上的显示器默认就是可见的，不用额外配置。
    private var hiddenDisplays: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "hiddenDisplays") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "hiddenDisplays") }
    }

    /// 真正要显示提示条的屏幕
    private var visibleScreens: [NSScreen] {
        let hidden = hiddenDisplays
        let screens = NSScreen.screens.filter { !hidden.contains($0.displayUUID) }
        return screens.isEmpty ? NSScreen.screens : screens   // 保底：至少留一块
    }

    /// 提示条在边缘上的相对位置：0 = 最下，1 = 最上（每块屏幕各存一份）
    /// 注意 NSScreen 的 y 轴向上，所以数值越大越靠上
    private func stripFraction(for screen: NSScreen) -> CGFloat {
        let key = "stripFraction." + screen.displayUUID
        let store = UserDefaults.standard
        if store.object(forKey: key) != nil {
            return CGFloat(min(max(store.double(forKey: key), 0), 1))
        }
        // 老版本只有一个全局值，迁移时沿用它
        if store.object(forKey: "stripFraction") != nil {
            return CGFloat(min(max(store.double(forKey: "stripFraction"), 0), 1))
        }
        return 0.5
    }

    private func setStripFraction(_ value: CGFloat, for screen: NSScreen) {
        UserDefaults.standard.set(
            Double(min(max(value, 0), 1)),
            forKey: "stripFraction." + screen.displayUUID
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if UserDefaults.standard.bool(forKey: "forceDark") {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        setupStatusItem()
        setupPanel()
        activeScreen = targetScreen()
        // 上次退出时若有显示器没接上，这里把它的记录清掉
        let live = Set(NSScreen.screens.map { $0.displayUUID })
        let pruned = hiddenDisplays.intersection(live)
        if pruned != hiddenDisplays { hiddenDisplays = pruned }
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

        // 开发用：把当前界面的文案全部打到 stderr，用来核对英文翻译有没有漏（EDGETODO_DUMP=1）
        if ProcessInfo.processInfo.environment["EDGETODO_DUMP"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.dumpUIStrings()
            }
        }
    }

    /// 遍历面板视图树，把文字打出来（调试用）
    private func dumpUIStrings() {
        var lines: [String] = []
        func walk(_ view: NSView, _ depth: Int) {
            let pad = String(repeating: "  ", count: depth)
            if let field = view as? NSTextField, !field.stringValue.isEmpty {
                let hint = field.placeholderString.map { "  [placeholder: \($0)]" } ?? ""
                lines.append("\(pad)text: \(field.stringValue)\(hint)")
            } else if let button = view as? NSButton, !button.title.isEmpty {
                lines.append("\(pad)btn: \(button.title)")
            }
            for sub in view.subviews { walk(sub, depth + 1) }
        }
        walk(controller.root, 0)
        if let button = statusItem.button, let win = button.window {
            let f = win.frame
            // 菜单栏项的屏幕位置，方便自动化点击
            let cgY = (win.screen?.frame.maxY ?? 0) - f.maxY
            lines.append("--- statusitem: NS(\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width)),\(Int(f.height))) CG(\(Int(f.midX)),\(Int(cgY + f.height / 2))) ---")
        }
        if let menu = statusItem.menu {
            lines.append("--- menu ---")
            for item in menu.items {
                if item.isSeparatorItem { lines.append("  ---"); continue }
                lines.append("  \(item.title)")
                if let sub = item.submenu {
                    for child in sub.items where !child.isSeparatorItem {
                        lines.append("    \(child.title)")
                    }
                }
            }
        }
        FileHandle.standardError.write(
            ("--- UI strings (" + (L10n.isEnglish ? "en" : "zh") + ") ---\n" + lines.joined(separator: "\n") + "\n--- end ---\n")
                .data(using: .utf8)!
        )
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
    private var displayMenuItem: NSMenuItem?
    private var languageMenuItem: NSMenuItem?

    private func setupStatusItem() {
        if let old = statusItem {
            NSStatusBar.system.removeStatusItem(old)   // 切语言时重建，旧的要摘掉
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = NSImage(
                systemSymbolName: "checklist",
                accessibilityDescription: L10n.t("侧边待办", "EdgeTodo")
            )
            image?.isTemplate = true
            button.image = image
            button.toolTip = L10n.t("侧边待办（⌥⌘T）", "EdgeTodo (⌥⌘T)")
        }
        let menu = NSMenu()
        menu.delegate = self
        addItem(menu, L10n.t("显示 / 隐藏", "Show / Hide"), #selector(togglePanelAction))
        addItem(menu, L10n.t("打开提醒事项", "Open Reminders"), #selector(openReminders))
        addItem(menu, L10n.t("重新加载", "Reload"), #selector(reloadAction))
        menu.addItem(.separator())
        dockRightItem = addItem(menu, L10n.t("停靠在屏幕右侧", "Dock to Right Edge"), #selector(dockRight))
        dockLeftItem = addItem(menu, L10n.t("停靠在屏幕左侧", "Dock to Left Edge"), #selector(dockLeft))
        let displayItem = NSMenuItem(
            title: L10n.t("提示条显示在", "Strip Shown On"), action: nil, keyEquivalent: ""
        )
        displayItem.submenu = NSMenu()
        menu.addItem(displayItem)
        displayMenuItem = displayItem
        addItem(menu, L10n.t("提示条位置复位到中间", "Reset Strip Position"), #selector(resetStripPosition))
        menu.addItem(.separator())
        loginMenuItem = addItem(menu, L10n.t("开机自动启动", "Launch at Login"), #selector(toggleLogin))
        menu.addItem(.separator())
        let languageItem = NSMenuItem(
            title: L10n.t("语言", "Language"), action: nil, keyEquivalent: ""
        )
        languageItem.submenu = NSMenu()
        menu.addItem(languageItem)
        languageMenuItem = languageItem
        menu.addItem(.separator())
        addItem(menu, L10n.t("退出侧边待办", "Quit EdgeTodo"), #selector(quit))
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
        displayMenuItem?.submenu = makeDisplaySubmenu()
        languageMenuItem?.submenu = makeLanguageSubmenu()
    }

    // MARK: 语言切换

    private func makeLanguageSubmenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let current = L10n.language
        for lang in AppLanguage.allCases {
            let item = NSMenuItem(
                title: lang.menuTitle, action: #selector(changeLanguage(_:)), keyEquivalent: ""
            )
            item.target = self
            item.representedObject = lang.rawValue
            item.state = (lang == current) ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc private func changeLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let lang = AppLanguage(rawValue: raw) else { return }
        guard lang != L10n.language else { return }
        L10n.language = lang
        // 界面文案是在构建时写进视图的，所以整体重建一遍
        let wasVisible = panel.isVisible
        installPanelContent()
        setupStatusItem()
        if wasVisible { showPanel(focus: false, on: activeScreen) }
    }

    @objc private func togglePanelAction() { togglePanel() }
    @objc private func openReminders() { store.openRemindersApp() }
    @objc private func reloadAction() { store.reload() }
    @objc private func dockRight() { side = "right"; rebuildHotZones() }
    @objc private func dockLeft() { side = "left"; rebuildHotZones() }
    @objc private func toggleLogin() { LoginItem.setEnabled(!LoginItem.isEnabled) }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func screensChanged() {
        // 面板所在的屏幕被拔掉了，就直接收起，别留在不存在的坐标上
        if let sc = activeScreen, !NSScreen.screens.contains(where: { $0.displayUUID == sc.displayUUID }) {
            activeScreen = nil
            panel?.orderOut(nil)
        }
        // 顺便清掉已经不存在的显示器记录，否则「关到一条不剩」的判定会被旧 UUID 干扰
        let live = Set(NSScreen.screens.map { $0.displayUUID })
        let pruned = hiddenDisplays.intersection(live)
        if pruned != hiddenDisplays { hiddenDisplays = pruned }
        rebuildHotZones()
    }

    @objc private func resetStripPosition() {
        for screen in visibleScreens { setStripFraction(0.5, for: screen) }
        rebuildHotZones()
    }

    // MARK: 显示器选择

    /// 「提示条显示在」子菜单：所有显示器 + 逐块勾选（可多选）
    private func makeDisplaySubmenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let hidden = hiddenDisplays
        let all = NSMenuItem(
            title: L10n.t("所有显示器", "All Displays"),
            action: #selector(enableAllDisplays), keyEquivalent: ""
        )
        all.target = self
        all.state = hidden.isEmpty ? .on : .off
        menu.addItem(all)
        menu.addItem(.separator())

        let screens = NSScreen.screens
        let nameCount = Dictionary(grouping: screens, by: { $0.localizedName }).mapValues { $0.count }
        var seen: [String: Int] = [:]
        for screen in screens {
            let base = screen.localizedName
            let index = (seen[base] ?? 0) + 1
            seen[base] = index
            let title = (nameCount[base] ?? 0) > 1
                ? L10n.t("\(base)（\(index)）", "\(base) (\(index))")
                : base

            let item = NSMenuItem(title: title, action: #selector(toggleDisplay(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = screen.displayUUID
            item.state = hidden.contains(screen.displayUUID) ? .off : .on
            menu.addItem(item)
        }
        return menu
    }

    @objc private func enableAllDisplays() {
        hiddenDisplays = []
        rebuildHotZones()
    }

    @objc private func toggleDisplay(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        var hidden = hiddenDisplays
        if hidden.contains(id) { hidden.remove(id) } else { hidden.insert(id) }
        // 不允许把所有显示器都关掉：关到一条不剩时自动恢复全部，
        // 否则用户会以为程序坏了，且没有入口再打开
        if hidden.count >= NSScreen.screens.count { hidden.removeAll() }
        hiddenDisplays = hidden
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

        installPanelContent()
        panel.setContentSize(panelSize)
    }

    /// 构建/重建面板内容。切换界面语言时整块换掉 —— 文案是构建时写进视图的，
    /// 就地改要遍历每一个 label，重建更省事也不容易漏。
    private func installPanelContent() {
        controller = PanelController()
        controller.onRequestHide = { [weak self] in self?.hidePanel() }
        controller.onBusyChange = { [weak self] value in self?.busy = value }

        let container = NSView(frame: NSRect(origin: .zero, size: panelSize))
        container.autoresizingMask = [.width, .height]
        let view = controller.root
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        panel.contentView = container
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
            // 快捷键/菜单栏唤起：没有具体的提示条来源，就跟着鼠标所在屏幕
            showPanel(focus: true, on: targetScreen())
        }
    }

    /// - Parameter screen: 从哪块屏幕激活的，面板就出现在哪块屏幕上
    func showPanel(focus: Bool, on screen: NSScreen? = nil) {
        outsideSince = nil
        let sc = screen ?? activeScreen ?? targetScreen()
        activeScreen = sc
        let vf = sc.visibleFrame
        let size = panelSize
        let isRight = side == "right"

        // 面板跟着提示条走：垂直居中对齐提示条，超出可视区再夹回来
        let strip = stripRect(for: sc)
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
        syncStripVisibility()   // 面板盖住的那块屏幕的拉手收起来，别叠在玻璃上
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
        for (_, w) in stripWindows {
            if visible { w.orderFrontRegardless() } else { w.orderOut(nil) }
        }
    }

    /// 只藏掉面板所在那块屏幕的提示条（它被玻璃卡片盖住了），
    /// 其他屏幕的提示条留着 —— 这样在其他屏幕上一点就能把面板搬过去。
    private func syncStripVisibility() {
        let coveredKey: String? = panel.isVisible ? activeScreen?.displayUUID : nil
        for (key, win) in stripWindows {
            if key == coveredKey {
                win.orderOut(nil)
            } else {
                win.orderFrontRegardless()
            }
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
        syncStripVisibility()
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
        let y = low + stripFraction(for: screen) * (high - low)
        return NSRect(x: x, y: y, width: edgeStripWidth, height: h)
    }

    /// 拖动时把屏幕坐标换算成新的相对位置（只作用于被拖动的那块屏幕）
    private func setStripPosition(mouseY: CGFloat, on screen: NSScreen) {
        let vf = screen.visibleFrame
        let h = min(edgeStripHeight, vf.height - 120)
        let low = vf.minY + stripMargin
        let high = max(low, vf.maxY - h - stripMargin)
        guard high > low else { return }
        setStripFraction((mouseY - h / 2 - low) / (high - low), for: screen)
    }

    private func tick() {
        guard let panel = panel else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let sc = screen else { return }
        let strip = stripRect(for: sc)
        // 这块屏幕上到底有没有提示条（用户可能把它关掉了，几何位置就不该再生效）
        let stripActive = !hiddenDisplays.contains(sc.displayUUID)
        let onStrip = stripActive && strip.contains(mouse)

        if panel.isVisible {
            // 鼠标停到「另一块」屏幕的提示条上 → 面板跟着搬过去
            if onStrip, activeScreen?.displayUUID != sc.displayUUID {
                showPanel(focus: false, on: sc)
                return
            }
            // 面板本身 + 本屏边缘热区都算"仍在里面"，否则会隐藏又被热区立刻唤出
            if panel.frame.insetBy(dx: -1, dy: -1).contains(mouse) || onStrip {
                outsideSince = nil
                // 鼠标真的挪进面板本体（不是只停在拉手上）就准备接管键盘：
                // 悬停拉手 0.28s 才弹面板，再等 0.15s 才激活，快速划过不会抢焦点。
                let inBody = panel.frame.contains(mouse) && !onStrip
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

        if !onStrip {
            suppressHover = false
            stripEnteredAt = nil
            return
        }
        if stripDragging { stripEnteredAt = nil; return }   // 正在拖动提示条
        if suppressHover { return }
        if Date().timeIntervalSince(lastHiddenAt) < 0.25 { return }  // 刚收起，别马上又弹

        // 先停留一小会儿再弹，给拖动留出手感
        if let since = stripEnteredAt {
            if Date().timeIntervalSince(since) >= hoverDwell { showPanel(focus: false, on: sc) }
        } else {
            stripEnteredAt = Date()
        }
    }

    // MARK: 边缘提示条

    private func rebuildHotZones() {
        stripWindows.values.forEach { $0.orderOut(nil) }
        stripWindows.removeAll()

        for screen in visibleScreens {
            let rect = stripRect(for: screen)
            let key = screen.displayUUID
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
                guard let sc = self.screen(withUUID: key) ?? win.screen else { return }
                self.setStripPosition(mouseY: point.y, on: sc)
                win.setFrame(self.stripRect(for: sc), display: true)
            }
            view.onRelease = { [weak self, weak win] _ in
                guard let self = self else { return }
                let moved = self.stripDragging
                self.stripDragging = false
                self.suppressHover = true
                self.stripEnteredAt = nil
                let sc = self.screen(withUUID: key) ?? win?.screen
                if let win = win, let sc = sc {
                    win.setFrame(self.stripRect(for: sc), display: true)
                }
                // 单纯点一下（没拖动）就在这块屏幕上打开面板
                if !moved { self.showPanel(focus: false, on: sc) }
            }
            view.onMenu = { [weak self] event in
                guard let self = self, let v = event.window?.contentView else { return }
                self.showStripMenu(with: event, for: v, screen: self.screen(withUUID: key))
            }

            win.contentView = view
            stripWindows[key] = win
        }
        syncStripVisibility()

        // 提示条窗口重新建过之后，别把已展开的面板压住
        if panel.isVisible { panel.orderFrontRegardless() }
    }

    private func screen(withUUID uuid: String) -> NSScreen? {
        NSScreen.screens.first { $0.displayUUID == uuid }
    }

    /// 右键提示条：左右边缘 / 显示在哪块屏幕 / 复位
    private func showStripMenu(with event: NSEvent, for view: NSView, screen: NSScreen?) {
        suppressHover = true
        stripEnteredAt = nil

        let menu = NSMenu()
        menu.autoenablesItems = false

        let right = NSMenuItem(
            title: L10n.t("停靠在屏幕右侧", "Dock to Right Edge"),
            action: #selector(dockRight), keyEquivalent: ""
        )
        right.target = self
        right.state = side == "right" ? .on : .off
        menu.addItem(right)

        let left = NSMenuItem(
            title: L10n.t("停靠在屏幕左侧", "Dock to Left Edge"),
            action: #selector(dockLeft), keyEquivalent: ""
        )
        left.target = self
        left.state = side == "left" ? .on : .off
        menu.addItem(left)

        menu.addItem(.separator())
        let displayItem = NSMenuItem(title: L10n.t("显示在", "Shown On"), action: nil, keyEquivalent: "")
        displayItem.submenu = makeDisplaySubmenu()
        menu.addItem(displayItem)

        let reset = NSMenuItem(
            title: L10n.t("位置复位到中间", "Reset Position"),
            action: #selector(resetStripPosition), keyEquivalent: ""
        )
        reset.target = self
        menu.addItem(reset)

        // 记下这次是从哪块屏幕点开的，复位/操作都针对它
        if let sc = screen { activeScreen = sc }

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
