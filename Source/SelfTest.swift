import AppKit

enum TestFailure: Error { case failed(String) }
final class TestPinGesture: NSEvent {
    var amount: CGFloat = 0
    var momentum: NSEvent.Phase = []
    var eventPhase: NSEvent.Phase = []
    var eventType: NSEvent.EventType = .magnify
    var precise = false
    var inverted = false
    var touchSamples = Set<NSTouch>()
    var point = CGPoint(x: 60, y: 60)
    override var type: NSEvent.EventType { eventType }
    override var phase: NSEvent.Phase { eventPhase }
    override var timestamp: TimeInterval { 100 }
    override var locationInWindow: NSPoint { point }
    override var magnification: CGFloat { amount }
    override var scrollingDeltaY: CGFloat { amount }
    override var hasPreciseScrollingDeltas: Bool { precise }
    override var isDirectionInvertedFromDevice: Bool { inverted }
    override var momentumPhase: NSEvent.Phase { momentum }
    override func touches(matching phase: NSTouch.Phase, in view: NSView?) -> Set<NSTouch> { touchSamples }
}
final class TestPinTouch: NSTouch, @unchecked Sendable {
    var touchID: NSString = "finger"
    var point = NSPoint.zero
    override var identity: NSCopying & NSObjectProtocol { touchID }
    override var type: NSTouch.TouchType { .indirect }
    override var phase: NSTouch.Phase { .moved }
    override var normalizedPosition: NSPoint { NSPoint(x: point.x / 100, y: point.y / 100) }
    override var deviceSize: NSSize { NSSize(width: 100, height: 100) }
}
final class TestMiddleClick: NSEvent {
    var point = NSPoint.zero
    var button = 2
    override var type: NSEvent.EventType { .otherMouseDown }
    override var buttonNumber: Int { button }
    override var locationInWindow: NSPoint { point }
}
func runSelfTests() throws {
    var checks = 0
    func check(_ value: @autoclosure () -> Bool, _ name: String) throws {
        guard value() else { throw TestFailure.failed(name) }
        checks += 1
        print("PASS: \(name)")
    }
    let size = NSSize(width: 200, height: 120)
    let image = NSImage(size: size, flipped: true) { _ in
        NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 100, height: 60).fill()
        NSColor.green.setFill(); NSRect(x: 100, y: 0, width: 100, height: 60).fill()
        NSColor.blue.setFill(); NSRect(x: 0, y: 60, width: 100, height: 60).fill()
        NSColor.white.setFill(); NSRect(x: 100, y: 60, width: 100, height: 60).fill()
        return true
    }
    let crop = NSRect(x: 50, y: 30, width: 100, height: 60)
    guard let bitmap = CaptureRenderer.render(image: image, canvasSize: size, selection: crop, scale: 2, marks: []) else {
        throw TestFailure.failed("create bitmap")
    }
    try check(bitmap.pixelsWide == 200 && bitmap.pixelsHigh == 120, "Retina crop retains 2× physical pixels")
    func rgb(_ bitmap: NSBitmapImageRep, _ x: Int, _ y: Int) -> NSColor { bitmap.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)! }
    let topLeft = rgb(bitmap, 10, 10), topRight = rgb(bitmap, 190, 10), bottomLeft = rgb(bitmap, 10, 110)
    try check(topLeft.redComponent > 0.95 && topLeft.blueComponent < 0.05, "Crop origin and top-left orientation")
    try check(topRight.greenComponent > 0.95 && topRight.redComponent < 0.05, "Crop right edge")
    try check(bottomLeft.blueComponent > 0.95 && bottomLeft.redComponent < 0.05, "Crop bottom edge without vertical inversion")
    let marks = [Mark(tool: .rectangle, points: [NSPoint(x: 60, y: 40), NSPoint(x: 90, y: 70)], color: .black, width: 4),
                 Mark(tool: .arrow, points: [NSPoint(x: 105, y: 45), NSPoint(x: 135, y: 70)], color: .black, width: 3),
                 Mark(tool: .pen, points: [NSPoint(x: 60, y: 75), NSPoint(x: 85, y: 80)], color: .black, width: 3),
                 Mark(tool: .text, points: [NSPoint(x: 100, y: 30)], color: .black, width: 3, text: "重点")]
    guard let annotated = CaptureRenderer.render(image: image, canvasSize: size, selection: crop, scale: 2, marks: marks) else {
        throw TestFailure.failed("render annotations")
    }
    let stroke = rgb(annotated, 20, 40)
    try check(stroke.redComponent < 0.05 && stroke.greenComponent < 0.05, "Annotations translated into crop coordinates")
    let unchanged = rgb(annotated, 4, 4)
    try check(unchanged.redComponent > 0.95, "Export contains source pixels without selection shading")
    let png = annotated.representation(using: .png, properties: [:])!
    let decoded = NSBitmapImageRep(data: png)!
    try check(decoded.pixelsWide == 200 && decoded.pixelsHigh == 120, "PNG round trip preserves dimensions")
    try check(rectBetween(NSPoint(x: 90, y: 80), NSPoint(x: 20, y: 10)) == NSRect(x: 20, y: 10, width: 70, height: 70), "Selection supports dragging in reverse")
    let front = WindowTarget(id: 1, name: "Front", frame: CGRect(x: 40, y: 20, width: 100, height: 80))
    let back = WindowTarget(id: 2, name: "Back", frame: CGRect(x: 0, y: 0, width: 180, height: 120))
    try check(WindowTarget.hit(CGPoint(x: 60, y: 30), in: [front, back])?.id == 1, "Window hit testing respects front-to-back order")
    try check(WindowTarget.hit(CGPoint(x: 10, y: 10), in: [front, back])?.id == 2, "Uncovered region selects the window behind")
    try check(WindowTarget.hit(CGPoint(x: 220, y: 10), in: [front, back]) == nil, "Desktop does not invent a window")
    let leftScreen = CGRect(x: -1920, y: 100, width: 1920, height: 1080)
    let leftWindow = WindowTarget(id: 3, name: "Left", frame: CGRect(x: -1800, y: 216, width: 600, height: 400))
    try check(leftWindow.localFrame(screen: leftScreen, primaryTop: 1296) == CGRect(x: 120, y: 100, width: 600, height: 400), "Window coordinates support a left, vertically offset monitor")
    let aboveScreen = CGRect(x: 0, y: 1296, width: 1920, height: 1080)
    let aboveWindow = WindowTarget(id: 4, name: "Above", frame: CGRect(x: 50, y: -1000, width: 400, height: 300))
    try check(aboveWindow.localFrame(screen: aboveScreen, primaryTop: 1296).origin == CGPoint(x: 50, y: 80), "Window coordinates support a monitor above the primary")
    let surface = CaptureSurface(frame: CGRect(origin: .zero, size: size), image: image, scale: 2)
    for i in 0..<1000 {
        surface.updateGuides(point: CGPoint(x: i % 200, y: i % 120), visible: true)
        surface.updateSelection(crop, hovering: true, name: "Test")
    }
    try check(surface.backgroundUploads == 1, "1000 overlay updates do not upload or redraw the screenshot")
    // Compare composited pixels, not just a layer's declared color: a black surround
    // previously made the correct sampled blue look much darker on screen.
    let guideCanvas = NSImage(size: NSSize(width: 40, height: 40), flipped: true) { rect in
        NSColor.white.setFill(); rect.fill(); return true
    }
    for backingScale in [1, 2] {
        for offset in [0.0, 0.25] {
            let guideSurface = CaptureSurface(frame: CGRect(x: 0, y: 0, width: 40, height: 40),
                                              image: guideCanvas, scale: CGFloat(backingScale))
            guideSurface.updateSelection(guideSurface.bounds, hovering: false, name: nil)
            guideSurface.updateGuides(point: CGPoint(x: 20 + offset, y: 20 + offset), visible: true)
            let context = CGContext(data: nil, width: 40 * backingScale, height: 40 * backingScale,
                                    bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            context.scaleBy(x: CGFloat(backingScale), y: CGFloat(backingScale))
            guideSurface.root.render(in: context)
            let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
            func sampled(_ x: Int, _ y: Int) -> [Int] {
                let index = y * context.bytesPerRow + x * 4
                return [Int(pixels[index]), Int(pixels[index + 1]), Int(pixels[index + 2])]
            }
            let range = (20 * backingScale - 4)...(20 * backingScale + 4)
            let horizontalSamples = range.map { sampled(30 * backingScale, $0) }
            let verticalSamples = range.map { sampled($0, 30 * backingScale) }
            let referenceBlue = [43, 171, 255], white = [255, 255, 255]
            let clean = [horizontalSamples, verticalSamples].allSatisfy { samples in
                samples.allSatisfy { $0 == referenceBlue || $0 == white } &&
                    samples.filter { $0 == referenceBlue }.count == backingScale
            }
            if !clean { print("GUIDE PIXELS: \(backingScale)x offset \(offset): \(horizontalSamples) / \(verticalSamples)") }
            try check(clean, "Composited \(backingScale)x guides at offset \(offset) match reference blue without dark or blurred fringes")
        }
    }
    try check(marks[0].vectorPath.boundingBox == CGRect(x: 60, y: 40, width: 30, height: 30), "Layer rectangle geometry matches export")
    var metrics = FrameMetrics()
    for i in 0..<1600 { metrics.record(now: Double(i) / 160, cost: 0.0001, targetInterval: 1.0 / 160) }
    try check(abs(metrics.callbackFPS - 160) < 0.01 && abs(metrics.percentile(metrics.intervals, 0.95) * 1000 - 6.25) < 0.01, "Frame diagnostics correctly measure 160 Hz / 6.25 ms")
    // Exercise the real selection handlers with local NSEvents; no global input is sent.
    let canvasSize = NSSize(width: 900, height: 700)
    let canvas = NSImage(size: canvasSize, flipped: true) { rect in NSColor.white.setFill(); rect.fill(); return true }
    let window = CaptureWindow(contentRect: NSRect(x: -1200, y: 200, width: 900, height: 700),
                               styleMask: .borderless, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let view = CaptureView(frame: NSRect(origin: .zero, size: canvasSize), image: canvas, scale: 2,
                           targets: [WindowTarget(id: 7, name: "App", frame: CGRect(x: 300, y: 100, width: 200, height: 200))])
    window.contentView = view
    defer { window.orderOut(nil); window.contentView = nil }
    func mouse(_ type: NSEvent.EventType, _ point: NSPoint, _ time: TimeInterval, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [], timestamp: time,
                          windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: clicks, pressure: 1)!
    }
    func key(_ text: String, command: Bool = false, shift: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: (command ? NSEvent.ModifierFlags.command : []).union(shift ? .shift : []), timestamp: 30,
                        windowNumber: window.windowNumber, context: nil, characters: text,
                        charactersIgnoringModifiers: text, isARepeat: false, keyCode: 17)!
    }
    let start = NSPoint(x: 50, y: 80), end = NSPoint(x: 250, y: 220)
    try check(view.acceptsFirstMouse(for: mouse(.leftMouseDown, start, 1)), "Inactive capture canvas accepts the first mouse-down")
    let hint = view.subviews.first { $0 is CaptureLabel }!
    try check(hint.hitTest(hint.frame.origin) == nil, "Informational overlay cannot swallow a selection drag")
    try check(view.target(at: start)?.frame == view.bounds, "Desktop hover highlights the current full display")
    try check(view.target(at: NSPoint(x: 350, y: 150))?.id == 7, "App window takes priority over desktop fallback")
    try check(view.target(at: NSPoint(x: -1, y: 20)) == nil, "Desktop fallback never highlights a different display")
    view.mouseDown(with: mouse(.leftMouseDown, start, 1))
    view.mouseDragged(with: mouse(.leftMouseDragged, end, 1.1))
    view.mouseUp(with: mouse(.leftMouseUp, end, 1.2))
    try check(view.selection == rectBetween(start, end), "First drag creates a selection without a preliminary click")
    try check(view.tool == .rectangle, "A fresh selection defaults to rectangle annotation")
    try check(CapturePointer.crosshair.image.size == NSSize(width: 19, height: 19) &&
              CapturePointer.crosshair.hotSpot == NSPoint(x: 9.5, y: 9.5),
              "Capture uses a compact system-managed crosshair with a centered hotspot")
    var copied: NSBitmapImageRep?
    view.onCopy = { copied = $0 }
    let click = NSPoint(x: 100, y: 130)
    view.mouseDown(with: mouse(.leftMouseDown, click, 2))
    view.mouseUp(with: mouse(.leftMouseUp, click, 2.01))
    view.mouseDown(with: mouse(.leftMouseDown, click, 2.05, clicks: 2))
    try check(copied?.pixelsWide == 400 && copied?.pixelsHigh == 280, "Double-click exports selected crop for clipboard")
    copied = nil
    view.keyDown(with: key("p"))
    view.mouseDown(with: mouse(.leftMouseDown, click, 3))
    view.mouseUp(with: mouse(.leftMouseUp, click, 3.01))
    view.mouseDown(with: mouse(.leftMouseDown, click, 3.05, clicks: 2))
    try check(copied != nil && rgb(copied!, 100, 100).greenComponent > 0.99, "Double-click with pen removes the incidental first-click dot")
    var pinFrame: NSRect?
    var pinned: NSBitmapImageRep?
    var pinnedContent: PinnedContent?
    view.onPin = { content, frame in pinnedContent = content; pinned = content.bitmap; pinFrame = frame }
    try check(view.performKeyEquivalent(with: key("t", command: true)), "Command-T selects the text tool")
    try check(pinFrame == nil, "Command-T does not pin the screenshot")
    view.mouseDown(with: mouse(.leftMouseDown, click, 4))
    let editor = view.subviews.compactMap { $0 as? NSTextField }.first { $0.isEditable }
    try check(editor != nil, "Text tool opens a text editor at the selected position")
    editor?.stringValue = "t should remain text"
    try check(!view.performKeyEquivalent(with: key("t", command: true)), "Text field retains its keyboard editing behavior")
    view.keyDown(with: key("t"))
    try check(pinned?.pixelsWide == 400 && pinFrame == NSRect(x: -1150, y: 680, width: 200, height: 140),
              "T pins the cropped image at the correct offset-display screen coordinates")
    let pin = PinnedCapture(content: pinnedContent!, frame: pinFrame!)
    try check(pin.window?.level == .floating && (pin.window as? NSPanel)?.hidesOnDeactivate == false,
              "Pinned screenshot stays above ordinary windows when another app is active")
    try check(pin.window?.animationBehavior == NSWindow.AnimationBehavior.none && pin.window?.frame == pinFrame,
              "Pin opens at the exact crop size and location with window animations disabled")
    try check(pin.window?.styleMask.contains(.nonactivatingPanel) == false,
              "Pinned window allows application activation on click for real trackpad gestures")
    var geometry = PinnedGeometry(frame: NSRect(x: -1000, y: 400, width: 400, height: 200))
    let zoomAnchor = NSPoint(x: -900, y: 450)
    geometry.scale(by: 2, around: zoomAnchor)
    try check(geometry.frame == NSRect(x: -1100, y: 350, width: 800, height: 400),
              "Zoom preserves the image point under the pointer on an offset display")
    geometry.scale(by: 0.5, around: zoomAnchor)
    try check(geometry.frame == NSRect(x: -1000, y: 400, width: 400, height: 200),
              "Zoom in and out preserves original aspect ratio and geometry")
    geometry.beginDrag(at: zoomAnchor)
    geometry.drag(to: NSPoint(x: 100, y: 900))
    try check(geometry.frame.origin == NSPoint(x: 0, y: 850), "Pinned drag keeps its grab offset while crossing displays")
    geometry.scale(by: 2, around: NSPoint(x: 100, y: 900))
    let zoomedOrigin = geometry.frame.origin
    geometry.endDrag(at: NSPoint(x: 110, y: 920))
    try check(geometry.frame.origin == NSPoint(x: zoomedOrigin.x + 10, y: zoomedOrigin.y + 20) && !geometry.isDragging,
              "Zoom during drag rebases the grab point and release uses the final pointer")
    geometry.scale(by: 100000, around: zoomAnchor)
    try check(geometry.zoom == 8, "Pinned zoom has a bounded maximum")
    geometry.scale(by: 0.000001, around: zoomAnchor)
    try check(geometry.frame.width >= 48 && geometry.zoom >= 0.1, "Pinned zoom cannot collapse the image")
    let safeFrame = geometry.frame
    geometry.scale(by: .nan, around: zoomAnchor)
    try check(geometry.frame == safeFrame, "Invalid gesture magnification cannot corrupt window geometry")
    let gesture = TestPinGesture()
    gesture.amount = 0.5
    gesture.eventPhase = .began
    pin.window?.sendEvent(gesture)
    pin.imageView.applyFrame()
    try check(abs(pin.imageView.geometry.zoom - 1.5) < 0.001, "Native magnify event routes through an unfocused pinned panel")
    gesture.amount = 0.2; gesture.eventPhase = .changed
    pin.window?.sendEvent(gesture)
    try check(abs(pin.imageView.geometry.zoom - 1.8) < 0.001, "Native pinch consumes event deltas without resetting or double applying")
    gesture.amount = 0; gesture.eventPhase = .ended
    pin.window?.sendEvent(gesture)
    try check(pin.window?.frame.size == pin.imageView.bounds.size && pin.imageView.imageLayer.frame == pin.imageView.bounds,
              "Pinch resize synchronizes window, content view and image layer geometry")
    gesture.amount = 3; gesture.eventType = .scrollWheel; gesture.eventPhase = []
    pin.imageView.scrollWheel(with: gesture)
    pin.imageView.applyFrame()
    try check(abs(pin.imageView.geometry.zoom - 1.8 * exp(-0.006)) < 0.001,
              "A positive three-line mouse-wheel step now shrinks about 0.6 percent after a pinch")
    let beforeFastWheel = pin.imageView.geometry.zoom
    gesture.amount = 1000
    pin.imageView.scrollWheel(with: gesture)
    try check(abs(pin.imageView.geometry.zoom / beforeFastWheel - 1 / 1.015) < 0.000001,
              "An accelerated positive mouse-wheel event uses the reversed reciprocal 1.5 percent cap")
    gesture.inverted = true
    pin.imageView.scrollWheel(with: gesture)
    try check(abs(pin.imageView.geometry.zoom - beforeFastWheel) < 0.001,
              "Natural-scrolling mouse input preserves the reversed physical wheel direction and reciprocal zoom")
    gesture.inverted = false
    let beforePreciseMouse = pin.imageView.geometry.zoom
    gesture.precise = true; gesture.amount = 18; gesture.eventPhase = []
    pin.imageView.scrollWheel(with: gesture)
    try check(abs(pin.imageView.geometry.zoom / beforePreciseMouse - exp(-0.009)) < 0.000001,
              "Phase-less high-resolution mouse input reverses direction with fine wheel sensitivity")
    gesture.amount = -18; pin.imageView.scrollWheel(with: gesture)
    gesture.amount = 1000; pin.imageView.scrollWheel(with: gesture)
    try check(abs(pin.imageView.geometry.zoom / beforePreciseMouse - 1 / 1.015) < 0.000001,
              "Large high-resolution mouse deltas share the reversed reciprocal 1.5 percent wheel cap")
    gesture.inverted = true; pin.imageView.scrollWheel(with: gesture); gesture.inverted = false
    let beforeMomentum = pin.imageView.geometry.zoom
    gesture.precise = true; gesture.momentum = .changed; gesture.amount = 4
    pin.imageView.scrollWheel(with: gesture)
    try check(pin.imageView.geometry.zoom == beforeMomentum, "Trackpad scroll momentum does not continue zooming after fingers stop")
    try check(pin.imageView.textureUploads == 1 && pin.bitmap.pixelsWide == 400 && pin.bitmap.pixelsHigh == 280,
              "Moving and scaling keep one texture and preserve original-resolution clipboard data")
    let resizeAction = pin.imageView.imageLayer.action(forKey: "bounds")
    try check(resizeAction == nil || resizeAction is NSNull,
              "Pinned image geometry has no implicit layer animation")
    let touchEvent = TestPinGesture()
    touchEvent.eventType = .gesture
    let finger1 = TestPinTouch(), finger2 = TestPinTouch()
    finger1.touchID = "first"; finger2.touchID = "second"
    finger1.point = NSPoint(x: 20, y: 20); finger2.point = NSPoint(x: 60, y: 60)
    touchEvent.touchSamples = [finger1, finger2]
    pin.imageView.touchesBegan(with: touchEvent)
    let beforeScroll = pin.imageView.geometry.zoom
    gesture.momentum = []; gesture.eventPhase = .began; gesture.amount = 0
    pin.imageView.scrollWheel(with: gesture)
    var everyScrollResponded = true
    for i in 0..<100 {
        // Keep both fingers down while reversing direction, with imperfect spacing.
        finger1.point = NSPoint(x: 20, y: i.isMultiple(of: 2) ? 40 : 20)
        finger2.point = NSPoint(x: 63, y: i.isMultiple(of: 2) ? 83 : 63)
        pin.imageView.touchesMoved(with: touchEvent)
        let beforeStep = pin.imageView.geometry.zoom
        gesture.eventPhase = .changed; gesture.amount = i.isMultiple(of: 2) ? 4 : -4
        pin.imageView.scrollWheel(with: gesture)
        everyScrollResponded = everyScrollResponded &&
            abs(pin.imageView.geometry.zoom / beforeStep - exp(gesture.amount * 0.006)) < 0.000001
    }
    try check(everyScrollResponded && abs(pin.imageView.geometry.zoom - beforeScroll) < 0.000001,
              "One continuous scroll survives 100 alternating updates and raw finger-spacing jitter")
    touchEvent.touchSamples = []; pin.imageView.touchesEnded(with: touchEvent)
    gesture.amount = 0; gesture.eventPhase = .ended
    pin.imageView.scrollWheel(with: gesture)
    try check(pin.window?.frame.size == pin.imageView.bounds.size && pin.imageView.imageLayer.frame == pin.imageView.bounds,
              "Ending a scroll flushes the last resize to the window and image layer")

    for _ in 0..<10 {
        gesture.eventPhase = .began; gesture.amount = 2
        pin.imageView.scrollWheel(with: gesture)
        gesture.eventPhase = .changed; gesture.amount = -2
        pin.imageView.scrollWheel(with: gesture)
        gesture.eventPhase = .ended; gesture.amount = 0
        pin.imageView.scrollWheel(with: gesture)
    }
    try check(abs(pin.imageView.geometry.zoom - beforeScroll) < 0.000001,
              "Repeated scroll gestures retain symmetric up and down zoom")
    gesture.inverted = true; gesture.eventPhase = .changed; gesture.amount = -4
    pin.imageView.scrollWheel(with: gesture)
    try check(abs(pin.imageView.geometry.zoom / beforeScroll - exp(0.024)) < 0.000001,
              "Natural-scrolling preference preserves physical scroll direction")
    gesture.amount = 4; pin.imageView.scrollWheel(with: gesture); gesture.inverted = false

    gesture.eventType = .magnify; gesture.eventPhase = .began; gesture.amount = 0.25
    pin.window?.sendEvent(gesture)
    try check(abs(pin.imageView.geometry.zoom / beforeScroll - 1.25) < 0.000001,
              "Native pinch still works immediately after back-and-forth scrolling")
    gesture.eventPhase = .changed; gesture.amount = -0.2
    pin.window?.sendEvent(gesture)
    try check(abs(pin.imageView.geometry.zoom - beforeScroll) < 0.000001,
              "Reversing native pinch returns to the original scale")
    gesture.eventPhase = .cancelled; gesture.amount = 0.5
    pin.window?.sendEvent(gesture)
    try check(abs(pin.imageView.geometry.zoom - beforeScroll) < 0.000001,
              "A cancelled pinch does not apply its magnification")
    gesture.eventType = .scrollWheel; gesture.eventPhase = .began; gesture.amount = 4
    pin.imageView.scrollWheel(with: gesture)
    try check(abs(pin.imageView.geometry.zoom / beforeScroll - exp(0.024)) < 0.000001,
              "Scroll resumes immediately after a cancelled pinch")
    gesture.amount = -4; pin.imageView.scrollWheel(with: gesture)
    gesture.eventType = .magnify; gesture.eventPhase = .began; gesture.amount = 0
    pin.window?.sendEvent(gesture)
    // Simulate switching input devices or losing a magnify end event.
    gesture.eventType = .scrollWheel; gesture.eventPhase = .changed; gesture.amount = 4
    pin.imageView.scrollWheel(with: gesture)
    try check(abs(pin.imageView.geometry.zoom / beforeScroll - exp(0.024)) < 0.000001,
              "A missing pinch end cannot leave subsequent scrolling locked")
    let beforeInvalid = pin.imageView.geometry.frame
    gesture.amount = .nan; pin.imageView.scrollWheel(with: gesture)
    try check(pin.imageView.geometry.frame == beforeInvalid, "Invalid scroll delta cannot corrupt pinned geometry")

    let middle = TestMiddleClick()
    middle.point = view.convert(click, to: nil)
    var quickSaved: NSBitmapImageRep?
    view.onQuickSave = { quickSaved = $0 }
    window.sendEvent(middle)
    try check(quickSaved?.pixelsWide == 400 && quickSaved?.pixelsHigh == 280,
              "Middle click on the selected canvas exports the annotated original-resolution crop")
    quickSaved = nil; middle.button = 3
    _ = view.quickSave(with: middle)
    try check(quickSaved == nil, "Extra mouse side buttons do not save a screenshot")
    middle.button = 2
    var pinSaved: NSBitmapImageRep?
    pin.onQuickSave = { pinSaved = $0 }
    pin.window?.sendEvent(middle)
    try check(pinSaved === pin.bitmap, "Middle click on a zoomed pin saves its original-resolution image")
    let testDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("quickmark-export-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: testDirectory) }
    let date = Date(timeIntervalSince1970: 1000)
    let saved1 = try PNGExport.save(pin.bitmap, to: testDirectory, date: date)
    let saved2 = try PNGExport.save(pin.bitmap, to: testDirectory, date: date)
    let exported = NSBitmapImageRep(data: try Data(contentsOf: saved1))!
    try check(saved1 != saved2 && exported.pixelsWide == pin.bitmap.pixelsWide,
              "Quick PNG export preserves resolution and never overwrites a duplicate filename")
    var writeFailed = false
    do { _ = try PNGExport.save(pin.bitmap, to: testDirectory.appendingPathComponent("missing")) }
    catch { writeFailed = true }
    try check(writeFailed, "Failed PNG writes propagate an error instead of reporting success")
    var pinClosed = false
    pin.onClose = { pinClosed = true }
    var copiedOnClose = false
    pin.onCopy = { _ in copiedOnClose = true }; pinSaved = nil
    let rightClick = NSEvent.mouseEvent(with: .rightMouseDown, location: CGPoint(x: 60, y: 60),
        modifierFlags: [], timestamp: 101, windowNumber: pin.window!.windowNumber, context: nil,
        eventNumber: 1, clickCount: 1, pressure: 1)!
    pin.window?.sendEvent(rightClick)
    try check(pinClosed, "Right click on an unfocused pin closes it through its owner callback")
    try check(!copiedOnClose && pinSaved == nil, "Right-click closing does not copy or save the image")
    try check(pin.imageView.subviews.isEmpty, "Pinned image has no close icon or other content-obscuring controls")
    let crispText = Mark(tool: .text, points: [CGPoint(x: 8, y: 8)], color: .black, width: 3, text: "清晰 Retina text")
    let textClip = CGRect(x: 0, y: 0, width: 360, height: 100)
    let normalText = TextRaster.render(crispText, scale: 2, clipping: textClip)!
    let largeText = TextRaster.render(crispText, scale: 6, clipping: textClip)!
    try check(normalText.image.width == Int((normalText.frame.width * 2).rounded()) &&
              largeText.image.width >= normalText.image.width * 3 - 4,
              "Text zoom re-rasterizes glyphs at higher density instead of stretching a small bitmap")
    let nativeText = NSBitmapImageRep(cgImage: normalText.image)
    let opaquePixels = (0..<nativeText.pixelsHigh).reduce(0) { count, y in
        count + (0..<nativeText.pixelsWide).filter { (nativeText.colorAt(x: $0, y: y)?.alphaComponent ?? 0) > 0.99 }.count
    }
    try check(opaquePixels > 100, "Retina text has solid glyph interiors rather than only blurred edges")
    try check(pin.imageView.textDensity >= 4, "Pinned annotation density follows enlarged display size")
    try check(CaptureDisplay.quartzFrame(CGRect(x: -1920, y: 100, width: 1920, height: 1080), primaryTop: 1296) ==
              CGRect(x: -1920, y: 116, width: 1920, height: 1080), "Fast screenshot API uses correct offset-display coordinates")
    view.resetSelection()
    view.mouseDown(with: mouse(.leftMouseDown, start, 5))
    view.mouseUp(with: mouse(.leftMouseUp, start, 5.01))
    try check(view.selection == view.bounds, "Clicking desktop selects the entire current display")
    // A snapped window must copy with just two clicks, including at its editing border.
    let snappedFrame = view.target(at: NSPoint(x: 350, y: 150))!.frame
    for (index, point) in [NSPoint(x: 350, y: 150), NSPoint(x: 301, y: 101)].enumerated() {
        view.resetSelection(); copied = nil
        let time = 10 + Double(index)
        view.mouseDown(with: mouse(.leftMouseDown, point, time))
        view.mouseUp(with: mouse(.leftMouseUp, point, time + 0.01))
        try check(view.selection == snappedFrame && copied == nil && view.marks.isEmpty,
                  "A single snapped-window click selects without copying or marking (\(index))")
        view.mouseDown(with: mouse(.leftMouseDown, point, time + 0.05, clicks: 2))
        view.mouseUp(with: mouse(.leftMouseUp, point, time + 0.06, clicks: 2))
        try check(copied?.pixelsWide == 400 && copied?.pixelsHigh == 400 && view.marks.isEmpty,
                  "Double-clicking a hovered window copies immediately, including its border (\(index))")
    }
    view.resetSelection(); copied = nil
    view.mouseDown(with: mouse(.leftMouseDown, start, 12))
    view.mouseUp(with: mouse(.leftMouseUp, start, 12.01))
    view.mouseDown(with: mouse(.leftMouseDown, start, 12.05, clicks: 2))
    try check(copied?.pixelsWide == 1800 && copied?.pixelsHigh == 1400,
              "Double-clicking desktop copies the full current display without a preliminary click")
    // The toolbar can appear under the pointer after selecting a full display.
    view.resetSelection(); copied = nil
    let toolbarPoint = NSPoint(x: 450, y: 640)
    view.mouseDown(with: mouse(.leftMouseDown, toolbarPoint, 13))
    view.mouseUp(with: mouse(.leftMouseUp, toolbarPoint, 13.01))
    try check(view.hitTest(view.convert(toolbarPoint, to: view.superview)) !== view,
              "Full-display selection can place the toolbar under the first click")
    window.sendEvent(mouse(.leftMouseDown, toolbarPoint, 13.05, clicks: 2))
    try check(copied?.pixelsWide == 1800 && copied?.pixelsHigh == 1400,
              "The new toolbar cannot intercept the second click of a capture double-click")
    view.resetSelection(); copied = nil
    view.mouseDown(with: mouse(.leftMouseDown, start, 14))
    view.mouseDragged(with: mouse(.leftMouseDragged, end, 14.01))
    view.mouseUp(with: mouse(.leftMouseUp, end, 14.02))
    view.mouseDown(with: mouse(.leftMouseDown, end, 14.05, clicks: 2))
    view.mouseUp(with: mouse(.leftMouseUp, end, 14.06, clicks: 2))
    try check(copied == nil && view.selection == rectBetween(start, end),
              "Dragging a crop does not become the first click of a copy gesture")
    view.resetSelection(); copied = nil
    let snapPoint = NSPoint(x: 350, y: 150)
    view.mouseDown(with: mouse(.leftMouseDown, snapPoint, 15))
    let clickDriver = FrameDriver(view)
    let clickLink = view.displayLink(target: clickDriver, selector: #selector(FrameDriver.tick(_:)))
    view.benchmarkMotion = true
    view.displayTick(clickLink)
    view.benchmarkMotion = false
    clickLink.invalidate()
    view.mouseUp(with: mouse(.leftMouseUp, snapPoint, 15.01))
    view.mouseDown(with: mouse(.leftMouseDown, snapPoint, 15.05, clicks: 2))
    try check(copied?.pixelsWide == 400 && copied?.pixelsHigh == 400,
              "A render callback between press and release cannot discard a completed selection click")
    // Both editable rectangle types use the real canvas mouse handlers and history.
    view.resetSelection()
    var editTime: TimeInterval = 100
    func editDrag(_ start: CGPoint, _ end: CGPoint, intermediate: CGPoint? = nil) {
        editTime += 1
        view.mouseDown(with: mouse(.leftMouseDown, start, editTime))
        view.mouseDragged(with: mouse(.leftMouseDragged, intermediate ?? end, editTime + 0.1))
        view.mouseUp(with: mouse(.leftMouseUp, end, editTime + 0.2))
    }
    let originalSelection = CGRect(x: 100, y: 100, width: 600, height: 400)
    let originalRectangle = CGRect(x: 200, y: 200, width: 200, height: 150)
    editDrag(originalSelection.origin, CGPoint(x: originalSelection.maxX, y: originalSelection.maxY))
    editDrag(originalRectangle.origin, CGPoint(x: originalRectangle.maxX, y: originalRectangle.maxY))
    try check(view.marks.count == 1 && view.marks[0].rectangle == originalRectangle,
              "Drawing a rectangle creates an editable mark without changing the crop")
    try check(RectangleHandle.allCases.allSatisfy {
        view.surface.selectionHandles.path?.contains($0.point(in: originalSelection)) == $0.isCorner &&
        view.surface.rectangleHandles.path?.contains($0.point(in: originalRectangle)) == true
    }, "Crop shows only four corner brackets while annotations retain eight handles")
    try check(RectangleEditing.hit(CGPoint(x: 250, y: 200), rect: originalRectangle) == .edge &&
              RectangleEditing.hit(CGPoint(x: 300, y: 200), rect: originalRectangle) == .handle(.top) &&
              RectangleEditing.hit(CGPoint(x: 270, y: 270), rect: originalRectangle) == nil,
              "Handles take priority over edges while the rectangle interior remains free for drawing")
    let originalMark = view.marks[0]
    let originalLayer = view.surface.annotations.sublayers!.first!
    for handle in RectangleHandle.allCases {
        let point = handle.point(in: originalRectangle)
        editDrag(point, CGPoint(x: point.x + 10, y: point.y + 20))
        let expected = CGRect(x: originalRectangle.minX + (handle.movesLeft ? 10 : 0),
                              y: originalRectangle.minY + (handle.movesTop ? 20 : 0),
                              width: originalRectangle.width + (handle.movesRight ? 10 : 0) - (handle.movesLeft ? 10 : 0),
                              height: originalRectangle.height + (handle.movesBottom ? 20 : 0) - (handle.movesTop ? 20 : 0))
        try check(view.marks[0].rectangle == expected && view.selection == originalSelection,
                  "Annotation handle \(handle) changes only its intended edges")
        _ = view.performKeyEquivalent(with: key("z", command: true))
        try check(view.marks == [originalMark], "One undo restores annotation handle \(handle)")
    }
    try check(view.surface.annotations.sublayers!.first! === originalLayer && view.surface.backgroundUploads == 1,
              "Repeated rectangle edits reuse the vector layer and never re-upload the screenshot")
    for handle in RectangleHandle.allCases {
        let point = handle.point(in: originalSelection)
        editDrag(point, CGPoint(x: point.x + 10, y: point.y + 20))
        let expected = CGRect(x: originalSelection.minX + (handle.movesLeft ? 10 : 0),
                              y: originalSelection.minY + (handle.movesTop ? 20 : 0),
                              width: originalSelection.width + (handle.movesRight ? 10 : 0) - (handle.movesLeft ? 10 : 0),
                              height: originalSelection.height + (handle.movesBottom ? 20 : 0) - (handle.movesTop ? 20 : 0))
        try check(view.selection == expected && view.marks == [originalMark],
                  "Crop handle \(handle) resizes the capture area while annotations stay on their source content")
        _ = view.performKeyEquivalent(with: key("z", command: true))
    }
    editDrag(CGPoint(x: 250, y: 200), CGPoint(x: 280, y: 225), intermediate: CGPoint(x: 260, y: 210))
    let movedRectangle = originalRectangle.offsetBy(dx: 30, dy: 25)
    try check(view.marks[0].rectangle == movedRectangle && view.marks.count == 1,
              "Dragging an annotation edge moves the whole rectangle without creating a new mark")
    _ = view.performKeyEquivalent(with: key("z", command: true))
    try check(view.marks == [originalMark], "A complete annotation move is a single undo step")
    _ = view.performKeyEquivalent(with: key("z", command: true, shift: true))
    try check(view.marks[0].rectangle == movedRectangle, "Redo restores the annotation move")
    _ = view.performKeyEquivalent(with: key("z", command: true))

    editDrag(CGPoint(x: 250, y: 100), CGPoint(x: 290, y: 135))
    try check(view.selection == originalSelection.offsetBy(dx: 40, dy: 35) && view.marks == [originalMark],
              "Dragging a crop edge translates the crop without resizing or moving source annotations")
    copied = nil
    _ = view.performKeyEquivalent(with: key("c", command: true))
    let expectedExport = CaptureRenderer.render(image: canvas, canvasSize: canvasSize,
        selection: view.selection!, scale: 2, marks: view.marks)!
    try check(copied?.pixelsWide == 1200 && copied?.pixelsHigh == 800 &&
              copied?.representation(using: .png, properties: [:]) == expectedExport.representation(using: .png, properties: [:]),
              "Moved crop exports the correct pixels and annotations without edit handles")
    _ = view.performKeyEquivalent(with: key("z", command: true))
    try check(view.selection == originalSelection, "Undo restores the previous crop position")

    editDrag(CGPoint(x: 250, y: 100), CGPoint(x: 2000, y: 2000))
    try check(view.selection?.maxX == view.bounds.maxX && view.selection?.maxY == view.bounds.maxY &&
              view.selection?.size == originalSelection.size, "Crop movement clamps to screen edges without changing size")
    _ = view.performKeyEquivalent(with: key("z", command: true))
    editDrag(originalSelection.origin, CGPoint(x: 899, y: 699))
    try check(view.selection?.width == 8 && view.selection?.height == 8,
              "Dragging a crop handle across its opposite corner keeps a usable minimum size")
    _ = view.performKeyEquivalent(with: key("z", command: true))
    editDrag(CGPoint(x: 250, y: 200), CGPoint(x: 250, y: 200), intermediate: CGPoint(x: 280, y: 230))
    try check(view.marks == [originalMark], "Returning a dragged edge to its start restores the exact original rectangle")
    editDrag(CGPoint(x: 250, y: 250), CGPoint(x: 330, y: 300))
    try check(view.marks.count == 2 && view.marks[1].rectangle == CGRect(x: 250, y: 250, width: 80, height: 50),
              "Dragging inside an existing rectangle draws a new annotation")
    let inner = view.marks[1]
    editDrag(CGPoint(x: 270, y: 250), CGPoint(x: 280, y: 260))
    try check(view.marks[0] == originalMark && view.marks[1].rectangle == inner.rectangle?.offsetBy(dx: 10, dy: 10),
              "An inner rectangle edge moves only the targeted annotation")
    _ = view.performKeyEquivalent(with: key("z", command: true))
    _ = view.performKeyEquivalent(with: key("z", command: true))
    try check(view.marks == [originalMark], "Undoing an inner edit then its creation preserves the outer annotation")

    // Exercise real key-window transitions and child-window movement with generated content.
    // Unlike the earlier direct event-handler tests, key windows require a launched, active app.
    NSApp.setActivationPolicy(.accessory)
    NSApp.activate(ignoringOtherApps: true)
    let activationDeadline = Date(timeIntervalSinceNow: 2)
    while !NSApp.isActive && Date() < activationDeadline {
        if let event = NSApp.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.01),
                                       inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
    }
    let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 700)
    let shadowFrame = NSRect(x: visibleFrame.midX - 100, y: visibleFrame.midY - 60, width: 200, height: 120)
    let firstPin = PinnedCapture(bitmap: bitmap, frame: shadowFrame)
    let secondPin = PinnedCapture(bitmap: bitmap, frame: shadowFrame.offsetBy(dx: 240, dy: 0))
    defer { firstPin.close(); secondPin.close() }
    firstPin.show(); secondPin.show()
    try check(!firstPin.selectionShadow.isVisible && !secondPin.selectionShadow.isVisible,
              "Showing pins without selecting them does not show a blue selection shadow")
    firstPin.window?.makeKeyAndOrderFront(nil)
    try check(firstPin.selectionShadow.isVisible && firstPin.selectionShadow.parent === firstPin.window &&
              firstPin.selectionShadow.ignoresMouseEvents && !firstPin.selectionShadow.canBecomeKey,
              "Selecting a pin shows its external shadow without capturing mouse input or keyboard focus")
    secondPin.window?.makeKeyAndOrderFront(nil)
    try check(!firstPin.selectionShadow.isVisible && firstPin.selectionShadow.parent == nil &&
              secondPin.selectionShadow.isVisible && secondPin.window?.isKeyWindow == true,
              "Selecting another pin transfers the blue shadow to only that pin")
    let selectedFrame = secondPin.imageView.geometry.frame
    secondPin.imageView.zoom(by: 1.5, around: NSPoint(x: selectedFrame.midX, y: selectedFrame.midY))
    secondPin.imageView.applyFrame()
    let shadowPadding = PinnedSelectionShadow.padding
    try check(secondPin.selectionShadow.frame == secondPin.imageView.geometry.frame.insetBy(dx: -shadowPadding, dy: -shadowPadding) &&
              secondPin.window?.frame == secondPin.imageView.geometry.frame,
              "The blue shadow follows zoom while the image window keeps its exact unpadded geometry")
    let beforeMove = secondPin.window!.frame.origin
    secondPin.window?.setFrameOrigin(NSPoint(x: beforeMove.x + 23, y: beforeMove.y + 17))
    try check(secondPin.selectionShadow.frame == secondPin.window!.frame.insetBy(dx: -shadowPadding, dy: -shadowPadding),
              "The attached blue shadow follows window movement without an independent timer")
    secondPin.window?.orderOut(nil)
    try check(!secondPin.selectionShadow.isVisible,
              "Hiding a selected pin also hides its blue shadow")
    secondPin.window?.makeKeyAndOrderFront(nil)
    secondPin.close()
    try check(!secondPin.selectionShadow.isVisible && secondPin.selectionShadow.parent == nil,
              "Closing a selected pin removes its shadow window")

    for scale in [1, 2] {
        let shadowView = firstPin.selectionShadow.contentView!
        shadowView.layoutSubtreeIfNeeded()
        let width = Int(shadowView.bounds.width) * scale, height = Int(shadowView.bounds.height) * scale
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        shadowView.layer!.render(in: context)
        let raster = NSBitmapImageRep(cgImage: context.makeImage()!)
        let padding = Int(shadowPadding) * scale
        let edgePoints = [(padding - 1, height / 2), (width - padding, height / 2),
                          (width / 2, padding - 1), (width / 2, height - padding)]
        let edges = edgePoints.map { rgb(raster, $0.0, $0.1) }
        let alpha = edges.map { $0.alphaComponent }
        try check(edges.allSatisfy { $0.blueComponent > $0.greenComponent && $0.greenComponent > $0.redComponent &&
                                   $0.alphaComponent > 0.02 && $0.alphaComponent < 0.4 } &&
                  alpha.max()! - alpha.min()! < 0.02 && rgb(raster, 0, 0).alphaComponent < 0.01,
                  "Composited \(scale)x selection shadow is soft blue on all four sides with a transparent outer margin")
        if scale == 2, let i = CommandLine.arguments.firstIndex(of: "--shadow-preview"),
           CommandLine.arguments.count > i + 1 {
            context.saveGState()
            context.setBlendMode(.destinationOver)
            context.setFillColor(NSColor.white.cgColor); context.fill(shadowView.bounds)
            context.restoreGState()
            context.draw(bitmap.cgImage!, in: shadowView.bounds.insetBy(dx: shadowPadding, dy: shadowPadding))
            let preview = NSBitmapImageRep(cgImage: context.makeImage()!)
            try preview.representation(using: .png, properties: [:])!.write(
                to: URL(fileURLWithPath: CommandLine.arguments[i + 1]), options: .atomic)
        }
    }

    // Inject generated captures into the full production flow, including its
    // asynchronous wait, rather than reading the desktop or only testing a panel flag.
    func waitForCaptureState(_ ready: () -> Bool) -> Bool {
        let deadline = Date(timeIntervalSinceNow: 3)
        while !ready() && Date() < deadline {
            if let event = NSApp.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.01),
                                           inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
        }
        return ready()
    }
    var foregroundPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
    var capturePin: PinnedCapture?
    var pinsStayedVisible = true
    var foregroundStayedUnchanged = true
    var completedCaptures = 0
    let captureApp = AppDelegate(screenPermission: { true }, captureScreens: { displays in
        pinsStayedVisible = pinsStayedVisible && capturePin?.window?.isVisible == true
        foregroundStayedUnchanged = foregroundStayedUnchanged && NSWorkspace.shared.frontmostApplication?.processIdentifier == foregroundPID
        try await Task.sleep(nanoseconds: 40_000_000)
        pinsStayedVisible = pinsStayedVisible && capturePin?.window?.isVisible == true
        foregroundStayedUnchanged = foregroundStayedUnchanged && NSWorkspace.shared.frontmostApplication?.processIdentifier == foregroundPID
        completedCaptures += 1
        return displays.map { ($0.index, bitmap.cgImage!) }
    })
    captureApp.pinCapture(PinnedContent(bitmap: bitmap), frame: shadowFrame)
    capturePin = captureApp.pinnedCaptures.last
    defer { captureApp.finishCapture(); capturePin?.close() }
    // Merely clearing AppKit's active flag does not ask WindowServer to hand
    // foreground ownership back. Hide/unhide this test app without activating it.
    NSApp.hide(nil)
    let handedOff = waitForCaptureState { !NSApp.isActive && NSWorkspace.shared.frontmostApplication?.processIdentifier != getpid() }
    NSApp.unhideWithoutActivation()
    try check(handedOff && waitForCaptureState { !NSApp.isActive && !NSApp.isHidden && capturePin?.window?.isVisible == true },
              "Capture lifecycle regression starts with another application in the foreground")
    foregroundPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
    captureApp.startCapture()
    try check(capturePin?.window?.isVisible == true && waitForCaptureState { !captureApp.overlays.isEmpty },
              "Starting capture leaves existing pins visible while the asynchronous screenshot is pending")
    let presented = captureApp.overlays
    // Allow WindowServer focus notifications and initial display callbacks to
    // settle. A panel's AppKit active appearance is not foreground ownership.
    let focusSettled = Date(timeIntervalSinceNow: 0.1)
    _ = waitForCaptureState { Date() >= focusSettled }
    if !pinsStayedVisible || !foregroundStayedUnchanged || NSWorkspace.shared.frontmostApplication?.processIdentifier != foregroundPID {
        print("CAPTURE STATE: pins=\(pinsStayedVisible), foregroundStable=\(foregroundStayedUnchanged), active=\(NSApp.isActive), expectedPID=\(foregroundPID ?? -1), currentPID=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1), panel=\(presented.first?.styleMask.rawValue ?? 0)")
    }
    try check(pinsStayedVisible && foregroundStayedUnchanged &&
              NSWorkspace.shared.frontmostApplication?.processIdentifier == foregroundPID,
              "Presenting capture preserves the foreground application and never hides or restores pins")
    let panelTookKeyboardFocus = waitForCaptureState { presented.contains { $0.isKeyWindow } }
    if !panelTookKeyboardFocus {
        print("PANEL FOCUS: active=\(NSApp.isActive), hidden=\(NSApp.isHidden), key=\(NSApp.keyWindow?.windowNumber ?? -1), panels=\(presented.map { [$0.windowNumber, $0.isKeyWindow ? 1 : 0, $0.isVisible ? 1 : 0] })")
    }
    try check(presented.allSatisfy { $0.styleMask.contains(.nonactivatingPanel) && $0.isVisible && !$0.hidesOnDeactivate } &&
              panelTookKeyboardFocus && NSWorkspace.shared.frontmostApplication?.processIdentifier == foregroundPID,
              "Nonactivating capture panels receive keyboard focus without activating QuickMark")
    let mouseScreenPoint = NSEvent.mouseLocation
    let readyCanvas = presented.first { $0.frame.contains(mouseScreenPoint) }.flatMap { $0.contentView as? CaptureView }
    let readyPoint = readyCanvas.map { $0.convert($0.window!.convertPoint(fromScreen: mouseScreenPoint), from: nil) }
    try check(readyCanvas != nil && readyCanvas!.surface.outline.path?.boundingBox == readyCanvas!.target(at: readyPoint!)?.frame &&
              readyCanvas!.surface.backgroundUploads == 1,
              "The first presented capture frame already contains its background, hover outline, and guides")
    let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 200,
        windowNumber: presented.first!.windowNumber, context: nil, characters: "\u{1b}",
        charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
    presented.first?.sendEvent(escape)
    try check(captureApp.overlays.isEmpty && presented.allSatisfy { !$0.isVisible } && capturePin?.window?.isVisible == true &&
              NSWorkspace.shared.frontmostApplication?.processIdentifier == foregroundPID,
              "Escape dismisses only the capture layer and preserves the original foreground and pin")
    captureApp.startCapture()
    captureApp.finishCapture()
    try check(waitForCaptureState { completedCaptures == 2 } && captureApp.overlays.isEmpty &&
              capturePin?.window?.isVisible == true && pinsStayedVisible,
              "Cancelling a pending capture cannot flash pins or reopen a stale capture layer")
    NSApp.activate(ignoringOtherApps: true)
    _ = waitForCaptureState { NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() }
    capturePin?.window?.makeKeyAndOrderFront(nil)
    captureApp.startCapture()
    try check(waitForCaptureState { !captureApp.overlays.isEmpty }, "Capture also opens when a QuickMark pin was selected")
    captureApp.finishCapture()
    try check(capturePin?.window?.isKeyWindow == true && capturePin?.selectionShadow.isVisible == true &&
              capturePin?.window?.frame == shadowFrame && capturePin?.imageView.textureUploads == 1,
              "Finishing capture restores the selected pin and its blue shadow without moving or reuploading it")

    print("All \(checks) rendering and interaction checks passed.")
}
