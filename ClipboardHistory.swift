import Cocoa
import Carbon

// MARK: - 全局状态
var history: [String] = []
let maxHistory = 30
var lastChangeCount: Int = 0
var hotKeyRef: EventHotKeyRef?
// 本程序主动写入剪贴板的内容:轮询时识别到它则跳过,避免点击历史项导致该项被挪到队首
var internalPasteText: String?

// MARK: - AppDelegate
class AppDelegate: NSObject, NSApplicationDelegate {
    // 强引用持有状态栏项,防止被释放后图标消失
    var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 隐藏 Dock 图标，作为后台进程运行
        NSApp.setActivationPolicy(.accessory)

        setupStatusItem()
        checkAccessibilityAndPromptIfNeeded()

        // 定时检查剪贴板变化（每 0.3 秒）
        Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
            checkPasteboard()
        }

        // 注册全局快捷键
        registerHotKey()
        installEventHandler()
    }

    // MARK: 状态栏图标与菜单
    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            // macOS 11+ 用 SF Symbol,低版本回退到 emoji 文本
            if #available(macOS 11.0, *) {
                button.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "ClipboardHistory")
            } else {
                button.title = "📋"
            }
        }

        let menu = NSMenu()
        menu.addItem(withTitle: "ClipboardHistory 运行中", action: nil, keyEquivalent: "")

        // 显示当前辅助功能权限状态,未授权时可点击跳转到设置页
        let hasAccess = AXIsProcessTrustedWithOptions(nil)
        let accessItem = NSMenuItem(
            title: hasAccess ? "辅助功能权限:已开启" : "辅助功能权限:未开启 (点击开启)",
            action: #selector(openAccessibilitySettings),
            keyEquivalent: ""
        )
        accessItem.target = self
        menu.addItem(accessItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: 辅助功能权限检查
    // CGEvent 模拟按键(Cmd+V)需要辅助功能权限;未授权时事件会被系统静默拦截,
    // 表现为"点击菜单后剪贴板变了但没有自动粘贴"。
    func checkAccessibilityAndPromptIfNeeded() {
        if AXIsProcessTrustedWithOptions(nil) {
            return
        }

        let alert = NSAlert()
        alert.messageText = "需要辅助功能权限"
        alert.informativeText = "点击历史项后自动粘贴需要模拟 Cmd+V 按键,请授予本应用辅助功能权限。\n\n系统设置 → 隐私与安全性 → 辅助功能 → 勾选 ClipboardHistory"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后再说")

        if alert.runModal() == .alertFirstButtonReturn {
            openAccessibilitySettings()
        }
    }

    @objc func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: - 剪贴板监听
func checkPasteboard() {
    let pb = NSPasteboard.general
    let count = pb.changeCount
    guard count != lastChangeCount else { return }
    lastChangeCount = count

    // 只记录文本
    guard let text = pb.string(forType: .string) else { return }

    // 如果是本程序点击菜单时主动写入剪贴板的内容,不参与排序,保持历史位置不变
    if text == internalPasteText {
        internalPasteText = nil
        return
    }
    internalPasteText = nil

    // 去重：若历史中已存在相同内容，先移除旧条目（LRU 语义，刚复制的浮到队首）
    history.removeAll { $0 == text }

    // FIFO 队列：新内容插入队首
    history.insert(text, at: 0)
    if history.count > maxHistory {
        history.removeLast()
    }
}

// MARK: - 模拟粘贴（Cmd+V）
// 通过 CGEvent 模拟按键，把已写入剪贴板的内容粘贴到当前前台应用。
// 首次使用时系统会提示授予"辅助功能"权限，否则事件无法送达其他应用。
func simulatePaste() {
    let source = CGEventSource(stateID: .combinedSessionState)
    let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
    keyDown?.flags = .maskCommand
    let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
    keyUp?.flags = .maskCommand
    keyDown?.post(tap: .cghidEventTap)
    keyUp?.post(tap: .cghidEventTap)
}

// MARK: - 历史项视图（自定义菜单项：左侧文本 + 右侧 × 删除按钮）
class ClipHistoryItemView: NSView {
    let text: String
    let onPaste: () -> Void
    let onDelete: () -> Void

    private let deleteWidth: CGFloat = 28
    private var isHoveringView = false
    private var isHoveringDelete = false
    private var trackingArea: NSTrackingArea?

    init(text: String, onPaste: @escaping () -> Void, onDelete: @escaping () -> Void) {
        self.text = text
        self.onPaste = onPaste
        self.onDelete = onDelete
        super.init(frame: NSRect(x: 0, y: 0, width: 340, height: 26))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let ta = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(ta)
        trackingArea = ta
    }

    private func pointInDelete(_ p: NSPoint) -> Bool {
        p.x >= bounds.maxX - deleteWidth
    }

    override func mouseEntered(with event: NSEvent) {
        isHoveringView = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHoveringView = false
        isHoveringDelete = false
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let inDelete = pointInDelete(p)
        if inDelete != isHoveringDelete {
            isHoveringDelete = inDelete
            needsDisplay = true
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if pointInDelete(p) {
            onDelete()
        } else {
            onPaste()
        }
    }

    override func mouseUp(with event: NSEvent) {
        // 占位:防止默认 mouseUp 触发菜单选中并意外关闭菜单
    }

    override func draw(_ dirtyRect: NSRect) {
        // 整行高亮（鼠标悬浮时）
        if isHoveringView {
            NSColor.controlAccentColor.setFill()
            bounds.fill()
        }

        // × 区域：悬浮时浅红底
        if isHoveringDelete {
            NSColor.systemRed.withAlphaComponent(0.25).setFill()
            NSRect(x: bounds.maxX - deleteWidth, y: 0, width: deleteWidth, height: bounds.height).fill()
        }

        // 文本（左侧，末尾省略）
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let textAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: isHoveringView ? NSColor.white : NSColor.labelColor,
            .paragraphStyle: para
        ]
        let textRect = NSRect(x: 10, y: 4, width: bounds.width - deleteWidth - 20, height: bounds.height - 8)
        (text as NSString).draw(in: textRect, withAttributes: textAttr)

        // × 字符（右侧）
        let xAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: isHoveringDelete ? NSColor.systemRed : (isHoveringView ? NSColor.white : NSColor.secondaryLabelColor)
        ]
        let xStr = NSAttributedString(string: "✕", attributes: xAttr)
        let size = xStr.size()
        let xRect = NSRect(
            x: bounds.maxX - deleteWidth / 2 - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        xStr.draw(in: xRect)
    }
}

// MARK: - 显示历史菜单（在鼠标位置弹出）
func showHistoryMenu() {
    // 记录当前前台应用，点击粘贴后切回它再模拟 Cmd+V
    let previousApp = NSWorkspace.shared.frontmostApplication
    NSApp.activate(ignoringOtherApps: true)

    let menu = NSMenu()
    menu.autoenablesItems = false

    if history.isEmpty {
        menu.addItem(withTitle: "暂无历史", action: nil, keyEquivalent: "")
    } else {
        for text in history {
            let item = NSMenuItem()
            let view = ClipHistoryItemView(
                text: text,
                onPaste: {
                    // 写剪贴板 → 关闭菜单 → 切回原前台应用 → 模拟 Cmd+V
                    // 先打标记,让轮询知道这次剪贴板变化是本程序触发的,不重排历史
                    internalPasteText = text
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(text, forType: .string)

                    menu.cancelTracking()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        previousApp?.activate(options: [])
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            simulatePaste()
                        }
                    }
                },
                onDelete: {
                    // 从历史和菜单中移除该项,不关闭菜单,可继续删
                    history.removeAll { $0 == text }
                    menu.removeItem(item)
                }
            )
            item.view = view
            menu.addItem(item)
        }
    }

    // 获取鼠标位置（屏幕坐标，原点在左下角）
    let mouseLocation = NSEvent.mouseLocation
    menu.popUp(positioning: nil, at: mouseLocation, in: nil)
}

// MARK: - 全局快捷键注册（Carbon）
func registerHotKey() {
    // 快捷键：Cmd+Shift+V
    let hotKeyID = EventHotKeyID(signature: OSType(0x434C4D47), id: 1) // "CLMG"
    _ = RegisterEventHotKey(
        UInt32(kVK_ANSI_V),
        UInt32(cmdKey | shiftKey),
        hotKeyID,
        GetApplicationEventTarget(),
        0,
        &hotKeyRef
    )
}

// MARK: - 事件处理器
func installEventHandler() {
    var eventType = EventTypeSpec(
        eventClass: OSType(kEventClassKeyboard),
        eventKind: UInt32(kEventHotKeyPressed)
    )

    InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
        var hkID = EventHotKeyID()
        GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hkID
        )

        // 检查是否是我们注册的快捷键
        if hkID.signature == OSType(0x434C4D47) && hkID.id == 1 {
            // 切换到主线程显示菜单
            DispatchQueue.main.async {
                showHistoryMenu()
            }
        }
        return noErr
    }, 1, &eventType, nil, nil)
}

// MARK: - 主程序入口
// NSApplication.delegate 在 SDK 中是 weak，必须由顶层全局强引用持有，
// 否则局部 let 会在后续重构（如把启动逻辑挪走）时被提前释放，导致菜单点击无响应。
let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.run()