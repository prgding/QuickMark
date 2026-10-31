import AppKit

enum MarkTool: String, CaseIterable {
    case arrow, rectangle, pen, text
    var title: String {
        switch self { case .arrow: return "箭头"; case .rectangle: return "方框"; case .pen: return "画笔"; case .text: return "文字" }
    }
    var symbol: String {
        switch self { case .arrow: return "arrow.up.right"; case .rectangle: return "rectangle"; case .pen: return "pencil.tip"; case .text: return "textformat" }
    }
    var shortcut: String {
        switch self { case .arrow: return "A"; case .rectangle: return "R"; case .pen: return "P"; case .text: return "⌘T" }
    }
}

struct Mark: Equatable {
    let tool: MarkTool
    var points: [NSPoint]
    let color: NSColor
    let width: CGFloat
    var text = ""

    func draw() {
        guard let first = points.first, let last = points.last else { return }
        color.setStroke()
        color.setFill()
        let path = NSBezierPath()
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        switch tool {
        case .arrow:
            let distance = hypot(last.x - first.x, last.y - first.y)
            guard distance > 2 else { return }
            let angle = atan2(last.y - first.y, last.x - first.x)
            let head = min(max(width * 4, 13), distance * 0.45)
            path.move(to: first)
            path.line(to: last)
            path.move(to: NSPoint(x: last.x - head * cos(angle - .pi / 6), y: last.y - head * sin(angle - .pi / 6)))
            path.line(to: last)
            path.line(to: NSPoint(x: last.x - head * cos(angle + .pi / 6), y: last.y - head * sin(angle + .pi / 6)))
            path.stroke()
        case .rectangle:
            path.appendRect(rectBetween(first, last))
            path.stroke()
        case .pen:
            if points.count == 1 {
                NSBezierPath(ovalIn: NSRect(x: first.x - width / 2, y: first.y - width / 2, width: width, height: width)).fill()
            } else {
                path.move(to: first)
                for point in points.dropFirst() { path.line(to: point) }
                path.stroke()
            }
        case .text:
            (text as NSString).draw(at: first, withAttributes: [
                .font: NSFont.systemFont(ofSize: textSize, weight: .semibold),
                .foregroundColor: color
            ])
        }
    }

    var textSize: CGFloat { 16 + width * 2 }
}

enum TextRaster {
    struct Result { let frame: CGRect; let image: CGImage }
    /// Render glyphs directly at the requested pixel density. No shadow blur or whole-canvas rasterization.
    static func render(_ mark: Mark, scale: CGFloat, clipping: CGRect) -> Result? {
        guard mark.tool == .text, let origin = mark.points.first else { return nil }
        let font = NSFont.systemFont(ofSize: mark.textSize, weight: .semibold)
        let size = (mark.text as NSString).size(withAttributes: [.font: font])
        let measured = CGRect(x: origin.x - 1, y: origin.y - 1, width: size.width + 2, height: size.height + 2).intersection(clipping)
        guard !measured.isNull, !measured.isEmpty else { return nil }
        let left = floor(measured.minX * scale), top = floor(measured.minY * scale)
        let width = max(1, Int(ceil(measured.maxX * scale) - left))
        let height = max(1, Int(ceil(measured.maxY * scale) - top))
        let frame = CGRect(x: left / scale, y: top / scale, width: CGFloat(width) / scale, height: CGFloat(height) / scale)
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        let context = graphics.cgContext
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -frame.minX, y: -frame.minY)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        mark.draw()
        NSGraphicsContext.restoreGraphicsState()
        guard let image = bitmap.cgImage else { return nil }
        return Result(frame: frame, image: image)
    }
}

func rectBetween(_ a: NSPoint, _ b: NSPoint) -> NSRect {
    NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
}

enum CaptureRenderer {
    /// The UI and export share top-left point coordinates. Output retains the source pixel density.
    static func render(image: NSImage, canvasSize: NSSize, selection: NSRect, scale: CGFloat, marks: [Mark]) -> NSBitmapImageRep? {
        let pixelWidth = max(1, Int((selection.width * scale).rounded()))
        let pixelHeight = max(1, Int((selection.height * scale).rounded()))
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixelWidth, pixelsHigh: pixelHeight,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        bitmap.size = selection.size
        NSGraphicsContext.saveGraphicsState()
        let cg = context.cgContext
        cg.translateBy(x: 0, y: CGFloat(pixelHeight))
        cg.scaleBy(x: scale, y: -scale)
        cg.translateBy(x: -selection.minX, y: -selection.minY)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        image.draw(in: NSRect(origin: .zero, size: canvasSize), from: .zero, operation: .copy,
                   fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        for mark in marks { mark.draw() }
        cg.flush()
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }

    static func demoImage(size: NSSize) -> NSImage {
        NSImage(size: size, flipped: true) { rect in
            NSColor(calibratedRed: 0.94, green: 0.93, blue: 0.89, alpha: 1).setFill()
            rect.fill()
            let card = NSRect(x: size.width * 0.18, y: size.height * 0.22,
                              width: size.width * 0.64, height: size.height * 0.56)
            NSColor.white.setFill()
            NSBezierPath(roundedRect: card, xRadius: 24, yRadius: 24).fill()
            let x = card.minX + 40
            let y = card.minY + 36
            ("QUICKMARK  /  练习画布" as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.gray])
            ("圈出重点，即刻分享。" as NSString).draw(at: NSPoint(x: x, y: y + 44), withAttributes: [
                .font: NSFont.systemFont(ofSize: 32, weight: .bold), .foregroundColor: NSColor.black])
            ("拖动框选一块区域，然后试试箭头、方框、画笔和文字。" as NSString).draw(at: NSPoint(x: x, y: y + 98), withAttributes: [
                .font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.darkGray])
            let colors: [NSColor] = [.systemOrange, .systemBlue, .systemGreen]
            for (index, color) in colors.enumerated() {
                let tile = NSRect(x: x + CGFloat(index) * (card.width - 96) / 3, y: y + 150,
                                  width: (card.width - 120) / 3, height: max(50, card.height - 230))
                color.withAlphaComponent(0.13).setFill()
                NSBezierPath(roundedRect: tile, xRadius: 12, yRadius: 12).fill()
                ( ["01  框选", "02  标注", "03  复制"][index] as NSString).draw(at: NSPoint(x: tile.minX + 16, y: tile.minY + 22), withAttributes: [
                    .font: NSFont.systemFont(ofSize: 17, weight: .semibold), .foregroundColor: color])
            }
            return true
        }
    }
}
