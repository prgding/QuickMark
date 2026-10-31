import AppKit
import ScreenCaptureKit

struct CaptureDisplay {
    let index: Int
    let id: UInt32
    let frame: CGRect
    let scale: CGFloat
    var pixelWidth: Int { Int((frame.width * scale).rounded()) }
    var pixelHeight: Int { Int((frame.height * scale).rounded()) }

    static func quartzFrame(_ screen: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: screen.minX, y: primaryTop - screen.maxY, width: screen.width, height: screen.height)
    }
}

enum ScreenCaptureService {
    /// Capture only on demand. Independent displays run concurrently; no live recording or stale image cache.
    static func capture(_ displays: [CaptureDisplay]) async throws -> [(Int, CGImage)] {
        if #available(macOS 26.0, *) {
            return try await withThrowingTaskGroup(of: (Int, CGImage).self) { group in
                for display in displays {
                    group.addTask {
                        let configuration = SCScreenshotConfiguration()
                        configuration.width = display.pixelWidth
                        configuration.height = display.pixelHeight
                        configuration.showsCursor = false
                        // Screenshot configurations default to stripping window shadows.
                        // Preserve the desktop's original window framing and occlusion.
                        configuration.ignoreShadows = false
                        configuration.ignoreClipping = false
                        configuration.displayIntent = .local
                        configuration.dynamicRange = .sdr
                        let output = try await SCScreenshotManager.captureScreenshot(rect: display.frame, configuration: configuration)
                        guard let image = output.sdrImage else { throw CaptureError.noDisplay }
                        return (display.index, image)
                    }
                }
                var results: [(Int, CGImage)] = []
                for try await result in group { results.append(result) }
                return results.sorted { $0.0 < $1.0 }
            }
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return try await withThrowingTaskGroup(of: (Int, CGImage).self) { group in
            for display in displays {
                guard let source = content.displays.first(where: { $0.displayID == display.id }) else { continue }
                // Match the region API: retain all visible windows, including pins,
                // without hiding or reordering anything on the live desktop.
                let filter = SCContentFilter(display: source, excludingWindows: [])
                if #available(macOS 14.2, *) { filter.includeMenuBar = true }
                group.addTask {
                    let configuration = SCStreamConfiguration()
                    configuration.width = display.pixelWidth
                    configuration.height = display.pixelHeight
                    configuration.showsCursor = false
                    configuration.ignoreShadowsDisplay = false
                    configuration.ignoreGlobalClipDisplay = false
                    configuration.capturesAudio = false
                    configuration.captureResolution = .best
                    return (display.index, try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration))
                }
            }
            var results: [(Int, CGImage)] = []
            for try await result in group { results.append(result) }
            return results.sorted { $0.0 < $1.0 }
        }
    }
}
