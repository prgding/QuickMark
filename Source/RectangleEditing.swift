import AppKit

/// Coordinates follow the flipped capture canvas: top is minY.
enum RectangleHandle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    var movesLeft: Bool { [.topLeft, .left, .bottomLeft].contains(self) }
    var movesRight: Bool { [.topRight, .right, .bottomRight].contains(self) }
    var movesTop: Bool { [.topLeft, .top, .topRight].contains(self) }
    var movesBottom: Bool { [.bottomLeft, .bottom, .bottomRight].contains(self) }
    var isCorner: Bool { (movesLeft || movesRight) && (movesTop || movesBottom) }

    func point(in rect: CGRect) -> CGPoint {
        CGPoint(x: movesLeft ? rect.minX : (movesRight ? rect.maxX : rect.midX),
                y: movesTop ? rect.minY : (movesBottom ? rect.maxY : rect.midY))
    }
}

enum RectangleHit: Equatable {
    case handle(RectangleHandle)
    case edge
}

enum RectangleEditing {
    static let handleSize: CGFloat = 6
    static let handleRadius: CGFloat = 8

    static func hit(_ point: CGPoint, rect: CGRect, edgeTolerance: CGFloat = 4,
                    cornerBrackets: Bool = false) -> RectangleHit? {
        guard rect.insetBy(dx: -handleRadius, dy: -handleRadius).contains(point) else { return nil }
        // Nearest handle wins when the hit areas of a small rectangle overlap.
        let nearest = RectangleHandle.allCases.min {
            distance(point, $0.point(in: rect)) < distance(point, $1.point(in: rect))
        }!
        if distance(point, nearest.point(in: rect)) <= handleRadius { return .handle(nearest) }
        if cornerBrackets, nearest.isCorner {
            // Match the visible L-shaped arms, without expanding into the canvas interior.
            let corner = nearest.point(in: rect)
            let dx = abs(point.x - corner.x), dy = abs(point.y - corner.y)
            let length = cornerLength(in: rect)
            if (dx <= length && dy <= edgeTolerance) || (dy <= length && dx <= edgeTolerance) {
                return .handle(nearest)
            }
        }
        let onHorizontal = point.x >= rect.minX && point.x <= rect.maxX &&
            min(abs(point.y - rect.minY), abs(point.y - rect.maxY)) <= edgeTolerance
        let onVertical = point.y >= rect.minY && point.y <= rect.maxY &&
            min(abs(point.x - rect.minX), abs(point.x - rect.maxX)) <= edgeTolerance
        return onHorizontal || onVertical ? .edge : nil
    }

    static func transform(_ rect: CGRect, hit: RectangleHit, from start: CGPoint, to point: CGPoint,
                          within bounds: CGRect, minimum: CGFloat) -> CGRect {
        let dx = point.x - start.x, dy = point.y - start.y
        switch hit {
        case .edge:
            return CGRect(x: min(max(rect.minX + dx, bounds.minX), bounds.maxX - rect.width),
                          y: min(max(rect.minY + dy, bounds.minY), bounds.maxY - rect.height),
                          width: rect.width, height: rect.height)
        case .handle(let handle):
            var left = rect.minX, right = rect.maxX, top = rect.minY, bottom = rect.maxY
            let minWidth = min(minimum, rect.width), minHeight = min(minimum, rect.height)
            if handle.movesLeft { left = min(max(left + dx, bounds.minX), right - minWidth) }
            if handle.movesRight { right = max(min(right + dx, bounds.maxX), left + minWidth) }
            if handle.movesTop { top = min(max(top + dy, bounds.minY), bottom - minHeight) }
            if handle.movesBottom { bottom = max(min(bottom + dy, bounds.maxY), top + minHeight) }
            return CGRect(x: left, y: top, width: right - left, height: bottom - top)
        }
    }

    static func handlePath(for rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        for handle in RectangleHandle.allCases {
            let point = handle.point(in: rect)
            path.addRect(CGRect(x: point.x - handleSize / 2, y: point.y - handleSize / 2,
                                width: handleSize, height: handleSize))
        }
        return path
    }

    /// Four L-shaped brackets for the crop, without visible midpoint dots.
    /// Hit testing still exposes all eight resize positions independently of this decoration.
    private static func cornerLength(in rect: CGRect) -> CGFloat {
        min(18, min(rect.width, rect.height) / 3)
    }

    static func cornerPath(for rect: CGRect) -> CGPath {
        let path = CGMutablePath()
        let length = cornerLength(in: rect)
        let thickness = min(3, length)
        for handle in RectangleHandle.allCases where handle.isCorner {
            let point = handle.point(in: rect)
            let x = handle.movesLeft ? point.x - thickness / 2 : point.x + thickness / 2 - length
            let y = handle.movesTop ? point.y - thickness / 2 : point.y + thickness / 2 - length
            path.addRect(CGRect(x: x, y: point.y - thickness / 2, width: length, height: thickness))
            path.addRect(CGRect(x: point.x - thickness / 2, y: y, width: thickness, height: length))
        }
        return path
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
}

extension Mark {
    var rectangle: CGRect? {
        guard tool == .rectangle, let first = points.first, let last = points.last else { return nil }
        return rectBetween(first, last)
    }
}
