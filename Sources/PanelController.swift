import AppKit
import EventKit

// MARK: - 基础控件

final class FlippedView: NSView {
    override var isFlipped: Bool { true }

    /// 空白处点击 → 聚焦输入框
    var onClick: (() -> Void)?

    /// 窗口还没成为 key window 时，第一次点击也要算数（否则要点两下）
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onClick?()
        super.mouseDown(with: event)
    }
}

/// 列表区域的滚动视图：点到没有内容的空白处也能开始输入
final class ClickScrollView: NSScrollView {
    var onBlankClick: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let hit = super.hitTest(p)
        if hit === self || hit is NSClipView {
            onBlankClick?()
        }
        super.mouseDown(with: event)
    }
}

/// 纯展示容器：点自己（或里面的标签）都算点空白，不吞按钮
final class ClickCatcher: NSView {
    var onClick: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if let control = hit as? NSControl, !(control is NSTextField) { return control }
        if let field = hit as? NSTextField, field.isEditable || field.isSelectable { return field }
        return hit == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
        super.mouseDown(with: event)
    }
}

// MARK: - 视觉基调（macOS 27 Liquid Glass）

enum Look {
    static var isDark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    static var hairline: NSColor { NSColor.separatorColor.withAlphaComponent(0.30) }

    /// 半透明填充：浅色外观用黑，深色外观用白
    static func tint(_ alpha: CGFloat) -> NSColor {
        let v: CGFloat = isDark ? 1 : 0
        return NSColor(srgbRed: v, green: v, blue: v, alpha: alpha)
    }

    static func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        img?.isTemplate = true
        return img
    }
}

/// 面板底 / 弹层用的卡片：macOS 26+ 用系统玻璃，更低版本回退到系统磨砂材质
final class GlassCard: NSView {
    var onClick: (() -> Void)?
    private let background: NSView
    private let wash = NSView()
    private let radius: CGFloat

    init(cornerRadius: CGFloat = 26, interactive: Bool = true) {
        self.radius = cornerRadius
        self.background = Self.makeBackground(cornerRadius: cornerRadius, interactive: interactive)
        super.init(frame: .zero)
        // 卡片自己也按圆角裁切：玻璃层的圆角遮罩在个别状态下（比如系统授权弹窗
        // 挡住 runloop 之后的首次布局）会短暂失效，方角就会从白雾底下露出来。
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)

        // 白雾：玻璃之上再压一层薄薄的底，让面板整体更接近白色
        wash.wantsLayer = true
        wash.layer?.cornerRadius = cornerRadius
        wash.layer?.cornerCurve = .continuous
        wash.layer?.masksToBounds = true
        wash.translatesAutoresizingMaskIntoConstraints = false
        addSubview(wash)

        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),

            wash.leadingAnchor.constraint(equalTo: leadingAnchor),
            wash.trailingAnchor.constraint(equalTo: trailingAnchor),
            wash.topAnchor.constraint(equalTo: topAnchor),
            wash.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        applyWash()
    }

    /// macOS 26+ 用系统玻璃；更低版本（应用最低支持 macOS 13）没有这个类，
    /// 回退到系统磨砂材质 NSVisualEffectView —— 观感接近，但不是折射玻璃。
    /// EDGETODO_NO_GLASS=1 可以在新系统上强制走回退分支，方便验证老系统效果。
    private static func makeBackground(cornerRadius: CGFloat, interactive: Bool) -> NSView {
        let forceFallback = ProcessInfo.processInfo.environment["EDGETODO_NO_GLASS"] != nil
        if !forceFallback, #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.style = .regular
            if #available(macOS 27.0, *) {
                glass.effectIsInteractive = interactive
            }
            glass.tintColor = Look.isDark
                ? NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.42)
                : NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.55)
            return glass
        } else {
            let blur = NSVisualEffectView()
            blur.material = .hudWindow
            blur.blendingMode = .behindWindow
            blur.state = .active
            blur.wantsLayer = true
            blur.layer?.cornerRadius = cornerRadius
            blur.layer?.cornerCurve = .continuous
            blur.layer?.masksToBounds = true
            return blur
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyWash()
    }

    private func applyWash() {
        wash.layer?.backgroundColor = Look.isDark
            ? NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.18).cgColor
            : NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.66).cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onClick?()
        super.mouseDown(with: event)
    }
}

/// 底部中间的圆形麦克风按钮（自绘，尺寸完全由约束决定，不会像 NSButton 那样被固有高度撑变形）
final class MicButton: NSView {
    var onTap: (() -> Void)?
    var isActive = false { didSet { refresh() } }

    private let icon = NSImageView()
    private var hovering = false { didSet { refresh() } }
    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.cornerCurve = .continuous
        // 不开 masksToBounds，才能让底下的阴影透出来；圆角只影响背景色
        layer?.shadowRadius = 6
        layer?.shadowOffset = CGSize(width: 0, height: -1)
        layer?.shadowOpacity = 0.16
        layer?.shadowColor = NSColor.black.cgColor
        icon.image = Look.symbol("mic.fill", size: 16, weight: .medium)
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 18, cornerHeight: 18, transform: nil)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func refresh() {
        if isActive {
            layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(hovering ? 0.30 : 0.20).cgColor
            layer?.borderWidth = 1.5
            layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.45).cgColor
            icon.contentTintColor = .controlAccentColor
            icon.image = Look.symbol("mic.fill", size: 16, weight: .bold)
        } else {
            layer?.backgroundColor = Look.tint(hovering ? 0.16 : 0.10).cgColor
            layer?.borderWidth = 1
            layer?.borderColor = Look.tint(0.07).cgColor
            icon.contentTintColor = .secondaryLabelColor
            icon.image = Look.symbol("mic.fill", size: 16, weight: .medium)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { onTap?() }
}

/// 带 hover 反馈的圆角按钮（列表名、快捷时间块、图标按钮都用它）
final class SoftButton: NSButton {
    var restFill: NSColor { didSet { refreshFill() } }
    var hoverFill: NSColor { didSet { refreshFill() } }
    var radius: CGFloat {
        didSet { layer?.cornerRadius = radius }
    }
    var horizontalPadding: CGFloat = 0 {
        didSet { invalidateIntrinsicContentSize() }
    }

    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        size.width += horizontalPadding * 2
        return size
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var hovering = false
    private var tracking: NSTrackingArea?

    init(radius: CGFloat = 9,
         rest: NSColor = Look.tint(0.06),
         hover: NSColor = Look.tint(0.11)) {
        self.radius = radius
        self.restFill = rest
        self.hoverFill = hover
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.masksToBounds = true
        refreshFill()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet { refreshFill() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        refreshFill()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        refreshFill()
    }

    private func refreshFill() {
        let color = (hovering || isHighlighted) ? hoverFill : restFill
        layer?.backgroundColor = color.cgColor
    }
}

/// 实心强调色胶囊按钮（确定 / 授权）
final class FilledButton: NSButton {
    var fill: NSColor = .controlAccentColor { didSet { needsDisplay = true } }
    var textColor: NSColor = .white { didSet { needsDisplay = true } }
    var radius: CGFloat = 9 { didSet { needsDisplay = true } }

    init(title: String, target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        isBordered = false
        wantsLayer = true
        font = .systemFont(ofSize: 12, weight: .medium)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var hovering = false {
        didSet { needsDisplay = true }
    }
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        var color = fill
        if isHighlighted {
            color = fill.blended(withFraction: 0.18, of: .black) ?? fill
        } else if hovering {
            color = fill.blended(withFraction: 0.08, of: .white) ?? fill
        }
        let path = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        color.setFill()
        path.fill()

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: textColor
        ]
        let size = title.size(withAttributes: attrs)
        let origin = NSPoint(x: (bounds.width - size.width) / 2,
                             y: (bounds.height - size.height) / 2)
        title.draw(at: origin, withAttributes: attrs)
    }
}

final class SeparatorLine: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Look.hairline.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - 时间展示

enum DueFmt {
    private static func make(_ format: String, _ localeID: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: localeID)
        f.dateFormat = format
        return f
    }

    // 中英各备一份，切换语言时直接换引用，不用每次重建
    private static let zhTime = make("HH:mm", "zh_CN")
    private static let enTime = make("HH:mm", "en_US")
    private static let zhShort = make("M月d日 HH:mm", "zh_CN")
    private static let enShort = make("MMM d HH:mm", "en_US")
    private static let zhFull = make("yyyy年M月d日 HH:mm", "zh_CN")
    private static let enFull = make("MMM d, yyyy HH:mm", "en_US")

    static var timeOnly: DateFormatter { L10n.isEnglish ? enTime : zhTime }
    static var shortDate: DateFormatter { L10n.isEnglish ? enShort : zhShort }
    static var fullDate: DateFormatter { L10n.isEnglish ? enFull : zhFull }

    static func text(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) {
            return L10n.t("今天 ", "Today ") + timeOnly.string(from: date)
        }
        if cal.isDateInTomorrow(date) {
            return L10n.t("明天 ", "Tomorrow ") + timeOnly.string(from: date)
        }
        if cal.isDateInYesterday(date) {
            return L10n.t("昨天 ", "Yesterday ") + timeOnly.string(from: date)
        }
        if cal.isDate(date, equalTo: Date(), toGranularity: .year) {
            return shortDate.string(from: date)
        }
        return fullDate.string(from: date)
    }

    static func color(_ date: Date) -> NSColor {
        if date < Date() { return .systemRed }
        if Calendar.current.isDateInToday(date) { return .systemOrange }
        return .secondaryLabelColor
    }
}

// MARK: - 面板界面

final class PanelController: NSObject, NSTextFieldDelegate {
    let store = TodoStore.shared
    let root = NSView()

    private let card = GlassCard(cornerRadius: 26)
    private let listButton = SoftButton(radius: 9,
                                        rest: Look.tint(0.06),
                                        hover: Look.tint(0.11))
    private let countLabel = NSTextField(labelWithString: "")
    private let contentHost = NSView()
    private let scrollView = ClickScrollView()
    private let rowsStack = NSStackView()
    private var emptyView: NSView!
    private var permissionView: NSView!

    /// 临时输入行：点空白处才出现，回车即存
    private var draftRow: NSView?
    private var draftField: NSTextField?
    private var draftDueLabel: NSTextField?

    /// 底部中间的语音输入
    private let voice = VoiceInput()
    private var micButton: MicButton!
    private var isVoiceListening = false
    private var voiceBaseText = ""
    private var permissionShown = false

    private var editorOverlay: NSView?
    private var editorDate = Date()
    private var editingItem: TodoItem?

    var onRequestHide: (() -> Void)?
    var onBusyChange: ((Bool) -> Void)?

    override init() {
        super.init()
        build()
        store.onChange = { [weak self] in self?.refresh() }
        refresh()
    }

    // MARK: 构建

    private func build() {
        root.frame = NSRect(x: 0, y: 0, width: 380, height: 600)
        root.autoresizingMask = [.width, .height]
        root.wantsLayer = true

        // 玻璃卡直接贴满窗口：窗口 alpha 形状 = 圆角卡片本身，
        // 系统阴影才会沿着圆角走。留内边距会让阴影按矩形窗口画，
        // 在卡片下方露出一条"第二道边"。
        card.translatesAutoresizingMaskIntoConstraints = false
        card.onClick = { [weak self] in self?.activateAndFocus() }
        root.addSubview(card)

        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            card.topAnchor.constraint(equalTo: root.topAnchor),
            card.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        let sections = NSStackView()
        sections.orientation = .vertical
        sections.spacing = 0
        sections.distribution = .fill
        sections.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(sections)
        NSLayoutConstraint.activate([
            sections.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            sections.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            sections.topAnchor.constraint(equalTo: card.topAnchor),
            sections.bottomAnchor.constraint(equalTo: card.bottomAnchor)
        ])

        addSection(buildHeader(), to: sections)
        addSection(makeHairline(), to: sections)

        contentHost.translatesAutoresizingMaskIntoConstraints = false
        addSection(contentHost, to: sections)
        contentHost.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        contentHost.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .vertical)
        buildContent()
        buildMicButton()
    }

    /// 底部中间的麦克风：点一下新建一条待办并开始听写
    private func buildMicButton() {
        let mic = MicButton()
        mic.onTap = { [weak self] in self?.micTapped() }
        mic.toolTip = L10n.t("语音输入：点一下开始说，再点一下存成提醒", "Voice input: click to start, click again to save")
        mic.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(mic)
        NSLayoutConstraint.activate([
            mic.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            mic.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
            mic.widthAnchor.constraint(equalToConstant: 36),
            mic.heightAnchor.constraint(equalToConstant: 36)
        ])
        micButton = mic
    }

    private func makeHairline() -> NSView {
        let wrap = NSView()
        let line = SeparatorLine(frame: .zero)
        line.translatesAutoresizingMaskIntoConstraints = false
        wrap.addSubview(line)
        NSLayoutConstraint.activate([
            wrap.heightAnchor.constraint(equalToConstant: 1),
            line.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 16),
            line.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -16),
            line.topAnchor.constraint(equalTo: wrap.topAnchor),
            line.heightAnchor.constraint(equalToConstant: 1)
        ])
        return wrap
    }

    /// NSStackView 的 .width 对齐不可靠，这里手工锁宽
    private func addSection(_ view: NSView, to stack: NSStackView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    /// 列表名胶囊：标题 + 小折叠箭头
    private func listChipTitle(_ name: String) -> NSAttributedString {
        let text = NSMutableAttributedString(
            string: name,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold),
                .foregroundColor: NSColor.labelColor
            ]
        )
        text.append(NSAttributedString(
            string: "  ▾",
            attributes: [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .bold),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        ))
        return text
    }

    private func buildHeader() -> NSView {
        let container = NSView()

        // 胶囊形的列表选择器
        listButton.font = .systemFont(ofSize: 12.5, weight: .semibold)
        listButton.contentTintColor = .labelColor
        listButton.image = Look.symbol("checklist", size: 11, weight: .semibold)
        listButton.imagePosition = .imageLeading
        listButton.imageHugsTitle = true
        listButton.attributedTitle = listChipTitle(L10n.t("提醒", "Reminders"))
        listButton.target = self
        listButton.action = #selector(showListMenu(_:))
        listButton.horizontalPadding = 10
        listButton.setContentHuggingPriority(.required, for: .horizontal)
        listButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        listButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(listButton)

        countLabel.font = .systemFont(ofSize: 11, weight: .medium)
        countLabel.textColor = .tertiaryLabelColor
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(countLabel)

        let reload = SoftButton(radius: 11,
                                rest: .clear,
                                hover: Look.tint(0.10))
        reload.image = Look.symbol("arrow.trianglehead.clockwise", size: 11, weight: .medium)
        reload.contentTintColor = .secondaryLabelColor
        reload.target = self
        reload.action = #selector(reloadTapped)
        reload.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(reload)

        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 46),

            listButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            listButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            listButton.heightAnchor.constraint(equalToConstant: 24),
            listButton.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -110),

            reload.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            reload.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            reload.widthAnchor.constraint(equalToConstant: 22),
            reload.heightAnchor.constraint(equalToConstant: 22),

            countLabel.trailingAnchor.constraint(equalTo: reload.leadingAnchor, constant: -6),
            countLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        return container
    }

    /// 临时输入行：点窗口空白处才插入，回车即存
    private func makeDraftRow() -> NSView {
        let row = NSView()
        row.wantsLayer = true
        row.layer?.cornerRadius = 10
        row.layer?.cornerCurve = .continuous
        row.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.13).cgColor
        row.layer?.borderWidth = 1
        row.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.35).cgColor
        row.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = Look.symbol("plus.circle.fill", size: 13, weight: .semibold)
        icon.contentTintColor = .controlAccentColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(icon)

        let field = NSTextField()
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.textColor = .labelColor
        field.placeholderString = L10n.t("写点什么，回车存进提醒事项", "Type something, Return to save")
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        field.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(field)

        let due = NSTextField(labelWithString: "")
        due.font = .systemFont(ofSize: 10.5, weight: .medium)
        due.textColor = .secondaryLabelColor
        due.alignment = .right
        due.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(due)

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 34),

            icon.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),

            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            field.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            field.heightAnchor.constraint(equalToConstant: 18),

            due.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 6),
            due.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -10),
            due.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        due.setContentHuggingPriority(.required, for: .horizontal)

        draftField = field
        draftDueLabel = due
        return row
    }

    // MARK: 草稿行

    /// 点空白 / 快捷键：在列表顶部开一行输入
    func startDraft() {
        if draftRow != nil {
            root.window?.makeFirstResponder(draftField)
            return
        }
        let row = makeDraftRow()
        draftRow = row
        rowsStack.insertArrangedSubview(row, at: 0)
        row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        refresh()
        refreshDraft()
        root.window?.makeFirstResponder(draftField)
    }

    /// 收起草稿行（有内容则先存下）
    func cancelDraftIfNeeded() {
        stopVoiceIfNeeded()
        guard draftRow != nil else { return }
        commitDraft(keepOpen: false)
    }

    private func removeDraft() {
        guard let row = draftRow else { return }
        rowsStack.removeArrangedSubview(row)
        row.removeFromSuperview()
        draftRow = nil
        draftField = nil
        draftDueLabel = nil
        refresh()
    }

    // MARK: 语音输入

    @objc private func micTapped() {
        if isVoiceListening {
            voice.stop()
            finishVoice(commit: true)     // 再点一下：把听到的内容直接存成提醒
        } else {
            startVoice()
        }
    }

    private func startVoice() {
        startDraft()                       // 点麦克风就等于新建一条提醒
        guard let field = draftField else { return }
        voiceBaseText = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        isVoiceListening = true
        updateMic()
        field.placeholderString = L10n.t("正在听…", "Listening…")
        onBusyChange?(true)                // 说话时先别自动收起面板
        voice.onPartial = { [weak self] text in self?.applyVoice(text) }
        voice.onError = { [weak self] message in
            guard let self = self else { return }
            self.isVoiceListening = false
            self.onBusyChange?(false)
            self.updateMic()
            self.draftField?.placeholderString = message
        }
        voice.onFinish = { [weak self] in self?.finishVoice(commit: true) }
        voice.start()
        NSApp.activate(ignoringOtherApps: true)
        root.window?.makeKey()
    }

    /// 把识别到的文字接到输入行里（中文不插空格，英文单词之间补一个）
    private func applyVoice(_ spoken: String) {
        let text = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        var joined = voiceBaseText
        if !joined.isEmpty, let last = joined.last, last.isASCII, last.isLetter || last.isNumber {
            joined += " "
        }
        joined += text
        draftField?.stringValue = joined
        refreshDraft()
    }

    /// 结束听写；commit = true 时按「回车」的逻辑直接存成提醒
    private func finishVoice(commit: Bool) {
        guard isVoiceListening else { return }
        isVoiceListening = false
        voice.onPartial = nil
        voice.onError = nil
        voice.onFinish = nil
        updateMic()
        onBusyChange?(false)
        draftField?.placeholderString = L10n.t("写点什么，回车存进提醒事项", "Type something, Return to save")
        guard let field = draftField else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            removeDraft()                  // 一句话都没听清：不留空行
            return
        }
        if commit {
            commitDraft(keepOpen: false)   // 标题 + 时间交给 QuickParse
            NSApp.activate(ignoringOtherApps: true)
            root.window?.makeKey()
        }
    }

    private func stopVoiceIfNeeded() {
        guard isVoiceListening else { return }
        isVoiceListening = false
        voice.onPartial = nil
        voice.onError = nil
        voice.onFinish = nil
        voice.stop()
        updateMic()
        onBusyChange?(false)
        draftField?.placeholderString = L10n.t("写点什么，回车存进提醒事项", "Type something, Return to save")
    }

    private func updateMic() {
        guard let mic = micButton else { return }
        mic.isActive = isVoiceListening
        mic.toolTip = isVoiceListening
            ? L10n.t("正在听…再点一下结束并存成提醒", "Listening… click again to finish and save")
            : L10n.t("语音输入：点一下开始说，再点一下存成提醒", "Voice input: click to start, click again to save")
    }

    private func updateMicVisibility() {
        micButton?.isHidden = permissionShown || editorOverlay != nil
    }

    /// 存下草稿；keepOpen 时清空并继续输入
    private func commitDraft(keepOpen: Bool) {
        guard let field = draftField else { return }
        // 回车存提醒 = 这一句说完了：麦克风先关掉，再走存库逻辑
        if isVoiceListening {
            voice.stop()
            isVoiceListening = false
            voice.onPartial = nil
            voice.onError = nil
            voice.onFinish = nil
            updateMic()
            onBusyChange?(false)
            field.placeholderString = L10n.t("写点什么，回车存进提醒事项", "Type something, Return to save")
        }
        let raw = field.stringValue
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let parsed = QuickParse.parse(raw)
            _ = store.add(title: parsed.title, due: parsed.due)
            field.stringValue = ""
            refreshDraft()
        }
        if !keepOpen { removeDraft() }
    }

    private func buildContent() {
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.onClick = { [weak self] in self?.activateAndFocus() }
        scrollView.onBlankClick = { [weak self] in self?.activateAndFocus() }

        rowsStack.orientation = .vertical
        rowsStack.spacing = 2
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(rowsStack)
        scrollView.documentView = doc

        contentHost.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: contentHost.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),

            doc.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            doc.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),

            rowsStack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 8),
            rowsStack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -8),
            rowsStack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 6),
            rowsStack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -54)   // 给底部麦克风留位置
        ])

        emptyView = buildEmpty()
        contentHost.addSubview(emptyView)
        permissionView = buildPermission()
        contentHost.addSubview(permissionView)
        for v in [emptyView!, permissionView!] {
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
                v.topAnchor.constraint(equalTo: contentHost.topAnchor),
                v.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor)
            ])
        }
    }

    /// 空状态与授权页共用的插图圆圈
    private func makeSymbolBadge(_ symbol: String) -> NSView {
        let badge = NSView()
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 26
        badge.layer?.backgroundColor = Look.tint(0.06).cgColor
        badge.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = Look.symbol(symbol, size: 22, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(icon)

        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: 52),
            badge.heightAnchor.constraint(equalToConstant: 52),
            icon.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: badge.centerYAnchor)
        ])
        return badge
    }

    private func buildEmpty() -> NSView {
        let container = ClickCatcher()
        container.onClick = { [weak self] in self?.activateAndFocus() }
        container.translatesAutoresizingMaskIntoConstraints = false

        let inner = NSStackView()
        inner.orientation = .vertical
        inner.alignment = .centerX
        inner.spacing = 4
        inner.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(inner)

        let badge = makeSymbolBadge("checkmark")
        inner.addArrangedSubview(badge)
        inner.setCustomSpacing(12, after: badge)

        let title = NSTextField(labelWithString: L10n.t("都清完了", "All clear"))
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .labelColor
        title.alignment = .center
        inner.addArrangedSubview(title)

        let tip = NSTextField(labelWithString: L10n.t("点一下空白处，直接开始写", "Click anywhere to start writing"))
        tip.font = .systemFont(ofSize: 11)
        tip.textColor = .secondaryLabelColor
        tip.alignment = .center
        inner.addArrangedSubview(tip)

        NSLayoutConstraint.activate([
            inner.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            inner.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            inner.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -40)
        ])
        return container
    }

    private func buildPermission() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let inner = NSStackView()
        inner.orientation = .vertical
        inner.alignment = .centerX
        inner.spacing = 4
        inner.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(inner)

        let badge = makeSymbolBadge("lock.shield")
        inner.addArrangedSubview(badge)
        inner.setCustomSpacing(12, after: badge)

        let title = NSTextField(labelWithString: L10n.t("需要访问系统「提醒事项」", "Needs access to Reminders"))
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.alignment = .center
        inner.addArrangedSubview(title)

        let tip = NSTextField(wrappingLabelWithString: L10n.t(
            "允许后，这里每一条都会实时读写提醒事项，并随 iCloud 同步到 iPhone。",
            "Reads and writes Reminders live, and syncs to your iPhone via iCloud."
        ))
        tip.font = .systemFont(ofSize: 11)
        tip.textColor = .secondaryLabelColor
        tip.alignment = .center
        tip.preferredMaxLayoutWidth = 250
        inner.addArrangedSubview(tip)

        let request = FilledButton(title: L10n.t("允许访问", "Allow Access"), target: self, action: #selector(requestAccess))
        request.translatesAutoresizingMaskIntoConstraints = false
        inner.addArrangedSubview(request)
        inner.setCustomSpacing(14, after: tip)

        let settings = SoftButton(radius: 9, rest: .clear, hover: Look.tint(0.08))
        settings.title = L10n.t("打开系统设置", "Open System Settings")
        settings.font = .systemFont(ofSize: 11)
        settings.contentTintColor = .secondaryLabelColor
        settings.target = self
        settings.action = #selector(openSettings)
        settings.translatesAutoresizingMaskIntoConstraints = false
        inner.addArrangedSubview(settings)

        NSLayoutConstraint.activate([
            inner.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            inner.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            inner.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -40),

            request.widthAnchor.constraint(equalToConstant: 110),
            request.heightAnchor.constraint(equalToConstant: 28),
            settings.heightAnchor.constraint(equalToConstant: 24),
            settings.widthAnchor.constraint(equalToConstant: 110)
        ])
        return container
    }

    /// 预览用：无权限时也能看到列表样式
    private var demoMode: Bool {
        ProcessInfo.processInfo.environment["EDGETODO_DEMO"] != nil
            || UserDefaults.standard.bool(forKey: "demoMode")
    }

    private static func demoItems() -> [TodoItem] {
        let ek = TodoStore.shared.ek
        let cal = Calendar.current
        let now = Date()
        // 只用通用条目，不放任何真实客户 / 学校 / 产品名，避免截图外泄隐私
        let samples: [(String, Date?)] = [
            (L10n.t("整理本周的会议纪要", "Tidy up this week's meeting notes"), now.addingTimeInterval(3600)),
            (L10n.t("回复客户关于报价的邮件", "Reply to the client's quote email"), cal.date(byAdding: .day, value: 1, to: now)),
            (L10n.t("提交上个月的报销单", "Submit last month's expense report"), nil),
            (L10n.t("确认下周的交付排期", "Confirm next week's delivery schedule"), now.addingTimeInterval(-7200)),
            (L10n.t("预约周五的体检", "Book Friday's checkup"), cal.date(byAdding: .day, value: 3, to: now))
        ]
        return samples.map { title, due in
            let r = EKReminder(eventStore: ek)
            r.title = title
            if let due = due {
                r.dueDateComponents = cal.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            }
            return TodoItem(reminder: r)
        }
    }

    // MARK: 刷新

    func refresh() {
        // 演示模式用语言对应的假列表名，避免英文界面里挂着一串中文真实列表名
        let listName = demoMode
            ? L10n.t("提醒", "Reminders")
            : (store.selectedList?.title ?? L10n.t("提醒事项", "Reminders"))
        listButton.attributedTitle = listChipTitle(listName)
        listButton.isEnabled = demoMode || !store.lists.isEmpty
        listButton.invalidateIntrinsicContentSize()
        let shown = demoMode ? Self.demoItems().count : store.items.count
        countLabel.stringValue = (store.authGranted || demoMode) && shown > 0 ? "\(shown)" : ""
        if let field = draftField {
            if isVoiceListening {
                field.placeholderString = L10n.t("正在听…", "Listening…")
            } else {
                field.placeholderString = store.lastError == nil
                    ? L10n.t("写点什么，回车存进提醒事项", "Type something, Return to save")
                    : L10n.t("⚠︎ 和提醒事项同步失败", "⚠︎ Reminders sync failed")
            }
        }

        rowsStack.arrangedSubviews.forEach { view in
            guard view !== draftRow else { return }   // 草稿行留着
            rowsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        var displayItems = store.items
        if demoMode {
            displayItems = Self.demoItems()
        }
        for item in displayItems {
            let row = TodoRowView(item: item)
            if !demoMode {
                row.onToggle = { [weak self] in self?.store.complete(item) }
            }
            row.onRemind = { [weak self] in self?.beginEdit(item) }
            row.translatesAutoresizingMaskIntoConstraints = false
            rowsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        }

        // forcePermission 仅用于预览未授权状态的排版（调试开关）
        let previewPermission = UserDefaults.standard.bool(forKey: "forcePermission")
        let showPermission = (!store.authGranted || previewPermission) && !demoMode
        // 有草稿行时不显示空状态，否则输入行会被盖住
        let showEmpty = store.authGranted && store.items.isEmpty && !demoMode && draftRow == nil
        permissionView.isHidden = !showPermission
        permissionShown = showPermission
        updateMicVisibility()
        emptyView.isHidden = !showEmpty
        scrollView.isHidden = showPermission || showEmpty
    }

    /// 输入时实时显示解析出的提醒时间
    func refreshDraft() {
        if let field = draftField, let dueLabel = draftDueLabel {
            let raw = field.stringValue
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, let due = QuickParse.parse(raw).due {
                dueLabel.stringValue = DueFmt.text(due)
                dueLabel.textColor = DueFmt.color(due)
            } else {
                dueLabel.stringValue = ""
            }
        }
        onBusyChange?(editorOverlay != nil)
    }

    // MARK: 输入处理

    func controlTextDidChange(_ obj: Notification) {
        refreshDraft()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            // 回车存下，输入行留着继续写
            commitDraft(keepOpen: true)
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            if editorOverlay != nil {
                closeEditor()
            } else if draftRow != nil {
                removeDraft()
            } else {
                onRequestHide?()
            }
            return true
        }
        return false
    }

    var isEditing: Bool { editorOverlay != nil }

    /// ESC：优先关掉提醒编辑框 / 收起草稿，返回 true 表示已消费
    func dismissEditorIfNeeded() -> Bool {
        if editorOverlay != nil {
            closeEditor()
            return true
        }
        if draftRow != nil {
            cancelDraftIfNeeded()
            return true
        }
        return false
    }

    /// 悬停展开时应用未激活，点一下才接管键盘
    func activateAndFocus() {
        let wasActive = NSApp.isActive
        NSApp.activate(ignoringOtherApps: true)
        root.window?.makeKeyAndOrderFront(nil)
        startDraft()
        // 从别的 app 切过来时，激活是异步的，等这一拍再补一次焦点，
        // 免得出现"输入行出来了但敲字没反应"。
        if !wasActive {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.root.window?.makeKey()
                self.root.window?.makeFirstResponder(self.draftField)
            }
        }
    }

    func focusInput() {
        startDraft()
    }

    // MARK: 提醒编辑

    private func beginEdit(_ item: TodoItem) {
        guard editorOverlay == nil else { return }
        editingItem = item
        editorDate = item.due ?? nextHour()
        let overlay = buildEditor(item: item)
        card.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: card.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: card.bottomAnchor)
        ])
        editorOverlay = overlay
        updateMicVisibility()
        NSApp.activate(ignoringOtherApps: true)
        onBusyChange?(true)
    }

    private func nextHour() -> Date {
        let cal = Calendar.current
        let now = Date()
        var comps = cal.dateComponents([.year, .month, .day, .hour], from: now)
        comps.hour = (comps.hour ?? 0) + 1
        if (comps.hour ?? 0) >= 24 {
            let tomorrow = cal.date(byAdding: .day, value: 1, to: now) ?? now
            comps = cal.dateComponents([.year, .month, .day], from: tomorrow)
            comps.hour = 9
        }
        return cal.date(from: comps) ?? now
    }

    private func closeEditor() {
        editorOverlay?.removeFromSuperview()
        editorOverlay = nil
        editingItem = nil
        updateMicVisibility()
        refreshDraft()
        focusInput()
    }

    @objc private func editorConfirm() {
        if let item = editingItem { store.setDue(item, editorDate) }
        closeEditor()
    }

    @objc private func editorClear() {
        if let item = editingItem { store.setDue(item, nil) }
        closeEditor()
    }

    @objc private func chipTapped(_ sender: NSButton) {
        let cal = Calendar.current
        var day = cal.startOfDay(for: Date())
        switch sender.tag {
        case 2: day = cal.date(byAdding: .day, value: 1, to: day) ?? day
        case 3:
            let weekday = cal.component(.weekday, from: Date())
            var delta = (2 - weekday + 7) % 7
            if delta == 0 { delta = 7 }
            day = cal.date(byAdding: .day, value: delta, to: day) ?? day
        default: break
        }
        let hour = [18, 20, 9, 9][sender.tag]
        if let d = cal.date(bySettingHour: hour, minute: 0, second: 0, of: day) {
            editorDate = d
            (editorOverlay?.viewWithTag(1000) as? NSDatePicker)?.dateValue = d
        }
    }

    private func buildEditor(item: TodoItem) -> NSView {
        let overlay = NSView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.10).cgColor

        let box = GlassCard(cornerRadius: 22)
        box.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(box)

        let title = NSTextField(labelWithString: L10n.t("设置提醒", "Set Reminder"))
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(title)

        let itemTitle = NSTextField(wrappingLabelWithString: item.title)
        itemTitle.font = .systemFont(ofSize: 11)
        itemTitle.textColor = .secondaryLabelColor
        itemTitle.preferredMaxLayoutWidth = 268
        itemTitle.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(itemTitle)

        let picker = NSDatePicker()
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = [.yearMonthDay, .hourMinute]
        picker.dateValue = editorDate
        picker.font = .systemFont(ofSize: 12)
        picker.tag = 1000
        picker.target = self
        picker.action = #selector(datePicked(_:))
        picker.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(picker)

        let chips = NSStackView()
        chips.orientation = .horizontal
        chips.spacing = 4
        chips.translatesAutoresizingMaskIntoConstraints = false
        let chipTitles = [
            L10n.t("今天 18:00", "Today 6pm"),
            L10n.t("今晚 20:00", "Tonight 8pm"),
            L10n.t("明早 09:00", "Tmrw 9am"),
            L10n.t("下周一", "Next Mon")
        ]
        for (i, t) in chipTitles.enumerated() {
            let b = SoftButton(radius: 8, rest: Look.tint(0.07), hover: Look.tint(0.13))
            b.title = t
            b.tag = i
            b.font = .systemFont(ofSize: 10)
            b.contentTintColor = .secondaryLabelColor
            b.target = self
            b.action = #selector(chipTapped(_:))
            b.heightAnchor.constraint(equalToConstant: 22).isActive = true
            chips.addArrangedSubview(b)
        }
        box.addSubview(chips)

        let clear = SoftButton(radius: 8, rest: .clear, hover: Look.tint(0.08))
        clear.title = L10n.t("清除提醒", "Clear Reminder")
        clear.font = .systemFont(ofSize: 11)
        clear.contentTintColor = .systemRed
        clear.target = self
        clear.action = #selector(editorClear)
        clear.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(clear)

        let cancel = SoftButton(radius: 9, rest: Look.tint(0.08), hover: Look.tint(0.14))
        cancel.title = L10n.t("取消", "Cancel")
        cancel.font = .systemFont(ofSize: 12)
        cancel.contentTintColor = .labelColor
        cancel.target = self
        cancel.action = #selector(editorCancel)
        cancel.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(cancel)

        let confirm = FilledButton(title: L10n.t("确定", "OK"), target: self, action: #selector(editorConfirm))
        confirm.keyEquivalent = "\r"
        confirm.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(confirm)

        NSLayoutConstraint.activate([
            box.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            box.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            box.widthAnchor.constraint(equalToConstant: 300),

            title.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 16),
            title.topAnchor.constraint(equalTo: box.topAnchor, constant: 14),

            itemTitle.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 16),
            itemTitle.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -16),
            itemTitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 5),

            picker.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 13),
            picker.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -13),
            picker.topAnchor.constraint(equalTo: itemTitle.bottomAnchor, constant: 12),

            chips.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 13),
            chips.topAnchor.constraint(equalTo: picker.bottomAnchor, constant: 10),

            clear.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 11),
            clear.centerYAnchor.constraint(equalTo: confirm.centerYAnchor),
            clear.heightAnchor.constraint(equalToConstant: 24),

            confirm.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -14),
            confirm.topAnchor.constraint(equalTo: chips.bottomAnchor, constant: 12),
            confirm.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -14),
            confirm.widthAnchor.constraint(equalToConstant: 64),
            confirm.heightAnchor.constraint(equalToConstant: 26),

            cancel.trailingAnchor.constraint(equalTo: confirm.leadingAnchor, constant: -6),
            cancel.centerYAnchor.constraint(equalTo: confirm.centerYAnchor),
            cancel.widthAnchor.constraint(equalToConstant: 56),
            cancel.heightAnchor.constraint(equalToConstant: 26)
        ])
        return overlay
    }

    @objc private func datePicked(_ sender: NSDatePicker) {
        editorDate = sender.dateValue
    }

    @objc private func editorCancel() { closeEditor() }

    // MARK: 动作

    @objc private func showListMenu(_ sender: NSButton) {
        guard !store.lists.isEmpty else { return }
        let menu = NSMenu()
        let current = store.selectedList?.calendarIdentifier
        for list in store.lists {
            let item = NSMenuItem(title: list.title, action: #selector(listChosen(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = list.calendarIdentifier
            item.state = (list.calendarIdentifier == current) ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    @objc private func listChosen(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String {
            store.selectedListID = id
        }
    }

    @objc private func reloadTapped() { store.reload() }
    @objc private func requestAccess() { store.requestAccess() }
    @objc private func openSettings() { store.openPrivacySettings() }
    @objc private func openReminders() { store.openRemindersApp() }
}

// MARK: - 列表行

final class TodoRowView: NSView {
    let item: TodoItem
    var onToggle: (() -> Void)?
    var onRemind: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private let circle = NSButton()
    private let titleLabel = NSTextField(labelWithString: "")
    private let dueChip = NSView()
    private let dueIcon = NSImageView()
    private let dueLabel = NSTextField(labelWithString: "")
    private let bell = NSButton()
    private var trackingRef: NSTrackingArea?
    private var hovering = false

    init(item: TodoItem) {
        self.item = item
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false

        circle.image = Look.symbol("circle", size: 14, weight: .regular)
        circle.isBordered = false
        circle.contentTintColor = .tertiaryLabelColor
        circle.target = self
        circle.action = #selector(toggle)
        circle.translatesAutoresizingMaskIntoConstraints = false
        addSubview(circle)

        titleLabel.stringValue = item.title
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.textColor = .labelColor
        titleLabel.maximumNumberOfLines = 2
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.cell?.wraps = true
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        // 到期时间做成带底色的胶囊
        dueChip.wantsLayer = true
        dueChip.layer?.cornerRadius = 7
        dueChip.layer?.cornerCurve = .continuous
        dueChip.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dueChip)

        dueIcon.translatesAutoresizingMaskIntoConstraints = false
        dueLabel.font = .systemFont(ofSize: 10.5, weight: .medium)
        dueLabel.translatesAutoresizingMaskIntoConstraints = false
        dueChip.addSubview(dueIcon)
        dueChip.addSubview(dueLabel)

        NSLayoutConstraint.activate([
            dueIcon.leadingAnchor.constraint(equalTo: dueChip.leadingAnchor, constant: 6),
            dueIcon.centerYAnchor.constraint(equalTo: dueChip.centerYAnchor),
            dueIcon.widthAnchor.constraint(equalToConstant: 9),
            dueIcon.heightAnchor.constraint(equalToConstant: 9),

            dueLabel.leadingAnchor.constraint(equalTo: dueIcon.trailingAnchor, constant: 4),
            dueLabel.trailingAnchor.constraint(equalTo: dueChip.trailingAnchor, constant: -6),
            dueLabel.centerYAnchor.constraint(equalTo: dueChip.centerYAnchor),

            dueChip.heightAnchor.constraint(equalToConstant: 18)
        ])

        if let due = item.due {
            let tint = DueFmt.color(due)
            dueLabel.stringValue = DueFmt.text(due)
            dueLabel.textColor = tint
            dueIcon.image = Look.symbol("alarm", size: 9, weight: .medium)
            dueIcon.contentTintColor = tint
            dueChip.layer?.backgroundColor = tint.withAlphaComponent(0.13).cgColor
            dueChip.isHidden = false
        } else {
            dueChip.isHidden = true
        }

        bell.image = Look.symbol("bell", size: 11, weight: .medium)
        bell.isBordered = false
        bell.contentTintColor = .secondaryLabelColor
        bell.target = self
        bell.action = #selector(remind)
        bell.isHidden = true
        bell.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bell)

        NSLayoutConstraint.activate([
            circle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            circle.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            circle.widthAnchor.constraint(equalToConstant: 15),
            circle.heightAnchor.constraint(equalToConstant: 15),

            titleLabel.leadingAnchor.constraint(equalTo: circle.trailingAnchor, constant: 9),
            titleLabel.trailingAnchor.constraint(equalTo: bell.leadingAnchor, constant: -6),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 7),

            dueChip.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            dueChip.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
            dueChip.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

            bell.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            bell.centerYAnchor.constraint(equalTo: circle.centerYAnchor),
            bell.widthAnchor.constraint(equalToConstant: 14),
            bell.heightAnchor.constraint(equalToConstant: 14)
        ])

        self.menu = buildMenu()
        for sub in [titleLabel, dueChip, dueLabel] { sub.menu = self.menu }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let remindItem = NSMenuItem(title: L10n.t("设置提醒…", "Set Reminder…"), action: #selector(remind), keyEquivalent: "")
        remindItem.target = self
        menu.addItem(remindItem)

        let clear = NSMenuItem(title: L10n.t("清除提醒", "Clear Reminder"), action: #selector(clearDue), keyEquivalent: "")
        clear.target = self
        clear.isEnabled = item.due != nil
        menu.addItem(clear)

        let move = NSMenuItem(title: L10n.t("移动到", "Move to"), action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for list in TodoStore.shared.lists {
            let mi = NSMenuItem(title: list.title, action: #selector(moveToList(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = list.calendarIdentifier
            submenu.addItem(mi)
        }
        move.submenu = submenu
        menu.addItem(move)

        menu.addItem(.separator())

        let open = NSMenuItem(title: L10n.t("在提醒事项中打开", "Open in Reminders"), action: #selector(openApp), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        let del = NSMenuItem(title: L10n.t("删除", "Delete"), action: #selector(deleteItem), keyEquivalent: "")
        del.target = self
        menu.addItem(del)
        return menu
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingRef { removeTrackingArea(t) }
        let t = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(t)
        trackingRef = t
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        bell.isHidden = false
        circle.contentTintColor = .controlAccentColor
        layer?.backgroundColor = Look.tint(0.06).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        bell.isHidden = true
        circle.contentTintColor = .tertiaryLabelColor
        layer?.backgroundColor = nil
    }

    override func layout() {
        super.layout()
        titleLabel.preferredMaxLayoutWidth = titleLabel.frame.width
    }

    @objc private func toggle() { onToggle?() }
    @objc private func remind() { onRemind?() }

    @objc private func clearDue() {
        TodoStore.shared.setDue(item, nil)
    }

    @objc private func moveToList(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let cal = TodoStore.shared.ek.calendar(withIdentifier: id) else { return }
        TodoStore.shared.move(item, to: cal)
    }

    @objc private func openApp() { TodoStore.shared.openRemindersApp() }

    @objc private func deleteItem() { TodoStore.shared.delete(item) }
}

private extension NSView {
    func with(height: CGFloat) -> NSView {
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: height).isActive = true
        return self
    }
}
