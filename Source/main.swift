import AppKit

let application = NSApplication.shared
if CommandLine.arguments.contains("--diagnose-gestures") {
    GestureDiagnostics.run()
} else if CommandLine.arguments.contains("--benchmark-pins") {
    runPinnedPerformanceTest()
} else if CommandLine.arguments.contains("--benchmark") {
    runPerformanceTest()
} else if CommandLine.arguments.contains("--self-test") {
    // Native background-panel focus requires a running AppKit application.
    application.setActivationPolicy(.accessory)
    application.finishLaunching()
    let tests = Timer(timeInterval: 0, repeats: false) { _ in
        do { try runSelfTests(); exit(0) }
        catch { fputs("SELF-TEST FAILED: \(error)\n", stderr); exit(1) }
    }
    RunLoop.main.add(tests, forMode: .common)
    application.run()
} else {
    let delegate = AppDelegate()
    application.delegate = delegate
    application.run()
}
