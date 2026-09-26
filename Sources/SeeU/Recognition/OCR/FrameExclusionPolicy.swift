import CoreGraphics
import Foundation

/// 宿主过滤 OCR 行并提供遮挡几何；所有坐标均为原图像素、左上原点。
nonisolated public struct FrameExclusion: Sendable {
    public let lines: [OCRLine]
    public let keyboardTop: CGFloat?
    public let occluders: [CGRect]

    public init(lines: [OCRLine], keyboardTop: CGFloat? = nil, occluders: [CGRect] = []) {
        self.lines = lines
        self.keyboardTop = keyboardTop
        self.occluders = occluders
    }
}

nonisolated public struct FrameExclusionPolicy: Sendable {
    let filter: @Sendable ([OCRLine], CGSize) -> FrameExclusion

    public init(_ filter: @escaping @Sendable ([OCRLine], CGSize) -> FrameExclusion) {
        self.filter = filter
    }

    public static let none = FrameExclusionPolicy { lines, _ in FrameExclusion(lines: lines) }
}
