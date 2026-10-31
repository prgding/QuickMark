import AppKit
import SwiftUI
import ScreenCaptureKit
import Carbon
import UniformTypeIdentifiers
import QuartzCore

final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject, NSMenuDelegate {
    @Published var hasPermission: Bool
    @Published var shortcutAvailable = true
    private var statusItem: NSStatusItem!
    private var welcome: NSWindow?
    private(set) var overlays: [CaptureWindow] = []
    private(set) var pinnedCaptures: [PinnedCapture] = []
    private weak var previousKeyWindow: NSWindow?
    private let screenPermission: () -> Bool
    private let captureScreens: @MainActor ([CaptureDisplay]) async throws -> [(Int, CGImage)]
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var isCapturing = false
    private var isDemo = false
    private var toast: NSPanel?
    private var screenObserver: NSObjectProtocol?
    private var captureGeneration = 0

    init(screenPermission: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
         captureScreens: @escaping @MainActor ([CaptureDisplay]) async throws -> [(Int, CGImage)] = { try await ScreenCaptureService.capture($0) }) {
        self.screenPermission = screenPermission
        self.captureScreens = captureScreens
        hasPermission = screenPermission()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureMainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "crop", accessibilityDescription: "QuickMark 截图")
        statusItem.button?.toolTip = "QuickMark · ⌘⇧4 截图"
        let menu = NSMenu()
        menu.delegate = self
        let capture = NSMenuItem(title: "截取区域", action: #selector(captureAction), keyEquivalent: "4")
        capture.keyEquivalentModifierMask = [.command, .shift]
        capture.target = self
        menu.addItem(capture)
        addMenuItem(menu, title: "练习标注", action: #selector(demoAction))
        menu.addItem(.separator())
        addMenuItem(menu, title: "使用说明…", action: #selector(showWelcome))
        addMenuItem(menu, title: "屏幕录制权限…", action: #selector(openPermissionSettings))
        menu.addItem(.separator())
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let releaseDate = (Bundle.main.object(forInfoDictionaryKey: "QuickMarkReleaseDate") as? Date)
            .map { formatter.string(from: $0) } ?? "未记录"
        for title in ["当前版本：\(version)", "发布时间：\(releaseDate)"] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())
        addMenuItem(menu, title: "退出 QuickMark", action: #selector(quit), key: "q")
        statusItem.menu = menu
        registerHotKey()
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in self?.finishCapture() }
        if CommandLine.arguments.contains("--demo") { startDemo() }
        else if !UserDefaults.standard.bool(forKey: "hasLaunched") || CommandLine.arguments.contains("--welcome") {
            UserDefaults.standard.set(true, forKey: "hasLaunched")
            showWelcome()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !isCapturing, overlays.isEmpty { showWelcome() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    private func configureMainMenu() {
        let main = NSMenu()
        let application = NSMenuItem()
        let appMenu = NSMenu()
        addMenuItem(appMenu, title: "退出 QuickMark", action: #selector(quit), key: "q")
        application.submenu = appMenu
        main.addItem(application)
        let file = NSMenuItem(title: "文件", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "文件")
        fileMenu.addItem(NSMenuItem(title: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        file.submenu = fileMenu
        main.addItem(file)
        let edit = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "编辑")
        for (title, selector, key) in [("剪切", #selector(NSText.cut(_:)), "x"),
            ("复制", #selector(NSText.copy(_:)), "c"), ("粘贴", #selector(NSText.paste(_:)), "v"),
            ("全选", #selector(NSText.selectAll(_:)), "a")] {
            editMenu.addItem(NSMenuItem(title: title, action: selector, keyEquivalent: key))
        }
        edit.submenu = editMenu
        main.addItem(edit)
        NSApp.mainMenu = main
    }

    private func addMenuItem(_ menu: NSMenu, title: String, action: Selector, key: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }

    func menuWillOpen(_ menu: NSMenu) { hasPermission = CGPreflightScreenCaptureAccess() }

    private func registerHotKey() {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let handlerResult = InstallEventHandler(GetApplicationEventTarget(), { _, _, data in
            guard let data else { return noErr }
            let app = Unmanaged<AppDelegate>.fromOpaque(data).takeUnretainedValue()
            DispatchQueue.main.async { app.startCapture() }
            return noErr
        }, 1, &event, pointer, &eventHandler)
        let identifier = EventHotKeyID(signature: 0x514D4152, id: 1)
        let result = RegisterEventHotKey(UInt32(kVK_ANSI_4), UInt32(cmdKey | shiftKey), identifier,
                                         GetApplicationEventTarget(), 0, &hotKey)
        shortcutAvailable = result == noErr && handlerResult == noErr
    }

    @objc private func captureAction() { startCapture() }
    @objc private func demoAction() { startDemo() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc func showWelcome() {
        hasPermission = CGPreflightScreenCaptureAccess()
        if welcome == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 530),
                                  styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "QuickMark"
            window.titlebarAppearsTransparent = true
            window.animationBehavior = .none
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: WelcomeView(app: self))
            window.center()
            welcome = window
        }
        welcome?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openPermissionSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    func requestPermission() {
        hasPermission = CGPreflightScreenCaptureAccess()
        if !hasPermission { hasPermission = CGRequestScreenCaptureAccess() }
        if !hasPermission { openPermissionSettings() }
    }

    func startCapture() {
        guard !isCapturing, overlays.isEmpty else { return }
        hasPermission = screenPermission()
        if !hasPermission {
            hasPermission = CGRequestScreenCaptureAccess()
            if !hasPermission {
                showWelcome()
                let alert = NSAlert()
                alert.messageText = "允许 QuickMark 截取屏幕"
                alert.informativeText = "请在「系统设置 → 隐私与安全性 → 屏幕与系统音频录制」中允许 QuickMark，然后再次截图。如果系统要求重新打开应用，请先退出再启动。也可以先使用练习画布。"
                alert.addButton(withTitle: "打开系统设置")
                alert.addButton(withTitle: "稍后")
                if alert.runModal() == .alertFirstButtonReturn { openPermissionSettings() }
                return
            }
        }
        isCapturing = true
        isDemo = false
        captureGeneration += 1
        let generation = captureGeneration
        let started = CACurrentMediaTime()
        // Capture the desktop as it is, including pins and their shadows. Hiding
        // and restoring windows here changes the scene and produces visible flashes.
        Task { @MainActor in
            do {
                let targets = WindowTarget.snapshot()
                let screens = NSScreen.screens
                let primaryTop = screens.first?.frame.maxY ?? 0
                let displays = screens.enumerated().compactMap { index, screen -> CaptureDisplay? in
                    guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else { return nil }
                    return CaptureDisplay(index: index, id: id, frame: CaptureDisplay.quartzFrame(screen.frame, primaryTop: primaryTop),
                                          scale: screen.backingScaleFactor)
                }
                let images = try await self.captureScreens(displays)
                guard generation == self.captureGeneration else { return }
                let captured = CACurrentMediaTime()
                let captures = images.map { index, image in
                    let screen = screens[index]
                    return (screen, NSImage(cgImage: image, size: screen.frame.size), CGFloat(image.width) / screen.frame.width)
                }
                guard !captures.isEmpty else { throw CaptureError.noDisplay }
                self.present(captures, targets: targets)
                self.recordStartup(started: started, captured: captured, displays: displays)
            } catch {
                guard generation == self.captureGeneration else { return }
                isCapturing = false
                showWelcome()
                let alert = NSAlert()
                alert.messageText = "暂时无法截图"
                alert.informativeText = "\(error.localizedDescription)\n\n请检查屏幕录制权限；更改权限后可能需要重新打开 QuickMark。"
                alert.runModal()
            }
        }
    }

    private func recordStartup(started: CFTimeInterval, captured: CFTimeInterval, displays: [CaptureDisplay]) {
        guard let index = CommandLine.arguments.firstIndex(of: "--startup-report"), CommandLine.arguments.count > index + 1 else { return }
        let report: [String: Any] = ["captureMs": (captured - started) * 1000,
                                    "readyMs": (CACurrentMediaTime() - started) * 1000,
                                    "displayCount": displays.count,
                                    "pixels": displays.map { [$0.pixelWidth, $0.pixelHeight] },
                                    "measures": "Request to overlay submission, not physical input-to-photon latency; no screenshot saved"]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]), options: .atomic)
        }
    }

    func startDemo() {
        guard !isCapturing, overlays.isEmpty, let screen = NSScreen.main else { return }
        isDemo = true
        welcome?.orderOut(nil)
        toast?.orderOut(nil)
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let rect = CGRect(x: screen.frame.minX + screen.frame.width * 0.18,
                          y: primaryTop - screen.frame.maxY + screen.frame.height * 0.22,
                          width: screen.frame.width * 0.64, height: screen.frame.height * 0.56)
        present([(screen, CaptureRenderer.demoImage(size: screen.frame.size), screen.backingScaleFactor)],
                targets: [WindowTarget(id: 1, name: "练习窗口", frame: rect)])
    }

    private func present(_ captures: [(NSScreen, NSImage, CGFloat)], targets: [WindowTarget]) {
        previousKeyWindow = NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? NSApp.keyWindow : nil
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for (screen, image, scale) in captures {
            let window = CaptureWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.level = .screenSaver
            window.animationBehavior = .none
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isReleasedWhenClosed = false
            window.hasShadow = false
            window.isOpaque = true
            window.backgroundColor = .black
            window.acceptsMouseMovedEvents = true
            let view = CaptureView(frame: NSRect(origin: .zero, size: screen.frame.size), image: image, scale: scale,
                                   targets: targets, screenFrame: screen.frame, primaryTop: NSScreen.screens.first?.frame.maxY ?? 0)
            view.onCancel = { [weak self] in self?.finishCapture() }
            view.onSelected = { [weak self, weak window] in
                guard let self, let window else { return }
                for other in self.overlays where other !== window { other.orderOut(nil) }
            }
            view.onReselect = { [weak self] in
                guard let self else { return }
                for overlay in self.overlays {
                    (overlay.contentView as? CaptureView)?.resetSelection()
                    overlay.orderFrontRegardless()
                }
            }
            view.onCopy = { [weak self] bitmap in self?.copyToClipboard(bitmap) }
            view.onSave = { [weak self, weak window] bitmap in self?.savePNG(bitmap, window: window) }
            view.onQuickSave = { [weak self] bitmap in self?.saveToDesktop(bitmap, endCapture: true) }
            view.onPin = { [weak self] content, frame in self?.pinCapture(content, frame: frame) }
            window.contentView = view
            view.prepareForPresentation()
            view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            overlays.append(window)
        }
        CATransaction.commit()
        CATransaction.flush()
        // Nonactivating panels take capture input without changing the foreground
        // application, its menu bar, or its window ordering.
        for window in overlays { window.orderFrontRegardless() }
        let mouse = NSEvent.mouseLocation
        let active = overlays.first(where: { $0.frame.contains(mouse) }) ?? overlays.first
        active?.makeKeyAndOrderFront(nil)
        active?.makeFirstResponder(active?.contentView)
        for window in overlays { (window.contentView as? CaptureView)?.startRendering() }
        isCapturing = false
    }

    private func copyToClipboard(_ bitmap: NSBitmapImageRep, endCapture: Bool = true) {
        guard let png = bitmap.representation(using: .png, properties: [:]) else { NSSound.beep(); return }
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        if let tiff = bitmap.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        let board = NSPasteboard.general
        board.clearContents()
        if board.writeObjects([item]) {
            if endCapture { finishCapture() }
            showToast("已复制 · ⌘V 粘贴")
        } else { NSSound.beep() }
    }

    func pinCapture(_ content: PinnedContent, frame: NSRect) {
        let pin = PinnedCapture(content: content, frame: frame)
        pin.onClose = { [weak self, weak pin] in self?.pinnedCaptures.removeAll { $0 === pin } }
        pin.onCopy = { [weak self] image in self?.copyToClipboard(image, endCapture: false) }
        pin.onQuickSave = { [weak self] image in self?.saveToDesktop(image, endCapture: false) }
        pinnedCaptures.append(pin)
        pin.show()
        finishCapture()
    }

    private func savePNG(_ bitmap: NSBitmapImageRep, window: CaptureWindow?) {
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }
        window?.orderOut(nil)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        panel.nameFieldStringValue = "QuickMark_\(formatter.string(from: Date())).png"
        panel.title = "保存截图"
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try png.write(to: url, options: .atomic)
                finishCapture()
                showToast("PNG 已保存")
            } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
                window?.makeKeyAndOrderFront(nil)
            }
        } else { window?.makeKeyAndOrderFront(nil) }
    }

    private func saveToDesktop(_ bitmap: NSBitmapImageRep, endCapture: Bool) {
        do {
            let desktop = try FileManager.default.url(for: .desktopDirectory, in: .userDomainMask,
                                                       appropriateFor: nil, create: false)
            _ = try PNGExport.save(bitmap, to: desktop)
            if endCapture { finishCapture() }
            showToast("已保存到桌面")
        } catch {
            // A failed save must leave the selection and annotations available to retry.
            let visible = overlays.filter(\.isVisible)
            for overlay in visible { overlay.orderOut(nil) }
            let alert = NSAlert(error: error)
            alert.messageText = "未能保存到桌面"
            alert.runModal()
            for overlay in visible { overlay.makeKeyAndOrderFront(nil) }
        }
    }

    func finishCapture() {
        guard isCapturing || !overlays.isEmpty || isDemo else { return }
        captureGeneration += 1
        let wasDemo = isDemo
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for window in overlays {
            (window.contentView as? CaptureView)?.stopRendering()
            window.orderOut(nil)
        }
        overlays.removeAll()
        isCapturing = false
        isDemo = false
        if wasDemo { showWelcome() }
        else if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
                let previousKeyWindow, previousKeyWindow.isVisible {
            previousKeyWindow.makeKey()
        }
        previousKeyWindow = nil
        CATransaction.commit()
    }

    private func showToast(_ message: String) {
        toast?.orderOut(nil)
        guard let screen = NSScreen.main else { return }
        let frame = NSRect(x: screen.visibleFrame.midX - 120, y: screen.visibleFrame.maxY - 78, width: 240, height: 44)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.animationBehavior = .none
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView:
            HStack(spacing: 10) { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green); Text(message).font(.system(size: 13, weight: .medium)) }
                .frame(width: 240, height: 44).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)))
        panel.orderFrontRegardless()
        toast = panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak panel] in panel?.orderOut(nil) }
    }
}

enum CaptureError: LocalizedError {
    case noDisplay
    var errorDescription: String? { "没有找到可以截取的显示器。" }
}

struct WelcomeView: View {
    @ObservedObject var app: AppDelegate
    private let ink = Color(red: 0.17, green: 0.20, blue: 0.18)
    private let orange = Color(red: 0.88, green: 0.29, blue: 0.12)
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "crop").font(.system(size: 21, weight: .bold)).foregroundStyle(orange)
                Text("QuickMark").font(.system(size: 18, weight: .bold, design: .rounded))
                Spacer()
                Text("为更少的打断而做").font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(.bottom, 31)
            Text("框一下，标重点。\n复制，继续工作。").font(.system(size: 36, weight: .bold)).lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
            Text("十字光标 · 窗口高亮 · 按显示器刷新率同步").font(.system(size: 14)).foregroundStyle(.secondary).padding(.top, 14)
            HStack(spacing: 12) {
                step("01", symbol: "selection.pin.in.out", title: "选取", subtitle: "单击窗口，或拖动框选")
                step("02", symbol: "arrow.up.right", title: "标注", subtitle: "箭头 · 方框 · 画笔 · 文字")
                step("03", symbol: "doc.on.doc", title: "复制 / 固定", subtitle: "双击复制 · T 固定 · ⌘T 文字")
            }.padding(.top, 26)
            HStack(spacing: 12) {
                Button(action: { app.startCapture() }) {
                    HStack { Image(systemName: "crop"); Text("开始截图"); Text("⌘⇧4").opacity(0.65) }
                        .font(.system(size: 13, weight: .semibold)).padding(.horizontal, 18).frame(height: 40)
                        .background(ink, in: RoundedRectangle(cornerRadius: 9)).foregroundStyle(.white)
                }.buttonStyle(.plain)
                Button(action: { app.startDemo() }) {
                    Text("先试试标注 →").font(.system(size: 13, weight: .medium)).foregroundStyle(ink).padding(10)
                }.buttonStyle(.plain)
                Spacer()
            }.padding(.top, 24)
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: app.hasPermission ? "checkmark.circle.fill" : "lock.shield").foregroundStyle(app.hasPermission ? .green : .secondary)
                Text(app.hasPermission ? "屏幕录制权限已开启。关闭此窗口后，可从菜单栏或快捷键截图。" : "首次截图需要屏幕录制权限。练习标注无需授权；图片仅在本机处理。")
                    .fixedSize(horizontal: false, vertical: true)
                if !app.hasPermission {
                    Button("设置") { app.requestPermission() }.buttonStyle(.plain).foregroundStyle(orange)
                }
            }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 20)
            if !app.shortcutAvailable {
                Text("⌘⇧4 已被其他应用占用，请使用菜单栏的「截取区域」。")
                    .font(.system(size: 11)).foregroundStyle(orange).padding(.top, 8)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 38).padding(.top, 42).padding(.bottom, 22)
        .frame(width: 660, height: 530)
        .foregroundStyle(ink)
        .background(Color(red: 0.97, green: 0.96, blue: 0.93))
        .preferredColorScheme(.light)
    }
    private func step(_ number: String, symbol: String, title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack { Text(number).font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary); Spacer(); Image(systemName: symbol).foregroundStyle(orange) }
            Text(title).font(.system(size: 16, weight: .semibold))
            Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(15).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 12))
    }
}
