import AppKit
import QuartzCore

final class CaptureWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask.union(.nonactivatingPanel), backing: backing, defer: flag)
        hidesOnDeactivate = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func sendEvent(_ event: NSEvent) {
        // Selecting a window can reveal the toolbar under the pointer between clicks.
        if event.type == .leftMouseDown, let view = contentView as? CaptureView,
           view.copyDoubleClick(with: event) { return }
        if event.type == .otherMouseDown, let view = contentView as? CaptureView,
           view.quickSave(with: event) { return }
        super.sendEvent(event)
    }
}

// Informational labels must not intercept the first drag over the canvas.
final class CaptureLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class CaptureView: NSView, NSTextFieldDelegate {
    let screenshot: NSImage
    let pixelScale: CGFloat
    var onCancel: (() -> Void)?
    var onSelected: (() -> Void)?
    var onReselect: (() -> Void)?
    var onCopy: ((NSBitmapImageRep) -> Void)?
    var onSave: ((NSBitmapImageRep) -> Void)?
    var onQuickSave: ((NSBitmapImageRep) -> Void)?
    var onPin: ((PinnedContent, NSRect) -> Void)?
    private(set) var selection: NSRect? { didSet { geometryDirty = true; controlsDirty = true } }
    private var anchor: NSPoint?
    private(set) var marks: [Mark] = [] { didSet { marksDirty = true; controlsDirty = true } }
    private struct CanvasState {
        let selection: NSRect?
        let marks: [Mark]
        let selectedRectangle: Int?
    }
    private enum EditTarget: Equatable { case selection, mark(Int) }
    private struct RectangleDrag {
        let target: EditTarget
        let hit: RectangleHit
        let original: CGRect
        let start: CGPoint
        let before: CanvasState
    }
    private var undoStates: [CanvasState] = []
    private var redoStates: [CanvasState] = []
    private var rectangleDrag: RectangleDrag?
    private var selectedRectangle: Int? { didSet { controlsDirty = true } }
    private var hoveredRectangle: Int? { didSet { if oldValue != hoveredRectangle { controlsDirty = true } } }
    private var controlsDirty = true
    private var draft: Mark? { didSet { draftDirty = true } }
    private(set) var tool: MarkTool = .rectangle
    private var color: NSColor = .systemRed
    private var strokeWidth: CGFloat = 3
    private var textEditor: NSTextField?
    private var textOrigin: NSPoint?
    private var lastCanvasClick: (point: NSPoint, time: TimeInterval)?
    private var clickDotIndex: Int?
    private let toolbar = NSView()
    private var toolButtons: [MarkTool: NSButton] = [:]
    private var colorButtons: [NSButton] = []
    private var undoButton: NSButton!
    private var redoButton: NSButton!
    private let hint = CaptureLabel(labelWithString: "双击窗口复制 · 单击选取 · 拖动框选 · G 辅助线 · F 帧率 · Esc 退出")
    private let dimensions = CaptureLabel(labelWithString: "")
    private let performance = CaptureLabel(labelWithString: "正在测量显示节奏…")
    let surface: CaptureSurface
    let windowTargets: [WindowTarget]
    private var hovered: WindowTarget? { didSet { if oldValue != hovered { geometryDirty = true } } }
    private var geometryDirty = true
    private var marksDirty = true
    private var draftDirty = true
    private var guidesEnabled = true
    private var frameLink: CADisplayLink?
    private var frameDriver: FrameDriver?
    private var lastHUD = 0.0
    private var lastDimensions = 0.0
    private(set) var metrics = FrameMetrics()
    private(set) var requestedHz = 0
    var benchmarkMotion = false
    private var benchmarkStart = CACurrentMediaTime()

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func shouldDelayWindowOrdering(for event: NSEvent) -> Bool { false }

    init(frame: NSRect, image: NSImage, scale: CGFloat, targets: [WindowTarget] = [], screenFrame: CGRect = .zero, primaryTop: CGFloat = 0) {
        screenshot = image
        pixelScale = scale
        surface = CaptureSurface(frame: NSRect(origin: .zero, size: frame.size), image: image, scale: scale)
        let localBounds = CGRect(origin: .zero, size: frame.size)
        windowTargets = targets.compactMap { target in
            let rect = target.localFrame(screen: screenFrame, primaryTop: primaryTop).intersection(localBounds)
            guard !rect.isNull, rect.width >= 8, rect.height >= 8 else { return nil }
            return WindowTarget(id: target.id, name: target.name, frame: rect)
        }
        super.init(frame: frame)
        appearance = NSAppearance(named: .darkAqua)
        addSubview(surface)
        configureToolbar()
        hint.font = .systemFont(ofSize: 14, weight: .medium)
        hint.textColor = .white
        hint.alignment = .center
        hint.drawsBackground = true
        hint.backgroundColor = .black.withAlphaComponent(0.72)
        hint.wantsLayer = true
        hint.layer?.cornerRadius = 10
        hint.layer?.masksToBounds = true
        hint.frame = NSRect(x: (frame.width - 590) / 2, y: 36, width: 590, height: 32)
        addSubview(hint)
        dimensions.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        dimensions.textColor = .white
        dimensions.drawsBackground = true
        dimensions.backgroundColor = .black.withAlphaComponent(0.8)
        dimensions.alignment = .center
        dimensions.isHidden = true
        addSubview(dimensions)
        performance.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        performance.textColor = .white
        performance.drawsBackground = true
        performance.backgroundColor = .black.withAlphaComponent(0.75)
        performance.maximumNumberOfLines = 2
        performance.frame = NSRect(x: frame.width - 376, y: 80, width: 360, height: 39)
        addSubview(performance)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var drawingCursor: NSCursor {
        if tool == .text { return .iBeam }
        return tool == .rectangle ? CapturePointer.drawing(color: color) : CapturePointer.crosshair
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: CapturePointer.crosshair)
        if let selection {
            addCursorRect(selection, cursor: drawingCursor)
        }
    }

    private func rectangleHit(at point: CGPoint) -> (EditTarget, RectangleHit, CGRect)? {
        guard let selection else { return nil }
        if let hit = RectangleEditing.hit(point, rect: selection, cornerBrackets: true) { return (.selection, hit, selection) }
        guard selection.contains(point) else { return nil }
        // Topmost rectangle wins. Its interior remains available for drawing another mark.
        for index in marks.indices.reversed() {
            guard let rect = marks[index].rectangle,
                  let hit = RectangleEditing.hit(point, rect: rect, edgeTolerance: max(4, marks[index].width / 2 + 2)) else { continue }
            return (.mark(index), hit, rect)
        }
        return nil
    }

    private func updateEditHover(at point: CGPoint) {
        guard selection != nil, anchor == nil, draft == nil, textEditor == nil,
              rectangleDrag == nil else { return }
        // Native controls retain their own cursor and mouse handling.
        if !toolbar.isHidden && toolbar.frame.contains(point) { hoveredRectangle = nil; return }
        let hit = rectangleHit(at: point)
        if case .mark(let index) = hit?.0 { hoveredRectangle = index } else { hoveredRectangle = nil }
        if let hit { CapturePointer.show(CapturePointer.editing(hit.1)) }
        else if bounds.contains(point) {
            CapturePointer.show(selection?.contains(point) == true ? drawingCursor : CapturePointer.crosshair)
        }
    }

    private func currentState() -> CanvasState {
        CanvasState(selection: selection, marks: marks, selectedRectangle: selectedRectangle)
    }
    private func rememberChange(_ before: CanvasState? = nil) {
        undoStates.append(before ?? currentState()); redoStates.removeAll()
    }
    private func restore(_ state: CanvasState) {
        selection = state.selection; marks = state.marks; selectedRectangle = state.selectedRectangle
        hoveredRectangle = nil; lastCanvasClick = nil; clickDotIndex = nil; draft = nil
        placeToolbar(); updateDimensions(); updateTools(); refreshLayers()
    }
    private func updateRectangleDrag(to point: CGPoint) {
        guard let drag = rectangleDrag else { return }
        let limits: CGRect
        switch drag.target {
        case .selection: limits = bounds
        case .mark: limits = (selection ?? bounds).union(drag.original).intersection(bounds)
        }
        let settledPoint = hypot(point.x - drag.start.x, point.y - drag.start.y) < 2 ? drag.start : point
        var rect = RectangleEditing.transform(drag.original, hit: drag.hit, from: drag.start, to: settledPoint,
                                               within: limits, minimum: drag.target == .selection ? 8 : 4)
        // Align both edges to physical pixels; crop dimensions and exports stay consistent.
        if drag.target == .selection {
            let x = (rect.minX * pixelScale).rounded() / pixelScale
            let y = (rect.minY * pixelScale).rounded() / pixelScale
            rect = CGRect(x: x, y: y, width: (rect.maxX * pixelScale).rounded() / pixelScale - x,
                          height: (rect.maxY * pixelScale).rounded() / pixelScale - y)
            if selection != rect { selection = rect }
        } else if case .mark(let index) = drag.target, marks.indices.contains(index), marks[index].rectangle != rect {
            marks[index].points = [rect.origin, CGPoint(x: rect.maxX, y: rect.maxY)]
        }
    }

    func startRendering() {
        guard frameLink == nil, let screen = window?.screen else { return }
        requestedHz = max(1, screen.maximumFramesPerSecond)
        let driver = FrameDriver(self)
        frameDriver = driver
        let link = displayLink(target: driver, selector: #selector(FrameDriver.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: Float(requestedHz), maximum: Float(requestedHz), preferred: Float(requestedHz))
        link.add(to: .main, forMode: .common)
        frameLink = link
        benchmarkStart = CACurrentMediaTime()
    }

    func prepareForPresentation() {
        guard let window else { return }
        let point = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        hovered = target(at: point)
        flushLayers()
        surface.updateGuides(point: bounds.contains(point) ? point : nil,
                             visible: guidesEnabled && bounds.contains(point))
        CATransaction.commit()
    }

    func stopRendering() { frameLink?.invalidate(); frameLink = nil; frameDriver = nil }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { stopRendering() }
        super.viewWillMove(toWindow: newWindow)
    }

    func displayTick(_ link: CADisplayLink) {
        let begin = CACurrentMediaTime()
        guard let window else { return }
        var point = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        if benchmarkMotion {
            let phase = begin - benchmarkStart
            point = CGPoint(x: bounds.width * (0.5 + 0.42 * sin(phase * 2.7)),
                            y: bounds.height * (0.5 + 0.4 * cos(phase * 1.9)))
        }
        let inside = bounds.contains(point)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Sample the latest pointer each display tick, not the potentially coalesced mouseMoved stream.
        if rectangleDrag != nil {
            updateRectangleDrag(to: point)
            if let drag = rectangleDrag { CapturePointer.show(CapturePointer.editing(drag.hit, dragging: true)) }
            if begin - lastDimensions > 1.0 / 30 { updateDimensions(); lastDimensions = begin }
        } else if let anchor {
            let clipped = clamp(point)
            if hypot(clipped.x - anchor.x, clipped.y - anchor.y) >= 3 {
                selection = rectBetween(anchor, clipped)
                if begin - lastDimensions > 1.0 / 30 { updateDimensions(); lastDimensions = begin }
            }
        } else if selection == nil {
            hovered = target(at: point)
        } else if draft != nil, tool != .pen, let first = draft?.points.first, let selection {
            let clipped = CGPoint(x: min(max(point.x, selection.minX), selection.maxX), y: min(max(point.y, selection.minY), selection.maxY))
            draft?.points = [first, clipped]
        }
        updateEditHover(at: point)
        if draft != nil { CapturePointer.show(drawingCursor) }
        flushLayers()
        let showGuides = guidesEnabled && inside && (selection == nil || anchor != nil)
        surface.updateGuides(point: inside ? point : nil, visible: showGuides)
        CATransaction.commit()
        let cost = CACurrentMediaTime() - begin
        metrics.record(now: begin, cost: cost, targetInterval: link.targetTimestamp - link.timestamp)
        if !performance.isHidden, begin - lastHUD >= 0.5 {
            lastHUD = begin
            if metrics.times.count < 2 { performance.stringValue = "屏幕 \(requestedHz) Hz · 正在测量…" }
            else {
                performance.stringValue = String(format: "屏幕 %d Hz · 回调 %.0f/s · p95 %.2f ms\n更新 CPU p95 %.2f ms · F 隐藏", requestedHz, metrics.callbackFPS,
                    metrics.percentile(metrics.intervals, 0.95) * 1000, metrics.percentile(metrics.work, 0.95) * 1000)
            }
        }
    }

    private func flushLayers() {
        if geometryDirty {
            let hovering = selection == nil && anchor == nil
            surface.updateSelection(selection ?? (hovering ? hovered?.frame : nil), hovering: hovering, name: hovered?.name)
            geometryDirty = false
        }
        if marksDirty { surface.updateMarks(marks); marksDirty = false }
        if draftDirty { surface.updateDraft(draft); draftDirty = false }
        if controlsDirty {
            let index = hoveredRectangle ?? selectedRectangle
            let rectangle = index.flatMap { marks.indices.contains($0) ? marks[$0].rectangle : nil }
            surface.updateEditingControls(selection: anchor == nil ? selection : nil,
                                          rectangle: draft == nil ? rectangle : nil)
            controlsDirty = false
        }
    }

    private func refreshLayers() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        flushLayers()
        CATransaction.commit()
    }
    private func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), bounds.width), y: min(max(point.y, 0), bounds.height))
    }

    func target(at point: CGPoint) -> WindowTarget? {
        guard bounds.contains(point) else { return nil }
        return WindowTarget.hit(point, in: windowTargets) ?? WindowTarget(id: 0, name: "整块屏幕", frame: bounds)
    }

    private func button(_ symbol: String, title: String = "", tooltip: String, action: Selector, width: CGFloat = 34) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .texturedRounded
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        button.contentTintColor = .white
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.toolTip = tooltip
        button.setAccessibilityLabel(tooltip)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: width).isActive = true
        button.heightAnchor.constraint(equalToConstant: 32).isActive = true
        return button
    }

    private func configureToolbar() {
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = NSColor(calibratedWhite: 0.12, alpha: 0.98).cgColor
        toolbar.layer?.cornerRadius = 13
        toolbar.layer?.borderWidth = 1
        toolbar.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        toolbar.isHidden = true
        addSubview(toolbar)
        let top = NSStackView()
        top.orientation = .horizontal
        top.spacing = 5
        for (index, item) in MarkTool.allCases.enumerated() {
            let b = button(item.symbol, tooltip: "\(item.title)（\(item.shortcut)）", action: #selector(selectTool(_:)))
            if item == .text { b.image = nil; b.title = "T"; b.font = .systemFont(ofSize: 17, weight: .semibold) }
            b.tag = index
            toolButtons[item] = b
            top.addArrangedSubview(b)
        }
        top.addArrangedSubview(separator())
        undoButton = button("arrow.uturn.backward", tooltip: "撤销（⌘Z）", action: #selector(undoMark))
        redoButton = button("arrow.uturn.forward", tooltip: "重做（⇧⌘Z）", action: #selector(redoMark))
        top.addArrangedSubview(undoButton)
        top.addArrangedSubview(redoButton)
        top.addArrangedSubview(button("selection.pin.in.out", tooltip: "重新框选", action: #selector(reselect)))
        top.addArrangedSubview(button("pin", tooltip: "固定在屏幕（T）", action: #selector(pinCapture)))
        top.addArrangedSubview(button("square.and.arrow.down", tooltip: "保存 PNG（⌘S）", action: #selector(save)))
        let copy = button("doc.on.doc", title: "复制 ↵", tooltip: "复制并退出（双击 / Enter / ⌘C）", action: #selector(copyCapture), width: 88)
        copy.contentTintColor = .systemOrange
        top.addArrangedSubview(copy)
        top.addArrangedSubview(button("xmark", tooltip: "取消（Esc）", action: #selector(cancel)))
        let bottom = NSStackView()
        bottom.orientation = .horizontal
        bottom.spacing = 10
        for (index, c) in palette.enumerated() {
            let b = NSButton(title: "", target: self, action: #selector(selectColor(_:)))
            b.isBordered = false
            b.tag = index
            b.image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { r in
                c.setFill(); NSBezierPath(ovalIn: r.insetBy(dx: 3, dy: 3)).fill(); return true
            }
            b.toolTip = ["红色", "橙色", "蓝色", "绿色", "白色", "黑色"][index]
            b.setAccessibilityLabel(b.toolTip)
            b.wantsLayer = true
            b.layer?.cornerRadius = 12
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 24).isActive = true
            b.heightAnchor.constraint(equalToConstant: 24).isActive = true
            colorButtons.append(b)
            bottom.addArrangedSubview(b)
        }
        bottom.addArrangedSubview(separator())
        let widths = NSSegmentedControl(labels: ["细", "中", "粗"], trackingMode: .selectOne, target: self, action: #selector(selectWidth(_:)))
        widths.selectedSegment = 1
        widths.segmentStyle = .rounded
        widths.controlSize = .small
        widths.setAccessibilityLabel("标注线宽")
        bottom.addArrangedSubview(widths)
        let label = NSTextField(labelWithString: "双击复制 · 中键存桌面 · T 固定")
        label.font = .systemFont(ofSize: 10)
        label.textColor = .secondaryLabelColor
        bottom.addArrangedSubview(label)
        let rows = NSStackView(views: [top, bottom])
        rows.orientation = .vertical
        rows.spacing = 6
        rows.alignment = .leading
        rows.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(rows)
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 12),
            rows.topAnchor.constraint(equalTo: toolbar.topAnchor, constant: 8),
            rows.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -12),
            rows.bottomAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: -10)
        ])
        updateTools()
    }

    private func separator() -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.15).cgColor
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: 1).isActive = true
        view.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return view
    }
    private var palette: [NSColor] { [.systemRed, .systemOrange, .systemBlue, .systemGreen, .white, .black] }

    private func updateTools() {
        for (item, button) in toolButtons {
            button.contentTintColor = item == tool ? .systemOrange : .white
            button.wantsLayer = true
            button.layer?.cornerRadius = 6
            button.layer?.backgroundColor = item == tool ? NSColor.white.withAlphaComponent(0.1).cgColor : NSColor.clear.cgColor
        }
        for (index, button) in colorButtons.enumerated() {
            button.layer?.borderWidth = palette[index] == color ? 1.5 : 0
            button.layer?.borderColor = NSColor.white.cgColor
        }
        undoButton?.isEnabled = !undoStates.isEmpty
        redoButton?.isEnabled = !redoStates.isEmpty
        window?.invalidateCursorRects(for: self)
    }

    @discardableResult func copyDoubleClick(with event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        guard event.type == .leftMouseDown, event.clickCount == 2,
              anchor == nil, rectangleDrag == nil, textEditor == nil,
              let selection, selection.contains(point), let previous = lastCanvasClick,
              event.timestamp - previous.time >= 0,
              event.timestamp - previous.time <= NSEvent.doubleClickInterval,
              hypot(point.x - previous.point.x, point.y - previous.point.y) <= 4 else { return false }
        // A pen's first click may have made a dot. A double-click is a copy gesture.
        if let index = clickDotIndex, index == marks.count - 1 {
            marks.removeLast(); _ = undoStates.popLast()
        }
        draft = nil
        lastCanvasClick = nil
        clickDotIndex = nil
        copyCapture()
        return true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(self)
        if copyDoubleClick(with: event) { return }
        let point = convert(event.locationInWindow, from: nil)
        if selection != nil, let (target, hit, rect) = rectangleHit(at: point) {
            commitText()
            let before = currentState()
            if case .mark(let index) = target { selectedRectangle = index }
            else { selectedRectangle = nil }
            hoveredRectangle = nil
            rectangleDrag = RectangleDrag(target: target, hit: hit, original: rect, start: point, before: before)
            lastCanvasClick = nil; clickDotIndex = nil
            toolbar.isHidden = true
            CapturePointer.show(CapturePointer.editing(hit, dragging: true))
            refreshLayers()
            return
        }
        if selection == nil {
            anchor = point
            // The click that selects a hovered window also starts a possible double-click.
            lastCanvasClick = (point, event.timestamp)
            clickDotIndex = nil
            hovered = target(at: point)
            hint.isHidden = true
        } else if let selection, selection.contains(point) {
            lastCanvasClick = (point, event.timestamp)
            clickDotIndex = nil
            commitText()
            selectedRectangle = nil; hoveredRectangle = nil
            window?.makeFirstResponder(self)
            if tool == .text { beginText(at: point) }
            else {
                draft = Mark(tool: tool, points: [point], color: color, width: strokeWidth)
                CapturePointer.show(drawingCursor)
            }
        } else { commitText(); window?.makeFirstResponder(self) }
    }

    override func mouseDragged(with event: NSEvent) {
        let raw = convert(event.locationInWindow, from: nil)
        let point = clamp(raw)
        if rectangleDrag != nil {
            updateRectangleDrag(to: raw)
        } else if let anchor {
            if hypot(point.x - anchor.x, point.y - anchor.y) >= 3 {
                selection = rectBetween(anchor, point)
            }
        } else if draft != nil, let selection {
            if let click = lastCanvasClick, hypot(point.x - click.point.x, point.y - click.point.y) > 2 {
                lastCanvasClick = nil
            }
            let clipped = NSPoint(x: min(max(point.x, selection.minX), selection.maxX), y: min(max(point.y, selection.minY), selection.maxY))
            if tool == .pen { draft?.points.append(clipped) }
            else if let first = draft?.points.first { draft?.points = [first, clipped] }
        }
        // Layer changes are coalesced into the next display-linked update.
    }

    @discardableResult func quickSave(with event: NSEvent) -> Bool {
        guard event.buttonNumber == 2, anchor == nil, draft == nil, rectangleDrag == nil, let selection,
              selection.contains(convert(event.locationInWindow, from: nil)) else { return false }
        if let result = rendered() { onQuickSave?(result) }
        return true
    }
    override func otherMouseDown(with event: NSEvent) {
        if !quickSave(with: event) { super.otherMouseDown(with: event) }
    }

    override func mouseUp(with event: NSEvent) {
        if let drag = rectangleDrag {
            updateRectangleDrag(to: convert(event.locationInWindow, from: nil))
            if selection != drag.before.selection || marks != drag.before.marks { rememberChange(drag.before) }
            rectangleDrag = nil
            placeToolbar(); updateDimensions()
            updateEditHover(at: convert(event.locationInWindow, from: nil))
        } else if let anchor {
            let point = clamp(convert(event.locationInWindow, from: nil))
            if hypot(point.x - anchor.x, point.y - anchor.y) < 3 {
                selection = target(at: point)?.frame
            } else {
                // Classify the completed gesture using the same sample as the selection.
                lastCanvasClick = nil
                selection = rectBetween(anchor, point)
            }
            self.anchor = nil
            if let rect = selection, rect.width >= 8, rect.height >= 8 {
                // Align to physical pixels so repeated export never shifts a crop by a fractional pixel.
                selection = NSRect(x: (rect.minX * pixelScale).rounded() / pixelScale,
                                   y: (rect.minY * pixelScale).rounded() / pixelScale,
                                   width: (rect.width * pixelScale).rounded() / pixelScale,
                                   height: (rect.height * pixelScale).rounded() / pixelScale)
                onSelected?()
                placeToolbar()
                updateDimensions()
            } else { selection = nil; hint.isHidden = false; dimensions.isHidden = true }
        } else if var finalMark = draft, let selection {
            // The mouse-up sample is authoritative, even if it arrives between display callbacks.
            let point = convert(event.locationInWindow, from: nil)
            let end = CGPoint(x: min(max(point.x, selection.minX), selection.maxX), y: min(max(point.y, selection.minY), selection.maxY))
            if finalMark.tool == .pen {
                if finalMark.points.last != end { finalMark.points.append(end) }
            } else if let first = finalMark.points.first { finalMark.points = [first, end] }
            if finalMark.tool == .pen || (finalMark.points.count > 1 && hypot(finalMark.points.last!.x - finalMark.points.first!.x, finalMark.points.last!.y - finalMark.points.first!.y) > 2) {
                if finalMark.tool == .pen, let click = lastCanvasClick,
                   hypot(end.x - click.point.x, end.y - click.point.y) <= 2 { clickDotIndex = marks.count }
                else { lastCanvasClick = nil }
                rememberChange()
                marks.append(finalMark)
                selectedRectangle = finalMark.tool == .rectangle ? marks.count - 1 : nil
            }
            self.draft = nil
        }
        updateTools()
        refreshLayers()
    }

    private func placeToolbar() {
        guard let selection else { return }
        toolbar.isHidden = false
        let size = NSSize(width: 610, height: 80)
        let x = min(max(12, selection.midX - size.width / 2), bounds.width - size.width - 12)
        var y = selection.maxY + 12
        if y + size.height > bounds.height - 12 {
            y = selection.minY - size.height - 12
            if y < 12 { y = bounds.height - size.height - 12 }
        }
        toolbar.frame = NSRect(origin: NSPoint(x: x, y: max(12, y)), size: size)
        toolbar.layoutSubtreeIfNeeded()
        window?.makeFirstResponder(self)
    }

    private func updateDimensions() {
        guard let selection else { return }
        dimensions.stringValue = "\(Int((selection.width * pixelScale).rounded())) × \(Int((selection.height * pixelScale).rounded())) px"
        dimensions.frame = NSRect(x: min(max(4, selection.minX), bounds.width - 140), y: max(4, selection.minY - 25), width: 136, height: 21)
        dimensions.isHidden = false
    }

    private func beginText(at point: NSPoint) {
        guard let selection else { return }
        let fontSize = 16 + strokeWidth * 2
        let origin = NSPoint(x: min(point.x, max(selection.minX, selection.maxX - 100)),
                             y: min(point.y, max(selection.minY, selection.maxY - fontSize - 12)))
        let field = NSTextField(frame: NSRect(x: origin.x, y: origin.y,
                                              width: min(360, selection.maxX - origin.x), height: fontSize + 12))
        field.font = .systemFont(ofSize: fontSize, weight: .semibold)
        field.textColor = color
        field.backgroundColor = .black.withAlphaComponent(0.65)
        field.isBezeled = false
        field.focusRingType = .none
        field.placeholderString = "输入文字"
        field.delegate = self
        field.setAccessibilityLabel("标注文字")
        textOrigin = NSPoint(x: ((origin.x + 2) * pixelScale).rounded() / pixelScale,
                             y: ((origin.y + 2) * pixelScale).rounded() / pixelScale)
        textEditor = field
        addSubview(field)
        window?.makeFirstResponder(field)
    }

    private func commitText() {
        guard let field = textEditor else { return }
        textEditor = nil
        if !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let origin = textOrigin {
            rememberChange()
            marks.append(Mark(tool: .text, points: [origin], color: color, width: strokeWidth, text: field.stringValue))
        }
        field.removeFromSuperview()
        textOrigin = nil
        updateTools()
        refreshLayers()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commitText(); window?.makeFirstResponder(self); return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            textEditor?.removeFromSuperview(); textEditor = nil; textOrigin = nil
            window?.makeFirstResponder(self); return true
        }
        return false
    }

    @objc private func selectTool(_ sender: NSButton) {
        commitText(); tool = MarkTool.allCases[sender.tag]; updateTools(); window?.makeFirstResponder(self)
    }
    @objc private func selectColor(_ sender: NSButton) {
        commitText(); color = palette[sender.tag]; updateTools(); window?.makeFirstResponder(self)
    }
    @objc private func selectWidth(_ sender: NSSegmentedControl) {
        commitText(); strokeWidth = [1.5, 3, 6][sender.selectedSegment]; window?.makeFirstResponder(self)
    }
    @objc private func undoMark() {
        guard rectangleDrag == nil else { return }
        commitText()
        if let state = undoStates.popLast() { redoStates.append(currentState()); restore(state) }
    }
    @objc private func redoMark() {
        guard rectangleDrag == nil else { return }
        if let state = redoStates.popLast() { undoStates.append(currentState()); restore(state) }
    }
    @objc private func reselect() { onReselect?() }
    func resetSelection() {
        textEditor?.removeFromSuperview(); textEditor = nil; textOrigin = nil
        selection = nil; marks.removeAll(); undoStates.removeAll(); redoStates.removeAll(); draft = nil; anchor = nil
        rectangleDrag = nil; selectedRectangle = nil; hoveredRectangle = nil
        tool = .rectangle
        lastCanvasClick = nil; clickDotIndex = nil
        toolbar.isHidden = true; hint.isHidden = false; dimensions.isHidden = true
        window?.makeFirstResponder(self)
        updateTools(); refreshLayers()
    }
    private func rendered() -> NSBitmapImageRep? {
        commitText()
        guard let selection else { return nil }
        return CaptureRenderer.render(image: screenshot, canvasSize: bounds.size, selection: selection, scale: pixelScale, marks: marks)
    }
    @objc private func copyCapture() { if let result = rendered() { onCopy?(result) } }
    @objc private func save() { if let result = rendered() { onSave?(result) } }
    @objc private func pinCapture() {
        guard let selection, let window, let result = rendered() else { return }
        let localMarks = marks.map { mark -> Mark in
            var local = mark
            local.points = mark.points.map { NSPoint(x: $0.x - selection.minX, y: $0.y - selection.minY) }
            return local
        }
        let frame = window.convertToScreen(convert(selection, to: nil))
        if !localMarks.isEmpty, let background = CaptureRenderer.render(image: screenshot, canvasSize: bounds.size,
            selection: selection, scale: pixelScale, marks: []) {
            onPin?(PinnedContent(bitmap: result, background: background, marks: localMarks), frame)
        } else { onPin?(PinnedContent(bitmap: result), frame) }
    }
    @objc private func cancel() { onCancel?() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Let the field editor own copy/paste/undo while typing.
        if textEditor != nil { return super.performKeyEquivalent(with: event) }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if event.modifierFlags.contains(.command) {
            switch key {
            case "c": copyCapture(); return true
            case "s": save(); return true
            case "t":
                if selection != nil { commitText(); tool = .text; updateTools(); window?.makeFirstResponder(self) }
                return true
            case "z": event.modifierFlags.contains(.shift) ? redoMark() : undoMark(); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty == false {
            if !performKeyEquivalent(with: event) { super.keyDown(with: event) }
            return
        }
        if event.keyCode == 53 { cancel(); return }
        if event.keyCode == 36 || event.keyCode == 76 { copyCapture(); return }
        if event.charactersIgnoringModifiers?.lowercased() == "f" { performance.isHidden.toggle(); return }
        if event.charactersIgnoringModifiers?.lowercased() == "g" { guidesEnabled.toggle(); return }
        guard selection != nil else { return }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "a": tool = .arrow
        case "r": tool = .rectangle
        case "p": tool = .pen
        case "t": pinCapture(); return
        default: super.keyDown(with: event); return
        }
        updateTools()
    }
}
