import CoreGraphics
import Foundation

/// 一行 OCR 文字。`rect` 是帧像素坐标，原点在左上角（已从 Vision 的左下归一化坐标换算）。
nonisolated public struct OCRLine: Sendable, Equatable {
    public let text: String
    public let rect: CGRect
    public let confidence: Float

    public init(text: String, rect: CGRect, confidence: Float) {
        self.text = text
        self.rect = rect
        self.confidence = confidence
    }
}
