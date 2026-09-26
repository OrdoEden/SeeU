import CoreGraphics
import Foundation

/// 按会话累积的版式知识：标题栏高度、两侧气泡边缘、两侧气泡颜色。
///
/// 只从几何上高置信（明显靠左/靠右）的气泡学习，再用来判断宽气泡（左右留白差不多）的发言方。
/// 学到的气泡颜色比“气泡 vs 页面背景”可靠得多：聊天背景可能是照片壁纸。
nonisolated struct LayoutAnchors: Sendable {
    private(set) var otherLeft: [CGFloat] = []
    private(set) var meRight: [CGFloat] = []
    private(set) var contentTops: [CGFloat] = []
    private(set) var meColors: [RGB] = []
    private(set) var otherColors: [RGB] = []
    private(set) var bodyHeights: [CGFloat] = []

    mutating func record(_ frame: ParsedChatFrame) {
        if frame.titleAnchored { Self.push(&contentTops, frame.contentTop) }
        // 正文行高：只统计确实分出了左右的消息，避免把图片里的小字当成正文。
        let strong = frame.bubbles.filter {
            $0.kind == .message && $0.sideConfidence >= 0.8 && !$0.clipped
        }
        if strong.count >= 2, frame.bodyLineHeight > 0 { Self.push(&bodyHeights, frame.bodyLineHeight) }
        for bubble in frame.bubbles where bubble.kind == .message && !bubble.clipped && bubble.sideConfidence >= 0.9 {
            switch bubble.side {
            case .other:
                Self.push(&otherLeft, bubble.rect.minX)
                if let color = bubble.color { Self.push(&otherColors, color) }
            case .me:
                Self.push(&meRight, bubble.rect.maxX)
                if let color = bubble.color { Self.push(&meColors, color) }
            case .unknown:
                break
            }
        }
    }

    var otherLeftMedian: CGFloat? { Self.median(otherLeft, minimum: 3) }
    var meRightMedian: CGFloat? { Self.median(meRight, minimum: 3) }
    var contentTopMedian: CGFloat? { Self.median(contentTops, minimum: 1) }
    /// 本会话学到的正文字高；学到之前由单帧的分位估算兜底。
    var bodyHeight: CGFloat? { Self.median(bodyHeights, minimum: 2) }
    var meColor: RGB? { Self.median(meColors) }
    var otherColor: RGB? { Self.median(otherColors) }

    private static func push<T>(_ list: inout [T], _ value: T) {
        list.append(value)
        if list.count > 30 { list.removeFirst(list.count - 30) }
    }

    private static func median(_ list: [CGFloat], minimum: Int) -> CGFloat? {
        guard list.count >= minimum else { return nil }
        let sorted = list.sorted()
        return sorted[sorted.count / 2]
    }

    private static func median(_ list: [RGB]) -> RGB? {
        guard list.count >= 2 else { return nil }
        func mid(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        return RGB(r: mid(list.map(\.r)), g: mid(list.map(\.g)), b: mid(list.map(\.b)))
    }
}
