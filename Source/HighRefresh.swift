import AppKit
import QuartzCore

struct WindowTarget: Equatable {
    let id: UInt32
    let name: String
    let frame: CGRect // Global Quartz coordinates: origin at the primary display's top-left.

    func localFrame(screen: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: frame.minX - screen.minX, y: frame.minY - (primaryTop - screen.maxY),
               width: frame.width, height: frame.height)
    }

    static func snapshot() -> [WindowTarget] {
        // CGWindowList is front-to-back. Never ask WindowServer for this list in the frame loop.
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            // Include our visible main window too; floating pins and capture
            // overlays are excluded by their window level.
            guard let level = info[kCGWindowLayer as String] as? Int, level == 0,
                  let alpha = info[kCGWindowAlpha as String] as? Double, alpha > 0,
                  let id = info[kCGWindowNumber as String] as? UInt32,
                  let dictionary = info[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: dictionary as CFDictionary), frame.width >= 16, frame.height >= 16 else { return nil }
            return WindowTarget(id: id, name: info[kCGWindowOwnerName as String] as? String ?? "窗口", frame: frame)
        }
    }

    static func hit(_ point: CGPoint, in targets: [WindowTarget]) -> WindowTarget? {
        targets.first(where: { $0.frame.contains(point) })
    }
}

enum CaptureStyle {
    // Sampled from the reference application's crosshair: #2BABFF.
    static let blue = NSColor(srgbRed: 43.0 / 255, green: 171.0 / 255, blue: 1, alpha: 1)
    static let cursorBlue = blue
}

enum CapturePointer {
    // A static NSCursor lets WindowServer move the pointer independently of our render callbacks.
    // Do not hide it and emulate it with a view or a 60 Hz timer.
    static let crosshair = makeCrosshair(color: CaptureStyle.cursorBlue)
    private static var drawingCursors: [NSColor: NSCursor] = [:]

    static func drawing(color: NSColor) -> NSCursor {
        if let cursor = drawingCursors[color] { return cursor }
        let cursor = makeCrosshair(color: color)
        drawingCursors[color] = cursor
        return cursor
    }

    private static func makeCrosshair(color: NSColor) -> NSCursor {
        let ink = color.usingColorSpace(.sRGB) ?? color
        let image = NSImage(size: NSSize(width: 19, height: 19), flipped: false) { _ in
            // A one-point colored cross, without the previous three-point white rim.
            // Only monochrome ink needs a faint, narrow contrast edge on matching backgrounds.
            if ink == NSColor.white.usingColorSpace(.sRGB) || ink == NSColor.black.usingColorSpace(.sRGB) {
                (ink.brightnessComponent > 0.5 ? NSColor.black : NSColor.white).withAlphaComponent(0.45).setFill()
                NSRect(x: 1.5, y: 8.5, width: 16, height: 2).fill()
                NSRect(x: 8.5, y: 1.5, width: 2, height: 16).fill()
            }
            ink.setFill()
            NSRect(x: 2, y: 9, width: 15, height: 1).fill()
            NSRect(x: 9, y: 2, width: 1, height: 15).fill()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 9.5, y: 9.5))
    }

    private static let resizeCursors: [RectangleHandle: NSCursor] = {
        Dictionary(uniqueKeysWithValues: RectangleHandle.allCases.map { handle in
            if #available(macOS 15.0, *) {
                let position: NSCursor.FrameResizePosition
                switch handle {
                case .topLeft: position = .topLeft
                case .top: position = .top
                case .topRight: position = .topRight
                case .right: position = .right
                case .bottomRight: position = .bottomRight
                case .bottom: position = .bottom
                case .bottomLeft: position = .bottomLeft
                case .left: position = .left
                }
                return (handle, NSCursor.frameResize(position: position, directions: .all))
            }
            // macOS 14 has no public diagonal frame-resize cursor API.
            return (handle, handle == .top || handle == .bottom ? NSCursor.resizeUpDown :
                (handle.isCorner ? NSCursor.crosshair : NSCursor.resizeLeftRight))
        })
    }()

    static func editing(_ hit: RectangleHit, dragging: Bool = false) -> NSCursor {
        switch hit {
        case .handle(let handle): return resizeCursors[handle]!
        case .edge: return dragging ? .closedHand : .openHand
        }
    }

    static func show(_ cursor: NSCursor) {
        if NSCursor.current !== cursor { cursor.set() }
    }
}

struct FrameMetrics {
    var times: [Double] = []
    var work: [Double] = []
    var targets: [Double] = []
    var initialTime: Double?
    mutating func record(now: Double, cost: Double, targetInterval: Double) {
        if initialTime == nil { initialTime = now }
        guard now - (initialTime ?? now) >= 0.5 else { return } // Exclude initial texture upload.
        times.append(now); work.append(cost); targets.append(targetInterval)
        if times.count > 3200 { times.removeFirst(1600); work.removeFirst(1600); targets.removeFirst(1600) }
    }
    var intervals: [Double] { zip(times.dropFirst(), times).map(-) }
    var callbackFPS: Double { guard times.count > 1, let first = times.first, let last = times.last, last > first else { return 0 }; return Double(times.count - 1) / (last - first) }
    func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
    }
    var report: [String: Any] {
        let target = percentile(targets, 0.5)
        return ["samples": times.count, "callbackHz": callbackFPS,
                "callbackP95ms": percentile(intervals, 0.95) * 1000,
                "callbackP99ms": percentile(intervals, 0.99) * 1000,
                "updateCPUP95ms": percentile(work, 0.95) * 1000,
                "targetIntervalMs": target * 1000,
                "intervalsOver1_5xTarget": intervals.filter { target > 0 && $0 > target * 1.5 }.count]
    }
}

/// Layer-hosted surface: one immutable screenshot texture, tiny movable guide layers,
/// and vector overlays. No drawRect, bitmap allocation, screenshots or window enumeration per tick.
final class CaptureSurface: NSView {
    let root = CALayer()
    let background = CALayer()
    let shade = CAShapeLayer()
    let outline = CAShapeLayer()
    let selectionHandles = CAShapeLayer()
    let rectangleHandles = CAShapeLayer()
    private let rectangleControlsMask = CAShapeLayer()
    let annotations = CALayer()
    let annotationMask = CAShapeLayer()
    let draftLayer = CAShapeLayer()
    let horizontal = CALayer()
    let vertical = CALayer()
    let targetName = CATextLayer()
    let scale: CGFloat
    private(set) var backgroundUploads = 0
    private var displayedMarks: [Mark] = []
    private var markLayers: [CALayer] = []
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init(frame: NSRect, image: NSImage, scale: CGFloat) {
        self.scale = scale
        super.init(frame: frame)
        root.isGeometryFlipped = true
        root.frame = bounds
        layer = root
        wantsLayer = true
        var proposed = NSRect(origin: .zero, size: image.size)
        background.contents = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
        backgroundUploads = 1
        background.frame = bounds
        background.contentsScale = scale
        background.contentsGravity = .resize
        root.addSublayer(background)
        shade.frame = bounds
        shade.fillRule = .evenOdd
        shade.fillColor = NSColor.black.withAlphaComponent(0.44).cgColor
        root.addSublayer(shade)
        annotations.frame = bounds
        annotations.mask = annotationMask
        root.addSublayer(annotations)
        outline.frame = bounds
        outline.contentsScale = scale
        outline.fillColor = nil
        outline.lineWidth = 2 / scale
        outline.strokeColor = CaptureStyle.blue.cgColor
        root.addSublayer(outline)
        for handles in [selectionHandles, rectangleHandles] {
            handles.frame = bounds
            handles.contentsScale = scale
            handles.fillColor = NSColor.white.cgColor
            handles.strokeColor = NSColor.black.withAlphaComponent(0.8).cgColor
            handles.lineWidth = 1 / scale
            root.addSublayer(handles)
        }
        selectionHandles.fillColor = CaptureStyle.blue.cgColor
        selectionHandles.strokeColor = nil
        rectangleHandles.mask = rectangleControlsMask
        for guide in [horizontal, vertical] {
            guide.anchorPoint = .zero
            // A single opaque blue line: the old black surround made the sampled
            // color look dark even though the center pixel had the correct value.
            guide.backgroundColor = CaptureStyle.cursorBlue.cgColor
            guide.contentsScale = scale
            root.addSublayer(guide)
        }
        horizontal.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: 1)
        vertical.bounds = CGRect(x: 0, y: 0, width: 1, height: bounds.height)
        targetName.contentsScale = scale
        targetName.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        targetName.fontSize = 12
        targetName.foregroundColor = NSColor.white.cgColor
        targetName.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        targetName.cornerRadius = 4
        targetName.alignmentMode = .center
        targetName.truncationMode = .end
        root.addSublayer(targetName)
        updateSelection(nil, hovering: false, name: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func updateSelection(_ rect: CGRect?, hovering: Bool, name: String?) {
        let path = CGMutablePath()
        path.addRect(bounds)
        if let rect { path.addRect(rect) }
        shade.path = path
        outline.path = rect.map { CGPath(rect: $0, transform: nil) }
        outline.strokeColor = CaptureStyle.blue.cgColor
        outline.lineWidth = (hovering ? 3 : 2) / scale
        annotationMask.path = rect.map { CGPath(rect: $0, transform: nil) }
        rectangleControlsMask.path = annotationMask.path
        targetName.isHidden = !hovering || rect == nil
        if let rect, hovering {
            targetName.string = "\(name ?? "窗口") · 单击选取"
            targetName.frame = CGRect(x: min(max(8, rect.minX), bounds.width - 230), y: max(8, rect.minY - 26), width: 222, height: 21)
        }
    }

    func updateEditingControls(selection: CGRect?, rectangle: CGRect?) {
        selectionHandles.path = selection.map { RectangleEditing.cornerPath(for: $0) }
        rectangleHandles.path = rectangle.map { RectangleEditing.handlePath(for: $0) }
    }

    func updateGuides(point: CGPoint?, visible: Bool) {
        horizontal.isHidden = !visible || point == nil
        vertical.isHidden = !visible || point == nil
        if visible, let point {
            horizontal.position = CGPoint(x: 0, y: ((point.y - 0.5) * scale).rounded() / scale)
            vertical.position = CGPoint(x: ((point.x - 0.5) * scale).rounded() / scale, y: 0)
        }
    }

    func updateMarks(_ marks: [Mark]) {
        // Editing a rectangle updates its existing vector layer, without re-rasterizing
        // text marks or replacing the screenshot texture at the display refresh rate.
        if marks.count != displayedMarks.count {
            markLayers = marks.map(makeLayer)
            annotations.sublayers = markLayers + [draftLayer]
        } else {
            for index in marks.indices where marks[index] != displayedMarks[index] {
                if marks[index].tool != .text, let shape = markLayers[index] as? CAShapeLayer {
                    configure(shape, marks[index])
                } else {
                    let replacement = makeLayer(marks[index])
                    annotations.replaceSublayer(markLayers[index], with: replacement)
                    markLayers[index] = replacement
                }
            }
        }
        // The first empty state must still attach the draft layer for drawing.
        if draftLayer.superlayer == nil { annotations.addSublayer(draftLayer) }
        displayedMarks = marks
    }
    func updateDraft(_ mark: Mark?) {
        draftLayer.isHidden = mark == nil
        guard let mark else { return }
        configure(draftLayer, mark)
    }
    private func configure(_ shape: CAShapeLayer, _ mark: Mark) {
        shape.frame = bounds
        shape.contentsScale = scale
        shape.path = mark.vectorPath
        shape.strokeColor = mark.color.cgColor
        shape.fillColor = nil
        shape.lineWidth = mark.width
        shape.lineCap = .round
        shape.lineJoin = .round
    }
    private func makeLayer(_ mark: Mark) -> CALayer {
        if mark.tool == .text {
            let text = CALayer()
            if let raster = TextRaster.render(mark, scale: scale, clipping: bounds) {
                text.frame = raster.frame
                text.contentsScale = scale
                text.contents = raster.image
            }
            return text
        }
        let shape = CAShapeLayer()
        configure(shape, mark)
        return shape
    }
}

extension Mark {
    var vectorPath: CGPath {
        let path = CGMutablePath()
        guard let first = points.first, let last = points.last else { return path }
        switch tool {
        case .arrow:
            let distance = hypot(last.x - first.x, last.y - first.y)
            guard distance > 2 else { return path }
            let angle = atan2(last.y - first.y, last.x - first.x)
            let head = min(max(width * 4, 13), distance * 0.45)
            path.move(to: first); path.addLine(to: last)
            path.move(to: CGPoint(x: last.x - head * cos(angle - .pi / 6), y: last.y - head * sin(angle - .pi / 6)))
            path.addLine(to: last)
            path.addLine(to: CGPoint(x: last.x - head * cos(angle + .pi / 6), y: last.y - head * sin(angle + .pi / 6)))
        case .rectangle: path.addRect(rectBetween(first, last))
        case .pen:
            path.move(to: first)
            if points.count == 1 { path.addLine(to: CGPoint(x: first.x + 0.01, y: first.y)) }
            else { for p in points.dropFirst() { path.addLine(to: p) } }
        case .text: break
        }
        return path
    }
}

final class FrameDriver: NSObject {
    weak var owner: CaptureView?
    init(_ owner: CaptureView) { self.owner = owner }
    @objc func tick(_ link: CADisplayLink) { owner?.displayTick(link) }
}
