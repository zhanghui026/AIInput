import CoreGraphics

enum PanelPlacement {
    enum Side: Equatable {
        case below
        case above
    }

    struct Result: Equatable {
        let frame: CGRect
        let side: Side
    }

    static func nearCursor(
        cursor: CGPoint,
        panelSize: CGSize,
        visibleFrame: CGRect,
        gap: CGFloat = 16,
        margin: CGFloat = 8
    ) -> Result {
        let usableFrame = usableFrame(from: visibleFrame, margin: margin)
        let fittedSize = CGSize(
            width: min(max(0, panelSize.width), usableFrame.width),
            height: min(max(0, panelSize.height), usableFrame.height)
        )
        let safeGap = max(0, gap)
        let roomBelow = cursor.y - safeGap - usableFrame.minY
        let roomAbove = usableFrame.maxY - cursor.y - safeGap
        let side: Side

        if roomBelow >= fittedSize.height {
            side = .below
        } else if roomAbove >= fittedSize.height {
            side = .above
        } else {
            side = roomBelow >= roomAbove ? .below : .above
        }

        let proposedY: CGFloat
        switch side {
        case .below:
            proposedY = cursor.y - safeGap - fittedSize.height
        case .above:
            proposedY = cursor.y + safeGap
        }

        let proposedFrame = CGRect(
            x: cursor.x - fittedSize.width / 2,
            y: proposedY,
            width: fittedSize.width,
            height: fittedSize.height
        )
        return Result(frame: fit(proposedFrame, in: visibleFrame, margin: margin), side: side)
    }

    /// 面板内容相对面板左边缘的缩进：让面板里的文字与被翻译的文字左对齐。
    static let contentInset: CGFloat = 22

    /// 贴在选中文字（或光标）下方；下方放不下时翻到上方。不遮挡原文。
    static func anchored(
        below textRect: CGRect,
        panelSize: CGSize,
        visibleFrame: CGRect,
        gap: CGFloat = 10,
        margin: CGFloat = 8
    ) -> Result {
        let usableFrame = usableFrame(from: visibleFrame, margin: margin)
        let text = textRect.standardized
        let height = min(max(0, panelSize.height), usableFrame.height)
        let roomBelow = text.minY - gap - usableFrame.minY
        let roomAbove = usableFrame.maxY - text.maxY - gap

        let side: Side
        if roomBelow >= height {
            side = .below
        } else if roomAbove >= height {
            side = .above
        } else {
            side = roomBelow >= roomAbove ? .below : .above
        }
        let originY = side == .below ? text.minY - gap - height : text.maxY + gap
        let proposed = CGRect(
            x: text.minX - contentInset,
            y: originY,
            width: panelSize.width,
            height: height
        )
        return Result(frame: fit(proposed, in: visibleFrame, margin: margin), side: side)
    }

    /// 屏幕上方居中（像 Spotlight），只向下伸长。
    static func topCenter(
        panelSize: CGSize,
        visibleFrame: CGRect,
        topFraction: CGFloat = 0.18,
        margin: CGFloat = 8
    ) -> Result {
        let frame = visibleFrame.standardized
        let top = frame.maxY - frame.height * topFraction
        let proposed = CGRect(
            x: frame.midX - panelSize.width / 2,
            y: top - panelSize.height,
            width: panelSize.width,
            height: panelSize.height
        )
        return Result(frame: fit(proposed, in: visibleFrame, margin: margin), side: .below)
    }

    /// 用户拖动后记住的位置（左上角），只向下伸长。
    static func pinned(
        topLeft: CGPoint,
        panelSize: CGSize,
        visibleFrame: CGRect,
        margin: CGFloat = 8
    ) -> Result {
        let proposed = CGRect(
            x: topLeft.x,
            y: topLeft.y - panelSize.height,
            width: panelSize.width,
            height: panelSize.height
        )
        return Result(frame: fit(proposed, in: visibleFrame, margin: margin), side: .below)
    }

    /// 辅助功能坐标原点在主屏左上角、y 向下；Cocoa 原点在主屏左下角、y 向上。
    static func cocoaRect(fromAX rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryScreenHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    static func fit(
        _ frame: CGRect,
        in visibleFrame: CGRect,
        margin: CGFloat = 8
    ) -> CGRect {
        let usableFrame = usableFrame(from: visibleFrame, margin: margin)
        var fitted = frame.standardized
        fitted.size.width = min(fitted.width, usableFrame.width)
        fitted.size.height = min(fitted.height, usableFrame.height)
        fitted.origin.x = min(max(fitted.minX, usableFrame.minX), usableFrame.maxX - fitted.width)
        fitted.origin.y = min(max(fitted.minY, usableFrame.minY), usableFrame.maxY - fitted.height)
        return fitted
    }

    static func fit(
        _ frame: CGRect,
        toBestOf visibleFrames: [CGRect],
        margin: CGFloat = 8
    ) -> CGRect {
        guard let visibleFrame = bestVisibleFrame(for: frame, among: visibleFrames) else {
            return frame.standardized
        }
        return fit(frame, in: visibleFrame, margin: margin)
    }

    static func resizedFrame(
        from currentFrame: CGRect,
        to panelSize: CGSize,
        placementSide: Side,
        visibleFrames: [CGRect],
        margin: CGFloat = 8
    ) -> CGRect {
        let current = currentFrame.standardized
        let size = CGSize(width: max(0, panelSize.width), height: max(0, panelSize.height))
        let originY: CGFloat

        switch placementSide {
        case .below:
            originY = current.maxY - size.height
        case .above:
            originY = current.minY
        }

        let resized = CGRect(
            x: current.midX - size.width / 2,
            y: originY,
            width: size.width,
            height: size.height
        )
        guard let visibleFrame = bestVisibleFrame(for: current, among: visibleFrames) else {
            return resized
        }
        return fit(resized, in: visibleFrame, margin: margin)
    }

    private static func bestVisibleFrame(for frame: CGRect, among visibleFrames: [CGRect]) -> CGRect? {
        let candidates = visibleFrames
            .map(\.standardized)
            .filter { $0.width > 0 && $0.height > 0 }
        guard var best = candidates.first else { return nil }

        var bestIntersectionArea = intersectionArea(frame, best)
        var bestDistance = squaredDistance(from: frame.center, to: best)

        for candidate in candidates.dropFirst() {
            let intersectionArea = intersectionArea(frame, candidate)
            let distance = squaredDistance(from: frame.center, to: candidate)
            if intersectionArea > bestIntersectionArea
                || (intersectionArea == bestIntersectionArea && distance < bestDistance) {
                best = candidate
                bestIntersectionArea = intersectionArea
                bestDistance = distance
            }
        }
        return best
    }

    private static func intersectionArea(_ first: CGRect, _ second: CGRect) -> CGFloat {
        let intersection = first.standardized.intersection(second.standardized)
        guard !intersection.isNull else { return 0 }
        return max(0, intersection.width) * max(0, intersection.height)
    }

    private static func squaredDistance(from point: CGPoint, to frame: CGRect) -> CGFloat {
        let dx = max(frame.minX - point.x, 0, point.x - frame.maxX)
        let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
        return dx * dx + dy * dy
    }

    private static func usableFrame(from visibleFrame: CGRect, margin: CGFloat) -> CGRect {
        let frame = visibleFrame.standardized
        let safeMargin = max(0, margin)
        let horizontalInset = min(safeMargin, frame.width / 2)
        let verticalInset = min(safeMargin, frame.height / 2)
        return frame.insetBy(dx: horizontalInset, dy: verticalInset)
    }
}

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}
