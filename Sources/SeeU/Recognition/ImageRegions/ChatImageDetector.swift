import CoreGraphics
import Foundation
import Vision

/// 内置聊天图片检测：先找两侧头像列，再把"头像旁没有文字气泡"的消息当作图片消息，
/// 按尺寸分为表情包（sticker）或照片（photo）。只依赖版式与像素，不认人脸、不分业务。
///
/// 局限：依赖头像可见；红包、转账、名片等无 OCR 文字的卡片也可能被当成图片消息。
nonisolated public struct SeeUChatImageDetector: SeeUImageDetector {
    /// 表情包最长边上限（相对帧宽）；超过视为照片。
    public var stickerMaximumWidthRatio: CGFloat

    public init(stickerMaximumWidthRatio: CGFloat = 0.42) {
        self.stickerMaximumWidthRatio = stickerMaximumWidthRatio
    }

    public var kinds: Set<SeeUImageKind> { [.avatar, .sticker, .photo] }

    struct Avatar: Equatable {
        let rect: CGRect
        let side: BubbleSide
        let alignedBubbleIndex: Int?
    }

    public func detect(in frame: SeeUImageFrame) -> [SeeUImageCandidate] {
        guard frame.image.width >= 160, frame.parsed.contentBottom > frame.parsed.contentTop else { return [] }
        let avatars = findAvatars(in: frame)
        var results = avatars.map {
            SeeUImageCandidate(kind: .avatar, rect: $0.rect, side: $0.side, alignedBubbleIndex: $0.alignedBubbleIndex)
        }
        for avatar in avatars where avatar.alignedBubbleIndex == nil {
            guard let rect = imageMessageRect(beside: avatar, avatars: avatars, in: frame) else { continue }
            let kind: SeeUImageKind = max(rect.width, rect.height) <= frame.pixelSize.width * stickerMaximumWidthRatio
                ? .sticker : .photo
            results.append(SeeUImageCandidate(kind: kind, rect: rect, side: avatar.side))
        }
        return results
    }

    // MARK: - 头像列

    /// 头像几何：近似正方形、宽约为帧宽 6%–14%、贴近对应一侧边缘。
    static func isAvatarShaped(_ rect: CGRect, imageWidth width: CGFloat, side: BubbleSide) -> Bool {
        guard rect.height > 0, width > 0, rect.width >= 16, rect.height >= 16,
              (0.8...1.2).contains(rect.width / rect.height),
              (0.06...0.14).contains(rect.width / width) else { return false }
        switch side {
        case .other: return (0.008...0.065).contains(rect.minX / width) && rect.maxX <= width * 0.165
        case .me: return (0.008...0.065).contains((width - rect.maxX) / width) && rect.minX >= width * 0.835
        case .unknown: return false
        }
    }

    func findAvatars(in frame: SeeUImageFrame) -> [Avatar] {
        let image = frame.image, parsed = frame.parsed
        let width = CGFloat(image.width)
        let stripWidth = (width * 0.17).rounded(.up)
        let top = max(0, Int(parsed.contentTop)), bottom = min(image.height, Int(parsed.contentBottom.rounded(.up)))
        // 分块：细长条整体送 Vision 时小方块容易漏检。
        let tileHeight = max(Int(width * 0.2), Int(width))
        let overlap = Int(width * 0.2)
        var found: [Avatar] = []
        for side in [BubbleSide.other, .me] {
            let stripX = side == .other ? 0 : width - stripWidth
            var tileTop = top
            while tileTop < bottom {
                let height = min(tileHeight, bottom - tileTop)
                defer { tileTop += max(1, tileHeight - overlap) }
                guard height >= Int(width * 0.06),
                      let tile = image.cropping(to: CGRect(x: stripX, y: CGFloat(tileTop),
                                                           width: stripWidth, height: CGFloat(height))) else { continue }
                for box in Self.rectangles(in: tile) {
                    // Vision 坐标为本条带归一化、左下原点。
                    let rect = CGRect(x: stripX + box.minX * CGFloat(tile.width),
                                      y: CGFloat(tileTop) + (1 - box.maxY) * CGFloat(tile.height),
                                      width: box.width * CGFloat(tile.width),
                                      height: box.height * CGFloat(tile.height)).integral
                    guard Self.isAvatarShaped(rect, imageWidth: width, side: side),
                          rect.minY >= parsed.contentTop - 1, rect.maxY <= parsed.contentBottom + 1,
                          !parsed.occluders.contains(where: { $0.intersects(rect) }),
                          !found.contains(where: { $0.side == side && abs($0.rect.midY - rect.midY) < rect.height * 0.5 }),
                          let crop = image.cropping(to: rect), let pixels = ImagePatch.sample(crop),
                          ImagePatch.hasTexture(pixels) else { continue }
                    found.append(Avatar(rect: rect, side: side,
                                        alignedBubbleIndex: Self.alignedBubble(for: rect, side: side, in: parsed)))
                }
                if tileTop + height >= bottom { break }
            }
        }
        return found.sorted { $0.rect.minY < $1.rect.minY }
    }

    private static func rectangles(in tile: CGImage) -> [CGRect] {
        let request = VNDetectRectanglesRequest()
        request.minimumAspectRatio = 0.8
        request.maximumAspectRatio = 1
        request.minimumSize = 0.3
        request.minimumConfidence = 0.65
        request.quadratureTolerance = 15
        request.maximumObservations = 16
        guard (try? VNImageRequestHandler(cgImage: tile, options: [:]).perform([request])) != nil else { return [] }
        return (request.results ?? []).map(\.boundingBox)
    }

    /// 与头像同一行开始的文字气泡（群聊昵称会让气泡略低于头像顶部）。
    static func alignedBubble(for avatar: CGRect, side: BubbleSide, in parsed: ParsedChatFrame) -> Int? {
        parsed.bubbles.indices.first { index in
            let bubble = parsed.bubbles[index]
            return bubble.kind == .message && (bubble.side == side || bubble.side == .unknown)
                && bubble.rect.minY >= avatar.minY - avatar.height * 0.3
                && bubble.rect.minY <= avatar.minY + avatar.height * 0.9
        }
    }

    // MARK: - 图片消息

    /// 在头像旁的横向区间内，按行占用找出第一段足够高的非底色内容（跳过群聊昵称这类细行）。
    func imageMessageRect(beside avatar: Avatar, avatars: [Avatar], in frame: SeeUImageFrame) -> CGRect? {
        guard let background = frame.backgroundColor else { return nil }
        let parsed = frame.parsed
        let width = frame.pixelSize.width
        let minSide = width * 0.1
        let xRange: ClosedRange<CGFloat> = avatar.side == .other
            ? (avatar.rect.maxX + width * 0.01)...(width * 0.86)
            : (width * 0.14)...(avatar.rect.minX - width * 0.01)
        let bandTop = max(parsed.contentTop, avatar.rect.minY - avatar.rect.height * 0.1)
        let nextTops = avatars.map(\.rect.minY).filter { $0 > avatar.rect.maxY }
            + parsed.bubbles.map(\.rect.minY).filter { $0 > avatar.rect.minY + avatar.rect.height * 0.2 }
        let bandBottom = min(parsed.contentBottom, (nextTops.min() ?? parsed.contentBottom) - 2)
        guard xRange.upperBound - xRange.lowerBound > minSide, bandBottom - bandTop > minSide else { return nil }

        let step = 2
        func differs(_ x: Int, _ y: Int) -> Bool {
            let c = frame.color(x: x, y: y)
            return max(abs(c.red - background.red), abs(c.green - background.green), abs(c.blue - background.blue)) > 0.1
        }
        let x0 = Int(xRange.lowerBound), x1 = Int(xRange.upperBound)
        let columns = Array(stride(from: x0, to: x1, by: step))
        let minimumHits = max(2, columns.count / 50)
        var runs: [ClosedRange<Int>] = []
        var runStart: Int?, lastHit = -1
        for y in stride(from: Int(bandTop), to: Int(bandBottom), by: step) {
            let hits = columns.reduce(0) { $0 + (differs($1, y) ? 1 : 0) }
            if hits >= minimumHits {
                if runStart == nil || y - lastHit > step * 3 {
                    if let start = runStart { runs.append(start...lastHit) }
                    runStart = y
                }
                lastHit = y
            }
        }
        if let start = runStart { runs.append(start...lastHit) }
        guard let run = runs.first(where: { CGFloat($0.upperBound - $0.lowerBound) >= minSide }) else { return nil }
        // 触到下边界说明图片被截断，等完整出现再提取。
        guard CGFloat(run.upperBound) < bandBottom - CGFloat(step * 2) || bandBottom < parsed.contentBottom - 2,
              CGFloat(run.lowerBound) <= avatar.rect.minY + avatar.rect.height * 0.8 else { return nil }

        var minX = Int.max, maxX = Int.min, hitCount = 0, sampleCount = 0
        for y in stride(from: run.lowerBound, through: run.upperBound, by: step) {
            for x in columns {
                sampleCount += 1
                if differs(x, y) {
                    hitCount += 1
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                }
            }
        }
        guard minX < maxX else { return nil }
        let rect = CGRect(x: minX, y: run.lowerBound, width: maxX - minX + step,
                          height: run.upperBound - run.lowerBound + step)
        guard rect.width >= minSide, rect.width <= width * 0.7, rect.height <= width * 1.2,
              Double(hitCount) / Double(max(1, sampleCount)) > 0.08,
              !parsed.occluders.contains(where: { $0.intersects(rect) }) else { return nil }
        return rect
    }
}
