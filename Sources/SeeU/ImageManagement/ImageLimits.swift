import Foundation

/// 限制编码大小和解码像素量；不自动缩小图片，避免悄悄丢失文字。
nonisolated public struct SeeUImageLimits: Sendable {
    public let maximumEncodedBytes: Int
    public let maximumPixels: Int
    public let maximumDimension: Int

    public init(maximumEncodedBytes: Int = 20 * 1024 * 1024,
                maximumPixels: Int = 8_000_000, maximumDimension: Int = 16_000) {
        self.maximumEncodedBytes = max(1, maximumEncodedBytes)
        self.maximumPixels = max(1, min(maximumPixels, Int.max / 4))
        self.maximumDimension = max(1, maximumDimension)
    }
}

nonisolated public enum SeeUImageError: Error, LocalizedError, Sendable {
    case encodedSizeExceeded
    case pixelBudgetExceeded
    case invalidImage
    case unsupportedOrientation

    public var errorDescription: String? {
        switch self {
        case .encodedSizeExceeded: "图片文件超过 SeeU 大小限制"
        case .pixelBudgetExceeded: "图片尺寸超过 SeeU 像素预算，请按屏幕拆分后顺序输入"
        case .invalidImage: "图片格式无效或无法解码"
        case .unsupportedOrientation: "请先将图片方向归一化为直立方向"
        }
    }
}
