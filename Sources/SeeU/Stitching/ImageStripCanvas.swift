import CoreGraphics
import Foundation

/// 仅处理已定位图片的合成。坐标、排除区均为像素；不依赖 OCR、会话或保留张数。
nonisolated final class ImageStripCanvas {
    private struct Strip {
        let id: UUID
        let capturedAt: Date
        var order: Int
        var bounds: CGRect
        var valid: [CGRect]
        var protected: [CGRect]
        var seamRange: ClosedRange<CGFloat>?
        let png: Data
    }

    let width: Int
    private var strips: [Strip] = []
    private var nextOrder = 0
    // 保持坐标可精确转为 Int，且拒绝无实际截图意义的超大偏移。
    private static let coordinateLimit: CGFloat = 1_000_000_000

    init(width: Int) { self.width = width }

    var count: Int { strips.count }
    var storedByteCount: Int { strips.reduce(0) { $0 + $1.png.count } }
    var top: CGFloat? { strips.map { $0.bounds.minY }.min() }
    var bottom: CGFloat? { strips.map { $0.bounds.maxY }.max() }
    var span: Int {
        guard let top, let bottom else { return 0 }
        return Int(bottom - top)
    }

    /// exclusions / protectedRects 为输入图坐标；offset 只作用于纵轴。
    @discardableResult
    func add(bitmap: FrameBitmap, rect: CGRect, offset: CGFloat, exclusions: [CGRect] = [],
             protectedRects: [CGRect] = [], capturedAt: Date, maxStoredBytes: Int? = nil,
             seamRange: ClosedRange<CGFloat>? = nil) -> Bool {
        guard width > 0, bitmap.width == width, Self.safeCoordinate(offset), Self.safeRect(rect),
              exclusions.count <= 128, protectedRects.count <= 128,
              exclusions.allSatisfy(Self.safeRect), protectedRects.allSatisfy(Self.safeRect) else { return false }
        if let seamRange {
            guard Self.safeCoordinate(seamRange.lowerBound), Self.safeCoordinate(seamRange.upperBound),
                  Self.safeCoordinate(seamRange.lowerBound + offset.rounded()),
                  Self.safeCoordinate(seamRange.upperBound + offset.rounded()) else { return false }
        }
        let crop = rect.integral.intersection(CGRect(origin: .zero, size: bitmap.size))
        let shift = offset.rounded(), bounds = crop.offsetBy(dx: 0, dy: shift)
        guard !crop.isNull, !crop.isEmpty, Self.safeRect(bounds),
              let image = bitmap.image.cropping(to: crop), let png = FrameBitmap.encodePNG(image) else { return false }
        let masks = exclusions.filter(Self.safeRect).map { $0.integral.offsetBy(dx: 0, dy: shift) }
        let valid = Self.subtract([bounds], masks)
        guard !valid.isEmpty else { return false }
        // 静止帧替换同位置来源时沿用已经确认的支持区，避免失去定位约束后误选固定栏。
        let inheritedRange = strips.filter {
            $0.bounds == bounds && $0.capturedAt <= capturedAt && $0.seamRange != nil
        }.max(by: Self.older)?.seamRange
        let placementRange = seamRange.map { ($0.lowerBound + shift)...($0.upperBound + shift) } ?? inheritedRange
        let candidate = Strip(id: UUID(), capturedAt: capturedAt, order: nextOrder, bounds: bounds,
                            valid: valid, protected: protectedRects.filter(Self.safeRect).map {
                                $0.offsetBy(dx: 0, dy: shift)
                            }, seamRange: placementRange, png: png)
        let retained = Self.pruned(strips + [candidate])
        if let limit = maxStoredBytes {
            var remaining = limit
            for strip in retained {
                guard strip.png.count <= remaining else { return false }
                remaining -= strip.png.count
            }
        }
        strips = retained
        nextOrder += 1
        return true
    }

    func absorb(_ other: ImageStripCanvas, shift: CGFloat) {
        guard other !== self, other.width == width, Self.safeCoordinate(shift),
              other.strips.allSatisfy({ Self.safeRect($0.bounds.offsetBy(dx: 0, dy: shift.rounded())) }) else { return }
        let offset = shift.rounded(), existing = Set(strips.map(\.id))
        for var strip in other.strips.sorted(by: Self.older) where !existing.contains(strip.id) {
            strip.bounds = strip.bounds.offsetBy(dx: 0, dy: offset)
            strip.valid = strip.valid.map { $0.offsetBy(dx: 0, dy: offset) }
            strip.protected = strip.protected.map { $0.offsetBy(dx: 0, dy: offset) }
            strip.seamRange = strip.seamRange.map { ($0.lowerBound + offset)...($0.upperBound + offset) }
            strip.order = nextOrder
            nextOrder += 1
            strips.append(strip)
        }
        prune()
    }

    /// 保留策略由调用方显式指定。逐次移出两端较旧的来源。
    func trim(to capacity: Int) {
        let limit = max(0, capacity)
        while strips.count > limit {
            guard let upper = strips.min(by: { $0.bounds.minY < $1.bounds.minY }),
                  let lower = strips.max(by: { $0.bounds.maxY < $1.bounds.maxY }) else { break }
            let drop = Self.older(upper, lower) ? upper : lower
            strips.removeAll { $0.id == drop.id }
        }
    }

    private static func older(_ lhs: Strip, _ rhs: Strip) -> Bool {
        lhs.capturedAt == rhs.capturedAt ? lhs.order < rhs.order : lhs.capturedAt < rhs.capturedAt
    }

    private func prune() {
        strips = Self.pruned(strips)
    }

    private static func pruned(_ input: [Strip]) -> [Strip] {
        var retained = input
        for candidate in input.sorted(by: Self.older) {
            let newer = retained.filter { Self.older(candidate, $0) }.flatMap(\.valid)
            // 只有更新来源的有效像素能替代旧图；遮挡的矩形绝不能算覆盖。
            if Self.subtract(candidate.valid, newer).isEmpty {
                retained.removeAll { $0.id == candidate.id }
            }
        }
        return retained
    }

    func render(maxPixelHeight: Int, header: CGImage? = nil, footer: CGImage? = nil) -> CGImage? {
        guard width > 0, maxPixelHeight > 0, let top, let bottom else { return nil }
        let headerHeight = header.map { CGFloat($0.height) * CGFloat(width) / CGFloat($0.width) } ?? 0
        let footerHeight = footer.map { CGFloat($0.height) * CGFloat(width) / CGFloat($0.width) } ?? 0
        let fullHeight = headerHeight + bottom - top + footerHeight
        guard fullHeight.isFinite, fullHeight > 0 else { return nil }
        let pixelScale = (24_000_000 / (CGFloat(width) * fullHeight)).squareRoot()
        // 极窄长图输出宽度至少为 1；高度也必须服从像素预算，不能仅截断画布。
        let scale = min(1, CGFloat(maxPixelHeight) / fullHeight, pixelScale, 24_000_000 / fullHeight)
        let outWidth = max(1, Int(CGFloat(width) * scale))
        let outHeight = max(1, min(24_000_000 / outWidth, Int(fullHeight * scale)))
        guard let context = CGContext(data: nil, width: outWidth, height: outHeight, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = scale == 1 ? .none : .high
        // 未被任何有效来源覆盖的区域保持中性空缺。
        context.setFillColor(CGColor(gray: 0.93, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: outWidth, height: outHeight))

        func destination(_ rect: CGRect) -> CGRect {
            CGRect(x: rect.minX * scale, y: CGFloat(outHeight) - rect.maxY * scale,
                   width: rect.width * scale, height: rect.height * scale)
        }
        let bodyOrigin = headerHeight - top
        var painted: [CGRect] = []
        var previous: [Strip] = []
        for strip in strips.sorted(by: Self.older) {
            guard let image = FrameBitmap.decodeJPEG(strip.png) else { return nil }
            var primary = strip.bounds
            if let paintedBottom = painted.map(\.maxY).max(), strip.bounds.maxY > paintedBottom,
               let reference = previous.filter({
                   $0.bounds.minY <= strip.bounds.minY && $0.bounds.maxY > strip.bounds.minY
               }).max(by: { $0.bounds.maxY < $1.bounds.maxY }) {
                let seam = Self.seam(reference, strip, image: image)
                primary = CGRect(x: primary.minX, y: seam, width: primary.width, height: primary.maxY - seam)
            } else if let paintedTop = painted.map(\.minY).min(), strip.bounds.minY < paintedTop,
                      let reference = previous.filter({
                          $0.bounds.minY < strip.bounds.maxY && $0.bounds.maxY >= strip.bounds.maxY
                      }).min(by: { $0.bounds.minY < $1.bounds.minY }) {
                let seam = Self.seam(reference, strip, image: image)
                primary.size.height = seam - primary.minY
            }
            let primaryRects = strip.valid.map { $0.intersection(primary) }.filter { !$0.isNull && !$0.isEmpty }
            // 接缝之外如果旧图没有有效像素，仍用新图补齐；不留下人为裁切产生的洞。
            let uncovered = Self.subtract(strip.valid, painted)
            let drawRects = primaryRects + Self.subtract(uncovered, primaryRects)
            guard !drawRects.isEmpty else { continue }
            context.saveGState()
            context.clip(to: drawRects.map { destination($0.offsetBy(dx: 0, dy: bodyOrigin)) })
            context.draw(image, in: destination(strip.bounds.offsetBy(dx: 0, dy: bodyOrigin)))
            context.restoreGState()
            painted.append(contentsOf: drawRects)
            previous.append(strip)
        }
        if let header {
            context.draw(header, in: destination(CGRect(x: 0, y: 0, width: CGFloat(width), height: headerHeight)))
        }
        if let footer {
            context.draw(footer, in: destination(CGRect(x: 0, y: fullHeight - footerHeight,
                                                       width: CGFloat(width), height: footerHeight)))
        }
        return context.makeImage()
    }

    /// 像素一致性优先，边缘能量次之；文字框只在确有差异时轻微影响选缝。
    private static func seam(_ older: Strip, _ newer: Strip, image: CGImage) -> CGFloat {
        let overlap = older.bounds.intersection(newer.bounds)
        guard !overlap.isNull, overlap.height >= 4,
              let referenceImage = FrameBitmap.decodeJPEG(older.png),
              let a = try? FrameBitmap(image: referenceImage), let b = try? FrameBitmap(image: image)
        else { return newer.bounds.minY }
        let first = max(Int(overlap.minY) + 1, newer.seamRange.map { Int(ceil($0.lowerBound)) } ?? Int(overlap.minY) + 1)
        let last = min(Int(overlap.maxY) - 1, newer.seamRange.map { Int(floor($0.upperBound)) } ?? Int(overlap.maxY) - 1)
        guard first <= last else { return newer.bounds.minY }
        let stepX = max(1, Int(overlap.width) / 160)
        var bestY = (first + last) / 2, bestScore = Double.infinity
        func score(_ y: Int) -> Double {
            var difference = 0.0, edges = 0.0, samples = 0
            for x in stride(from: Int(overlap.minX), to: Int(overlap.maxX), by: stepX) {
                let point = CGPoint(x: x, y: y)
                guard older.valid.contains(where: { $0.contains(point) }),
                      newer.valid.contains(where: { $0.contains(point) }) else { continue }
                let ax = x - Int(older.bounds.minX), ay = y - Int(older.bounds.minY)
                let bx = x - Int(newer.bounds.minX), by = y - Int(newer.bounds.minY)
                difference += a.color(x: ax, y: ay).distance(to: b.color(x: bx, y: by)) / Double(3).squareRoot()
                edges += abs(a.luma(x: ax, y: ay + 1) - a.luma(x: ax, y: ay - 1))
                edges += abs(b.luma(x: bx, y: by + 1) - b.luma(x: bx, y: by - 1))
                samples += 1
            }
            guard samples >= max(1, Int(overlap.width) / stepX / 4) else { return .infinity }
            let mismatch = difference / Double(samples)
            let protected = (older.protected + newer.protected).contains { CGFloat(y) >= $0.minY && CGFloat(y) < $0.maxY }
            let middleBias = 0.01 * abs(Double(y - (first + last) / 2)) / Double(max(1, last - first))
            return mismatch + 0.12 * edges / Double(samples) + (protected && mismatch > 3 ? 4 : 0) + middleBias
        }
        // 大重叠先稀疏搜索，再在最佳行附近逐像素细化。
        let stepY = max(1, (last - first) / 180)
        for y in stride(from: first, through: last, by: stepY) {
            let value = score(y)
            if value < bestScore { bestScore = value; bestY = y }
        }
        for y in max(first, bestY - stepY)...min(last, bestY + stepY) {
            let value = score(y)
            if value < bestScore { bestScore = value; bestY = y }
        }
        return CGFloat(bestY)
    }

    private static func safeCoordinate(_ value: CGFloat) -> Bool {
        value.isFinite && abs(value) <= coordinateLimit
    }

    private static func safeRect(_ rect: CGRect) -> Bool {
        rect.size.width.isFinite && rect.size.height.isFinite && rect.size.width >= 0 && rect.size.height >= 0 &&
            safeCoordinate(rect.minX) && safeCoordinate(rect.minY) && safeCoordinate(rect.maxX) && safeCoordinate(rect.maxY)
    }

    /// 矩形差集用于排除遮挡、证明有效覆盖，以及填补接缝外的未覆盖区域。
    private static func subtract(_ rectangles: [CGRect], _ cutters: [CGRect]) -> [CGRect] {
        var result = rectangles
        for cutter in cutters {
            result = result.flatMap { rect -> [CGRect] in
                let cut = rect.intersection(cutter)
                guard !cut.isNull, !cut.isEmpty else { return [rect] }
                return [
                    CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: cut.minY - rect.minY),
                    CGRect(x: rect.minX, y: cut.maxY, width: rect.width, height: rect.maxY - cut.maxY),
                    CGRect(x: rect.minX, y: cut.minY, width: cut.minX - rect.minX, height: cut.height),
                    CGRect(x: cut.maxX, y: cut.minY, width: rect.maxX - cut.maxX, height: cut.height)
                ].filter { !$0.isEmpty }
            }
            if result.isEmpty { break }
        }
        return result
    }
}
