// Standalone build helper. Uses CoreGraphics only; no screen access.
import CoreGraphics
import ImageIO
import Foundation

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let side = points * scale
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.scaleBy(x: CGFloat(side) / 1024, y: CGFloat(side) / 1024)
        context.setFillColor(CGColor(red: 0.96, green: 0.95, blue: 0.91, alpha: 1))
        context.addPath(CGPath(roundedRect: CGRect(x: 72, y: 72, width: 880, height: 880), cornerWidth: 196, cornerHeight: 196, transform: nil))
        context.fillPath()
        context.setStrokeColor(CGColor(red: 0.17, green: 0.20, blue: 0.18, alpha: 1))
        context.setLineWidth(66)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.move(to: CGPoint(x: 338, y: 776))
        context.addLine(to: CGPoint(x: 338, y: 338))
        context.addLine(to: CGPoint(x: 776, y: 338))
        context.strokePath()
        context.move(to: CGPoint(x: 248, y: 686))
        context.addLine(to: CGPoint(x: 686, y: 686))
        context.addLine(to: CGPoint(x: 686, y: 248))
        context.strokePath()
        context.setStrokeColor(CGColor(red: 0.88, green: 0.29, blue: 0.12, alpha: 1))
        context.setLineWidth(54)
        context.move(to: CGPoint(x: 454, y: 456))
        context.addLine(to: CGPoint(x: 576, y: 578))
        context.move(to: CGPoint(x: 477, y: 578))
        context.addLine(to: CGPoint(x: 576, y: 578))
        context.addLine(to: CGPoint(x: 576, y: 479))
        context.strokePath()
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        let destination = CGImageDestinationCreateWithURL(output.appendingPathComponent(name) as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        guard CGImageDestinationFinalize(destination) else { fatalError("Unable to write icon") }
    }
}
