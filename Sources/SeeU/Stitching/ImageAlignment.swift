import CoreGraphics
import Foundation

/// 原图像素坐标中的有效区域；排除区可用于固定工具栏或临时遮挡。
nonisolated public struct ImageStitchRegion: Sendable {
    public let rect: CGRect?
    public let exclusions: [CGRect]

    public init(rect: CGRect? = nil, exclusions: [CGRect] = []) {
        self.rect = rect
        self.exclusions = exclusions
    }

    func bounds(in bitmap: FrameBitmap) -> CGRect {
        guard exclusions.count <= 128, exclusions.allSatisfy({
            $0.origin.x.isFinite && $0.origin.y.isFinite && $0.size.width.isFinite && $0.size.height.isFinite &&
            $0.size.width >= 0 && $0.size.height >= 0
        }) else { return .null }
        let image = CGRect(origin: .zero, size: bitmap.size)
        guard let rect else { return image }
        guard Self.valid(rect) else { return .null }
        return rect.intersection(image)
    }

    private static func valid(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite &&
        rect.size.width.isFinite && rect.size.height.isFinite && rect.size.width > 0 && rect.size.height > 0
    }

    fileprivate func contains(_ point: CGPoint, bounds: CGRect) -> Bool {
        bounds.contains(point) && !exclusions.contains { Self.valid($0) && $0.contains(point) }
    }
}

nonisolated public struct ImageAlignment: Sendable {
    public enum Status: Sendable, Equatable { case matched, unchanged, unmatched }
    public let status: Status
    /// 当前图 y + offset = 上一图 y。评分仅用于比较，不是成功概率。
    public let offset: CGFloat
    public let score: Double
    public let matchedRegions: Int
    public let reason: String?
    /// 当前帧中支持最终位移的局部区域中心范围，可约束自动接缝。
    public let matchingRange: ClosedRange<CGFloat>?
}

/// 仅处理同宽截图的纵向平移，不依赖 OCR、会话或条带保留策略。
nonisolated enum ImageAligner {
    private struct PointSample {
        let dy: Int
        let value: Double
        let column: Int
    }

    private struct Vote {
        let offset: Int
        let y: Int
        let error: Double
    }

    static func align(previous: FrameBitmap, current: FrameBitmap,
                      previousRegion: ImageStitchRegion, currentRegion: ImageStitchRegion,
                      hint: CGFloat? = nil) -> ImageAlignment {
        func unmatched(_ reason: String) -> ImageAlignment {
            ImageAlignment(status: .unmatched, offset: 0, score: 0, matchedRegions: 0, reason: reason, matchingRange: nil)
        }
        guard previous.width == current.width else { return unmatched("differentWidths") }
        let a = previousRegion.bounds(in: previous), b = currentRegion.bounds(in: current)
        guard !a.isNull, !b.isNull, !a.isEmpty, !b.isEmpty else { return unmatched("emptyRegion") }
        let left = Int(ceil(max(a.minX, b.minX))), right = Int(floor(min(a.maxX, b.maxX)))
        let radius = max(4, min(32, Int((Double(current.width) * 0.022).rounded())))
        guard right - left > radius * 2 + 1, min(a.height, b.height) > CGFloat(radius * 2 + 1)
        else { return unmatched("regionTooSmall") }

        // 静止与无法匹配是不同结果；壁纸静止而消息变化不能走 unchanged。
        let common = a.intersection(b)
        var sameCount = 0, changedCount = 0
        var sameError = 0.0
        if !common.isNull, !common.isEmpty {
            for row in 0..<80 {
                for col in 0..<32 {
                    let x = Int(common.minX + (CGFloat(col) + 0.5) * common.width / 32)
                    let y = Int(common.minY + (CGFloat(row) + 0.5) * common.height / 80)
                    let point = CGPoint(x: x, y: y)
                    guard previousRegion.contains(point, bounds: a), currentRegion.contains(point, bounds: b) else { continue }
                    let p = previous.color(x: x, y: y), c = current.color(x: x, y: y)
                    let error = (abs(p.r - c.r) + abs(p.g - c.g) + abs(p.b - c.b)) / 3
                    sameCount += 1
                    sameError += error
                    if error > 12 { changedCount += 1 }
                }
            }
        }
        if a == b, sameCount >= 128, sameError / Double(sameCount) <= 2,
           Double(changedCount) / Double(sameCount) < 0.004 {
            return ImageAlignment(status: .unchanged, offset: 0, score: 1,
                                  matchedRegions: sameCount, reason: nil, matchingRange: nil)
        }

        let xs = positions(from: left + radius, through: right - radius - 1, count: 10)
        let ys = positions(from: Int(ceil(b.minY)) + radius,
                           through: Int(floor(b.maxY)) - radius - 1, count: 48)
        let grid = positions(from: -radius, through: radius, count: 5)
        let columns = Array(Set(xs.flatMap { x in grid.map { x + $0 } })).sorted()
        let columnIndices = Dictionary(uniqueKeysWithValues: columns.enumerated().map { ($0.element, $0.offset) })
        // 至多 50 列，不复制全尺寸位图；候选纵坐标保持原分辨率，避免量化误差。
        var luminance = [Double](repeating: 0, count: columns.count * previous.height)
        for (index, x) in columns.enumerated() {
            for y in 0..<previous.height {
                luminance[index * previous.height + y] = previousRegion.contains(CGPoint(x: x, y: y), bounds: a)
                    ? previous.luma(x: x, y: y) : .nan
            }
        }
        let minY = Int(ceil(a.minY)) + radius, maxY = Int(floor(a.maxY)) - radius - 1
        guard minY <= maxY, !xs.isEmpty, !ys.isEmpty else { return unmatched("regionTooSmall") }
        var votes: [Vote] = []
        for y in ys {
            for x in xs {
                var samples: [PointSample] = []
                for dy in grid {
                    for dx in grid {
                        let px = x + dx, py = y + dy, point = CGPoint(x: px, y: py)
                        guard currentRegion.contains(point, bounds: b),
                              let column = columnIndices[px] else { continue }
                        let value = current.luma(x: px, y: py)
                        // 同位置未变的像素不能为非零位移投票，防止固定壁纸占多数。
                        if previousRegion.contains(point, bounds: a),
                           abs(value - luminance[column * previous.height + py]) <= 12 { continue }
                        samples.append(PointSample(dy: dy, value: value, column: column))
                    }
                }
                guard samples.count >= 8 else { continue }
                let mean = samples.reduce(0) { $0 + $1.value } / Double(samples.count)
                let variance = samples.reduce(0) { $0 + ($1.value - mean) * ($1.value - mean) } / Double(samples.count)
                guard variance >= 256 else { continue }
                var costs = [Double](repeating: 18, count: maxY - minY + 1)
                var bestY = minY, best = 18.0
                for candidate in minY...maxY {
                    var sum = 0.0
                    for sample in samples {
                        let py = candidate + sample.dy
                        let value = luminance[sample.column * previous.height + py]
                        guard value.isFinite else {
                            sum = Double(samples.count) * 18
                            break
                        }
                        sum += abs(sample.value - value)
                        if sum >= Double(samples.count) * 18 { break }
                    }
                    let error = sum / Double(samples.count)
                    costs[candidate - minY] = error
                    if error < best { best = error; bestY = candidate }
                }
                guard best < 8, bestY != y else { continue }
                var second = 18.0
                for candidate in minY...maxY where abs(candidate - bestY) > 3 {
                    second = min(second, costs[candidate - minY])
                }
                guard second > best * 1.5 + 2 else { continue }
                let offset = bestY - y
                // 用不同于搜索网格的密集采样重新验证，避免偶然命中的稀疏点。
                guard let error = verify(x: x, y: y, radius: radius, offset: offset,
                                         previous: previous, current: current,
                                         a: a, b: b, previousRegion: previousRegion, currentRegion: currentRegion),
                      error < 10 else { continue }
                votes.append(Vote(offset: offset, y: y, error: error))
            }
        }
        guard !votes.isEmpty else { return unmatched("insufficientMovingTexture") }
        let offsets = Set(votes.map(\.offset))
        let groups = offsets.map { offset in votes.filter { abs($0.offset - offset) <= 1 } }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                let l = lhs.reduce(0) { $0 + $1.error }, r = rhs.reduce(0) { $0 + $1.error }
                if l != r { return l < r }
                if let hint, hint.isFinite {
                    return abs(CGFloat(lhs[0].offset) - hint) < abs(CGFloat(rhs[0].offset) - hint)
                }
                return lhs[0].offset < rhs[0].offset
            }
        guard let best = groups.first, best.count >= 3 else { return unmatched("insufficientConsensus") }
        let ordered = best.map(\.offset).sorted(), offset = ordered[ordered.count / 2]
        let rows = best.map(\.y)
        guard Set(rows).count >= 2, (rows.max()! - rows.min()!) >= radius * 2 else {
            return unmatched("insufficientSpatialCoverage")
        }
        // 提示只影响搜索排序，不允许用滚动预测掩盖重复内容的歧义。
        if let rival = groups.first(where: { abs($0[0].offset - offset) > 3 }),
           Double(rival.count) >= Double(best.count) * 0.7 {
            return unmatched("ambiguousMotion")
        }
        let error = best.reduce(0) { $0 + $1.error } / Double(best.count)
        return ImageAlignment(status: .matched, offset: CGFloat(offset),
                              score: Double(best.count) / (1 + error), matchedRegions: best.count, reason: nil,
                              matchingRange: CGFloat(rows.min()!)...CGFloat(rows.max()!))
    }

    private static func positions(from start: Int, through end: Int, count: Int) -> [Int] {
        guard start <= end else { return [] }
        return Array(Set((0..<count).map { start + (end - start) * $0 / (count - 1) })).sorted()
    }

    private static func verify(x: Int, y: Int, radius: Int, offset: Int,
                               previous: FrameBitmap, current: FrameBitmap, a: CGRect, b: CGRect,
                               previousRegion: ImageStitchRegion, currentRegion: ImageStitchRegion) -> Double? {
        var count = 0, sum = 0.0
        for dy in positions(from: -radius, through: radius, count: 9) {
            for dx in positions(from: -radius, through: radius, count: 9) {
                let px = x + dx, py = y + dy, otherY = py + offset
                guard currentRegion.contains(CGPoint(x: px, y: py), bounds: b),
                      previousRegion.contains(CGPoint(x: px, y: otherY), bounds: a) else { continue }
                let c = current.color(x: px, y: py)
                if previousRegion.contains(CGPoint(x: px, y: py), bounds: a),
                   abs(c.luma - previous.luma(x: px, y: py)) <= 12 { continue }
                let p = previous.color(x: px, y: otherY)
                sum += (abs(c.r - p.r) + abs(c.g - p.g) + abs(c.b - p.b)) / 3
                count += 1
            }
        }
        return count >= 12 ? sum / Double(count) : nil
    }
}
