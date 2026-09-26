import CoreGraphics
import Foundation

nonisolated public struct ImageStitchUpdate: Sendable {
    public enum Status: Sendable, Equatable { case started, appended, unchanged, unmatched }
    public let status: Status
    /// 当前帧坐标加上 offset 后，得到输出画布中的坐标。
    public let offset: CGFloat
    public let alignment: ImageAlignment?
    public let stripCount: Int
    public let imageSpan: Int
}

nonisolated public enum ImageStitchError: Error, LocalizedError, Sendable {
    case invalidRegion
    case storageLimitOrEncodingFailure

    public var errorDescription: String? {
        switch self {
        case .invalidRegion: "拼接区域无效或没有有效像素"
        case .storageLimitOrEncodingFailure: "条带超过存储预算或无法编码；已有拼图保持不变"
        }
    }
}

/// 通用纵向截图拼接，不运行 OCR，不判断聊天页，不限制为 10 个条带。
/// 每个实例由一个顺序生产者使用；不同页面/批次由调用方 reset。
public actor ImageStitcher {
    private struct Last {
        let bitmap: FrameBitmap
        let region: ImageStitchRegion
        let offset: CGFloat
        let delta: CGFloat
    }

    private let limits: SeeUImageLimits
    private let maximumStoredBytes: Int
    private var canvas: ImageStripCanvas?
    private var last: Last?
    private var sequence = 0

    /// 预算只统计保存的无损条带；处理和导出另需临时位图内存。
    public init(limits: SeeUImageLimits = .init(), maximumStoredBytes: Int = 128 * 1024 * 1024) {
        self.limits = limits
        self.maximumStoredBytes = max(1, maximumStoredBytes)
    }

    public func reset() {
        canvas = nil
        last = nil
        sequence = 0
    }

    /// region 缺省为整图。固定顶底栏、浮窗等可由宿主提供几何裁剪/排除区域。
    /// 匹配失败返回 unmatched，保持已有画布和参考帧，绝不把未知位置强行追加。
    public func ingest(_ imageData: Data, region: ImageStitchRegion = .init()) throws -> ImageStitchUpdate {
        let bitmap = try FrameBitmap(imageData: imageData, limits: limits)
        let rect = region.bounds(in: bitmap)
        guard !rect.isNull, !rect.isEmpty else { throw ImageStitchError.invalidRegion }
        let alignment = last.map {
            ImageAligner.align(previous: $0.bitmap, current: bitmap,
                               previousRegion: $0.region, currentRegion: region, hint: $0.delta)
        }
        if let alignment, alignment.status == .unmatched {
            return ImageStitchUpdate(status: .unmatched, offset: last?.offset ?? 0, alignment: alignment,
                                     stripCount: canvas?.count ?? 0, imageSpan: canvas?.span ?? 0)
        }
        let delta = alignment?.offset ?? 0
        let offset = (last?.offset ?? 0) + delta
        let target = canvas ?? ImageStripCanvas(width: bitmap.width)
        guard target.add(bitmap: bitmap, rect: rect, offset: offset, exclusions: region.exclusions,
                         capturedAt: Date(timeIntervalSinceReferenceDate: Double(sequence)),
                         maxStoredBytes: maximumStoredBytes, seamRange: alignment?.matchingRange) else {
            throw ImageStitchError.storageLimitOrEncodingFailure
        }
        let status: ImageStitchUpdate.Status = last == nil ? .started
            : (alignment?.status == .unchanged ? .unchanged : .appended)
        canvas = target
        last = Last(bitmap: bitmap, region: region, offset: offset, delta: delta)
        sequence += 1
        return ImageStitchUpdate(status: status, offset: offset, alignment: alignment,
                                 stripCount: target.count, imageSpan: target.span)
    }

    /// 无损输出；超过高度或 2400 万像素预算时等比缩小。背景可能在接缝处跳变。
    public func renderPNG(maxPixelHeight: Int = 16_000) -> Data? {
        guard let image = canvas?.render(maxPixelHeight: maxPixelHeight) else { return nil }
        return FrameBitmap.encodePNG(image)
    }

    /// 只在最终导出编码一次 JPEG。
    public func renderJPEG(maxPixelHeight: Int = 16_000, quality: Double = 0.92) -> Data? {
        guard quality.isFinite, let image = canvas?.render(maxPixelHeight: maxPixelHeight) else { return nil }
        return FrameBitmap.encodeJPEG(image, quality: min(1, max(0, quality)))
    }
}
