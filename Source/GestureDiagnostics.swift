import AppKit

/// Opt-in input diagnostics for generated test content only. No screen images or typed text.
enum GestureDiagnostics {
    static let enabled = CommandLine.arguments.contains("--diagnose-gestures")
    static var events: [[String: Any]] = []
    static var monitor: Any?
    static var timer: Timer?
    static var pin: PinnedCapture?
    static var status: NSWindow?

    static func record(_ stage: String, _ event: NSEvent, view: PinnedImageView? = nil) {
        guard enabled else { return }
        let types: [NSEvent.EventType] = [.magnify, .gesture, .scrollWheel, .beginGesture, .endGesture, .rotate, .leftMouseDown]
        guard types.contains(event.type) || stage.hasPrefix("touches") else { return }
        var item: [String: Any] = ["stage": stage, "type": event.type.rawValue,
                                  "phase": event.phase.rawValue, "time": event.timestamp,
                                  "window": event.windowNumber, "appActive": NSApp.isActive,
                                  "keyWindow": NSApp.keyWindow?.windowNumber ?? -1]
        if event.type == .magnify { item["magnification"] = event.magnification }
        if event.type == .scrollWheel {
            item["scrollY"] = event.scrollingDeltaY
            item["precise"] = event.hasPreciseScrollingDeltas
            item["momentumPhase"] = event.momentumPhase.rawValue
            item["naturalDirection"] = event.isDirectionInvertedFromDevice
        }
        if let view {
            item["touches"] = event.touches(matching: .touching, in: view).count
            item["zoom"] = view.geometry.zoom
        }
        events.append(item)
        if events.count > 6000 { events.removeFirst(events.count - 6000) }
    }

    static func flush() {
        guard let i = CommandLine.arguments.firstIndex(of: "--report"), CommandLine.arguments.count > i + 1 else { return }
        let report: [String: Any] = ["events": events, "zoom": pin?.imageView.geometry.zoom ?? 0,
                                    "keyWindow": NSApp.keyWindow?.windowNumber ?? -1,
                                    "appActive": NSApp.isActive]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]), options: .atomic)
        }
    }

    static func run() {
        NSApp.setActivationPolicy(.accessory)
        guard let screen = NSScreen.main else { exit(1) }
        let size = NSSize(width: 640, height: 360)
        let bitmap = CaptureRenderer.render(image: CaptureRenderer.demoImage(size: size), canvasSize: size,
            selection: NSRect(origin: .zero, size: size), scale: screen.backingScaleFactor, marks: [])!
        let frame = NSRect(x: screen.visibleFrame.midX - size.width / 2,
                           y: screen.visibleFrame.midY - size.height / 2, width: size.width, height: size.height)
        let testPin = PinnedCapture(bitmap: bitmap, frame: frame)
        testPin.window?.title = "QuickMark 捏合诊断贴图"
        testPin.onClose = { flush(); NSApp.terminate(nil) }
        pin = testPin
        monitor = NSEvent.addLocalMonitorForEvents(matching: .any) { event in
            record("application", event)
            return event
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in flush() }
        testPin.show()
        flush()
        NSApp.run()
    }
}
