import AppKit
import QuartzCore

/// Runs the production layer path with synthetic pointer positions and a generated image.
/// Measures callback cadence and CPU update cost, not physical panel presentation or input latency.
func runPerformanceTest() {
    NSApp.setActivationPolicy(.accessory)
    var windows: [CaptureWindow] = []
    let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
    for screen in NSScreen.screens {
        let window = CaptureWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = .screenSaver
        window.isReleasedWhenClosed = false
        let target = WindowTarget(id: 1, name: "性能测试 · 合成窗口", frame:
            CGRect(x: screen.frame.minX + screen.frame.width * 0.18, y: primaryTop - screen.frame.maxY + screen.frame.height * 0.22,
                   width: screen.frame.width * 0.64, height: screen.frame.height * 0.56))
        let view = CaptureView(frame: CGRect(origin: .zero, size: screen.frame.size), image: CaptureRenderer.demoImage(size: screen.frame.size),
                               scale: screen.backingScaleFactor, targets: [target], screenFrame: screen.frame, primaryTop: primaryTop)
        view.benchmarkMotion = true
        view.onCancel = { NSApp.terminate(nil) }
        window.contentView = view
        window.orderFrontRegardless()
        window.makeFirstResponder(view)
        view.startRendering()
        windows.append(window)
    }
    NSApp.activate(ignoringOtherApps: true)
    windows.first?.makeKeyAndOrderFront(nil)
    DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
        var reports: [[String: Any]] = []
        for window in windows {
            guard let view = window.contentView as? CaptureView, let screen = window.screen else { continue }
            view.stopRendering()
            var report = view.metrics.report
            report["display"] = screen.localizedName
            report["requestedHz"] = view.requestedHz
            report["physicalPixels"] = [Int(screen.frame.width * screen.backingScaleFactor), Int(screen.frame.height * screen.backingScaleFactor)]
            report["screenshotTextureUploads"] = view.surface.backgroundUploads
            reports.append(report)
            window.orderOut(nil)
        }
        let result: [String: Any] = ["test": "Production layers + synthetic moving guides and window hit testing; 8 seconds; 0.5s warmup",
                                    "measures": "Display-link callback cadence and CPU update time, NOT physical presented frames or hardware cursor latency",
                                    "displays": reports]
        let data = try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        if let i = CommandLine.arguments.firstIndex(of: "--report"), CommandLine.arguments.count > i + 1 {
            do { try data.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]), options: .atomic) }
            catch { fputs("Cannot save report: \(error)\n", stderr); exit(1) }
        }
        exit(0)
    }
    NSApp.run()
}

func runPinnedPerformanceTest() {
    NSApp.setActivationPolicy(.accessory)
    var pins: [PinnedCapture] = []
    for screen in NSScreen.screens {
        let size = NSSize(width: 700, height: 420)
        let rect = NSRect(origin: .zero, size: size)
        guard let bitmap = CaptureRenderer.render(image: CaptureRenderer.demoImage(size: size), canvasSize: size,
                                                   selection: rect, scale: screen.backingScaleFactor, marks: []) else { continue }
        let frame = NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2,
                           width: size.width, height: size.height)
        let pin = PinnedCapture(bitmap: bitmap, frame: frame)
        pin.onClose = { NSApp.terminate(nil) }
        pin.show()
        pin.imageView.startBenchmark()
        pins.append(pin)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
        let reports: [[String: Any]] = pins.map { pin in
            let view = pin.imageView
            view.stopRendering()
            var report = view.metrics.report
            report["display"] = pin.window?.screen?.localizedName ?? "Unknown"
            report["requestedHz"] = view.requestedHz
            report["windowPositionUpdates"] = view.frameUpdates
            report["textureUploads"] = view.textureUploads
            pin.window?.orderOut(nil)
            return report
        }
        let result: [String: Any] = ["test": "Pinned screenshot production window movement; synthetic pointer; 8 seconds; 0.5s warmup",
                                    "measures": "Display-link cadence, window position update calls and CPU time, NOT physical presentation or end-to-end mouse latency",
                                    "displays": reports]
        let data = try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        if let i = CommandLine.arguments.firstIndex(of: "--report"), CommandLine.arguments.count > i + 1 {
            do { try data.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]), options: .atomic) }
            catch { fputs("Cannot save report: \(error)\n", stderr); exit(1) }
        }
        exit(0)
    }
    NSApp.run()
}
