import AppKit
import QuartzCore

final class PinnedPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func sendEvent(_ event: NSEvent) {
        GestureDiagnostics.record("panel", event, view: contentView as? PinnedImageView)
        // Route gestures directly to the image, independently of the field responder chain.
        if let image = contentView as? PinnedImageView {
            if event.type == .magnify { image.magnify(with: event); return }
            if event.type == .endGesture { image.endGesture(with: event); return }
            if event.type == .rightMouseDown { image.rightMouseDown(with: event); return }
            if event.type == .otherMouseDown, event.buttonNumber == 2 {
                image.otherMouseDown(with: event); return
            }
        }
        super.sendEvent(event)
    }
}

struct PinnedContent {
    let bitmap: NSBitmapImageRep // Original-resolution composite used for clipboard export.
    let background: NSBitmapImageRep
    let marks: [Mark]
    init(bitmap: NSBitmapImageRep, background: NSBitmapImageRep? = nil, marks: [Mark] = []) {
        self.bitmap = bitmap; self.background = background ?? bitmap; self.marks = marks
    }
}

struct PinnedGeometry {
    let originalSize: NSSize
    private(set) var frame: NSRect
    private(set) var zoom: CGFloat = 1
    private var dragOffset: NSPoint?
    var isDragging: Bool { dragOffset != nil }

    init(frame: NSRect) { self.frame = frame; originalSize = frame.size }
    mutating func beginDrag(at point: NSPoint) {
        dragOffset = NSPoint(x: point.x - frame.minX, y: point.y - frame.minY)
    }
    mutating func drag(to point: NSPoint) {
        guard let dragOffset else { return }
        frame.origin = NSPoint(x: point.x - dragOffset.x, y: point.y - dragOffset.y)
    }
    mutating func endDrag(at point: NSPoint) { drag(to: point); dragOffset = nil }
    mutating func scale(by factor: CGFloat, around point: NSPoint) {
        guard factor.isFinite, factor > 0 else { return }
        // Bound the backing-store size as well as the zoom; keep tiny selections usable.
        let longest = max(originalSize.width, originalSize.height)
        let minimum = max(0.1, min(1, 48 / longest))
        let maximum = max(1, min(8, 8192 / longest))
        let next = min(max(zoom * factor, minimum), maximum)
        let ratio = next / zoom
        frame = NSRect(x: point.x + (frame.minX - point.x) * ratio,
                       y: point.y + (frame.minY - point.y) * ratio,
                       width: originalSize.width * next, height: originalSize.height * next)
        zoom = next
        if isDragging { beginDrag(at: point) }
    }
}

/// A mouse-transparent child behind the image keeps the selection shadow outside
/// the screenshot's exact frame, without adding padding to its content or exports.
final class PinnedSelectionShadow: NSPanel {
    static let padding: CGFloat = 12

    init(imageFrame: NSRect) {
        super.init(contentRect: imageFrame.insetBy(dx: -Self.padding, dy: -Self.padding),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        animationBehavior = .none
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        hasShadow = false
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = true
        contentView = PinnedSelectionShadowView(frame: NSRect(origin: .zero, size: frame.size))
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class PinnedSelectionShadowView: NSView {
    private let glow = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        glow.backgroundColor = CaptureStyle.blue.cgColor
        glow.shadowColor = CaptureStyle.blue.cgColor
        glow.shadowOpacity = 0.42
        glow.shadowRadius = 5
        glow.shadowOffset = .zero
        glow.actions = ["bounds": NSNull(), "position": NSNull(), "shadowPath": NSNull()]
        layer?.addSublayer(glow)
        setAccessibilityElement(false)
        needsLayout = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        glow.frame = bounds.insetBy(dx: PinnedSelectionShadow.padding, dy: PinnedSelectionShadow.padding)
        glow.contentsScale = window?.backingScaleFactor ?? 2
        // The opaque image window covers the fill; only the soft, even blue halo is visible.
        glow.shadowPath = CGPath(rect: glow.bounds, transform: nil)
        CATransaction.commit()
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }
}

final class PinnedCapture: NSWindowController, NSWindowDelegate {
    let bitmap: NSBitmapImageRep
    let imageView: PinnedImageView
    let selectionShadow: PinnedSelectionShadow
    var onClose: (() -> Void)?
    var onCopy: ((NSBitmapImageRep) -> Void)?
    var onQuickSave: ((NSBitmapImageRep) -> Void)?

    init(content: PinnedContent, frame: NSRect) {
        bitmap = content.bitmap
        imageView = PinnedImageView(frame: NSRect(origin: .zero, size: frame.size), content: content, screenFrame: frame)
        selectionShadow = PinnedSelectionShadow(imageFrame: frame)
        let panel = PinnedPanel(contentRect: frame, styleMask: [.borderless],
                                backing: .buffered, defer: false)
        super.init(window: panel)
        panel.title = "QuickMark 固定截图"
        panel.level = .floating
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.hasShadow = true
        panel.isOpaque = true
        panel.backgroundColor = .black
        panel.delegate = self
        imageView.onCopy = { [weak self] in guard let self else { return }; self.onCopy?(self.bitmap) }
        imageView.onQuickSave = { [weak self] in guard let self else { return }; self.onQuickSave?(self.bitmap) }
        imageView.onClose = { [weak self] in self?.close() }
        panel.contentView = imageView
        panel.makeFirstResponder(imageView)
    }

    convenience init(bitmap: NSBitmapImageRep, frame: NSRect) {
        self.init(content: PinnedContent(bitmap: bitmap), frame: frame)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func show() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        window?.orderFrontRegardless()
        imageView.layoutSubtreeIfNeeded()
        updateSelectionShadow()
        CATransaction.commit()
    }
    func updateSelectionShadow() {
        guard let window else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if window.isKeyWindow && window.isVisible {
            window.hasShadow = false
            selectionShadow.setFrame(window.frame.insetBy(dx: -PinnedSelectionShadow.padding,
                                                         dy: -PinnedSelectionShadow.padding),
                                     display: false, animate: false)
            selectionShadow.contentView?.layoutSubtreeIfNeeded()
            if selectionShadow.parent !== window { window.addChildWindow(selectionShadow, ordered: .below) }
            selectionShadow.order(.below, relativeTo: window.windowNumber)
        } else {
            window.hasShadow = true
            window.removeChildWindow(selectionShadow)
            selectionShadow.orderOut(nil)
        }
        CATransaction.commit()
    }
    func windowDidBecomeKey(_ notification: Notification) { updateSelectionShadow() }
    func windowDidResignKey(_ notification: Notification) { updateSelectionShadow() }
    func windowDidResize(_ notification: Notification) { updateSelectionShadow() }
    func windowDidChangeScreen(_ notification: Notification) { imageView.updateDisplayRate() }
    func windowWillClose(_ notification: Notification) {
        window?.removeChildWindow(selectionShadow)
        selectionShadow.orderOut(nil)
        imageView.stopRendering()
        onClose?()
    }
}

/// One immutable texture. Movement updates the window origin at the display cadence;
/// zoom changes layer geometry without re-rasterizing the source image.
final class PinnedImageView: NSView {
    var onCopy: (() -> Void)?
    var onClose: (() -> Void)?
    var onQuickSave: (() -> Void)?
    let imageLayer = CALayer()
    private let annotationLayer = CALayer()
    private let marks: [Mark]
    private var markLayers: [(mark: Mark, layer: CALayer, frame: CGRect)] = []
    private(set) var textDensity: CGFloat = 0
    private var pinchAnchor: NSPoint?
    private(set) var textureUploads = 0
    private(set) var geometry: PinnedGeometry
    private var frameLink: CADisplayLink?
    private var driver: PinnedFrameDriver?
    private var lastInteraction = 0.0
    private(set) var requestedHz = 0
    private(set) var metrics = FrameMetrics()
    private(set) var frameUpdates = 0
    private var benchmarkOrigin: NSPoint?
    private var benchmarkStart = 0.0
    override var acceptsFirstResponder: Bool { true }
    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func shouldDelayWindowOrdering(for event: NSEvent) -> Bool { false }

    init(frame: NSRect, content: PinnedContent, screenFrame: NSRect) {
        geometry = PinnedGeometry(frame: screenFrame)
        marks = content.marks
        super.init(frame: frame)
        wantsLayer = true
        layer?.actions = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull(), "sublayers": NSNull()]
        imageLayer.actions = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull()]
        imageLayer.contents = content.background.cgImage
        textureUploads = 1
        imageLayer.contentsGravity = .resize
        imageLayer.minificationFilter = .trilinear
        imageLayer.magnificationFilter = .linear
        imageLayer.frame = bounds
        layer?.addSublayer(imageLayer)
        annotationLayer.isGeometryFlipped = true
        annotationLayer.masksToBounds = true
        annotationLayer.actions = ["bounds": NSNull(), "position": NSNull(), "sublayers": NSNull()]
        layer?.addSublayer(annotationLayer)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("固定截图：拖动移动，滚轮或双指捏合缩放，双击复制，中键保存到桌面，右键或 Esc 关闭")
        needsLayout = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        updateAnnotations()
        CATransaction.commit()
    }
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        imageLayer.contentsScale = window?.backingScaleFactor ?? 2
        needsLayout = true
    }

    private func updateAnnotations() {
        annotationLayer.frame = bounds
        let density = max(1, ceil((window?.backingScaleFactor ?? 2) * geometry.zoom))
        let clip = CGRect(origin: .zero, size: geometry.originalSize)
        if markLayers.isEmpty || density > textDensity {
            textDensity = max(textDensity, density)
            annotationLayer.sublayers = nil
            markLayers = marks.compactMap { mark in
                let item: CALayer
                let frame: CGRect
                if mark.tool == .text {
                    guard let raster = TextRaster.render(mark, scale: textDensity, clipping: clip) else { return nil }
                    item = CALayer(); item.contents = raster.image
                    item.contentsScale = textDensity; frame = raster.frame
                } else {
                    let shape = CAShapeLayer()
                    shape.fillColor = nil; shape.strokeColor = mark.color.cgColor
                    shape.lineCap = .round; shape.lineJoin = .round
                    item = shape; frame = clip
                }
                item.actions = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull(), "path": NSNull()]
                annotationLayer.addSublayer(item)
                return (mark, item, frame)
            }
        }
        let zoom = geometry.zoom
        for entry in markLayers {
            entry.layer.frame = CGRect(x: entry.frame.minX * zoom, y: entry.frame.minY * zoom,
                                       width: entry.frame.width * zoom, height: entry.frame.height * zoom)
            if let shape = entry.layer as? CAShapeLayer {
                var transform = CGAffineTransform(scaleX: zoom, y: zoom)
                shape.path = entry.mark.vectorPath.copy(using: &transform)
                shape.lineWidth = entry.mark.width * zoom
                shape.contentsScale = window?.backingScaleFactor ?? 2
            }
        }
    }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { stopRendering() }
        super.viewWillMove(toWindow: newWindow)
    }

    func updateDisplayRate() {
        requestedHz = max(1, window?.screen?.maximumFramesPerSecond ?? 60)
        frameLink?.preferredFrameRateRange = CAFrameRateRange(minimum: Float(requestedHz), maximum: Float(requestedHz), preferred: Float(requestedHz))
    }
    private func startRendering() {
        lastInteraction = CACurrentMediaTime()
        guard frameLink == nil, window != nil else { return }
        let target = PinnedFrameDriver(self)
        driver = target
        frameLink = displayLink(target: target, selector: #selector(PinnedFrameDriver.tick(_:)))
        updateDisplayRate()
        frameLink?.add(to: .main, forMode: .common)
    }
    func stopRendering() { frameLink?.invalidate(); frameLink = nil; driver = nil }
    func displayTick(_ link: CADisplayLink) {
        let begin = CACurrentMediaTime()
        if let origin = benchmarkOrigin {
            let phase = begin - benchmarkStart
            geometry.drag(to: CGPoint(x: origin.x + 90 * sin(phase * 2.7), y: origin.y + 65 * cos(phase * 1.9)))
        } else if geometry.isDragging {
            geometry.drag(to: NSEvent.mouseLocation)
        }
        applyFrame()
        metrics.record(now: begin, cost: CACurrentMediaTime() - begin, targetInterval: link.targetTimestamp - link.timestamp)
        if !geometry.isDragging && begin - lastInteraction > 0.12 { stopRendering() }
    }
    func applyFrame() {
        guard let window, window.frame != geometry.frame else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if window.frame.size == geometry.frame.size { window.setFrameOrigin(geometry.frame.origin) }
        else {
            window.setFrame(geometry.frame, display: false, animate: false)
            needsLayout = true
            layoutSubtreeIfNeeded()
        }
        CATransaction.commit()
        frameUpdates += 1
    }
    // Synthetic motion uses exactly the same position-update path as real dragging.
    func startBenchmark() {
        benchmarkOrigin = NSPoint(x: geometry.frame.midX, y: geometry.frame.midY)
        geometry.beginDrag(at: benchmarkOrigin!)
        benchmarkStart = CACurrentMediaTime()
        startRendering()
    }

    override func mouseDown(with event: NSEvent) {
        // Key status alone is not app activation. macOS may send only scrolling to an
        // inactive app's floating panel and withhold trackpad magnify/touch events.
        // Activate only after the user's click; showing or hovering a pin never steals focus.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKey()
        window?.makeFirstResponder(self)
        if event.clickCount == 2 { onCopy?(); return }
        geometry.beginDrag(at: NSEvent.mouseLocation)
        startRendering()
    }
    override func mouseDragged(with event: NSEvent) {
        // The display link reads the latest global position, even if these events are coalesced.
    }
    override func mouseUp(with event: NSEvent) {
        geometry.endDrag(at: NSEvent.mouseLocation)
        applyFrame() // Keep the exact release position, including releases between frames.
        stopRendering()
    }
    override func otherMouseDown(with event: NSEvent) {
        if event.buttonNumber == 2 { onQuickSave?() }
        else { super.otherMouseDown(with: event) }
    }
    override func rightMouseDown(with event: NSEvent) { onClose?() }
    func zoom(by factor: CGFloat, around point: NSPoint) {
        geometry.scale(by: factor, around: point)
        startRendering()
    }
    override func scrollWheel(with event: NSEvent) {
        // Stop with the fingers: inertial scrolling must not keep enlarging a pinned image.
        guard event.momentumPhase.isEmpty else {
            GestureDiagnostics.record("scrollMomentumIgnored", event, view: self)
            return
        }
        let delta = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
        guard delta.isFinite else { return }
        // AppKit classifies scrolling and magnification. Do not latch raw finger-spacing
        // changes as a pinch: ordinary back-and-forth scrolling includes spacing jitter.
        // A scroll also ends the previous pinch anchor even if its end event was lost.
        if delta != 0 || event.phase.contains(.began) { pinchAnchor = nil }
        // Pixel-resolution deltas are also emitted by high-resolution/smoothed mice.
        // Only a phased gesture uses trackpad sensitivity; phase-less wheel input
        // stays fine-grained regardless of whether its units are lines or pixels.
        let isTrackpadGesture = event.hasPreciseScrollingDeltas && !event.phase.isEmpty
        // Reverse mouse-wheel zoom after normalizing the system's scrolling preference.
        let zoomDelta = isTrackpadGesture ? delta : -delta
        let sensitivity: CGFloat = isTrackpadGesture ? 0.006 : (event.hasPreciseScrollingDeltas ? 0.0005 : 0.002)
        let limit: CGFloat = isTrackpadGesture ? 0.5 : log(1.015)
        let anchor = window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        if delta != 0 { zoom(by: exp(min(max(zoomDelta * sensitivity, -limit), limit)), around: anchor) }
        if !event.phase.intersection([.ended, .cancelled]).isEmpty { applyFrame() }
        GestureDiagnostics.record("scrollApplied", event, view: self)
    }
    override func magnify(with event: NSEvent) {
        GestureDiagnostics.record("magnify", event, view: self)
        let finished = !event.phase.intersection([.ended, .cancelled]).isEmpty
        if pinchAnchor == nil || event.phase.contains(.began) {
            guard !finished else { return }
            pinchAnchor = window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        }
        // NSEvent magnification is a delta for this event, unlike recognizer magnification.
        if !event.phase.contains(.cancelled), event.magnification.isFinite, let pinchAnchor {
            zoom(by: max(0.05, 1 + event.magnification), around: pinchAnchor)
        }
        if finished { pinchAnchor = nil; applyFrame() }
    }
    override func endGesture(with event: NSEvent) {
        pinchAnchor = nil; applyFrame()
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onClose?() }
        else { super.keyDown(with: event) }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "c" {
            onCopy?(); return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

final class PinnedFrameDriver: NSObject {
    weak var owner: PinnedImageView?
    init(_ owner: PinnedImageView) { self.owner = owner }
    @objc func tick(_ link: CADisplayLink) { owner?.displayTick(link) }
}
