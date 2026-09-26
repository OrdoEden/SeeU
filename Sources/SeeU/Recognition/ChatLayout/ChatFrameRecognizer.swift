import CoreGraphics
import Foundation

/// 单屏识别仅负责像素和版式，不等待跨屏对齐、长图编码或业务分析。
nonisolated final class ChatFrameRecognizer: Sendable {
    private let ocr = VisionOCRService()

    func recognize(jpeg: Data, frameID: UUID, capturedAt: Date, anchors: LayoutAnchors,
                   currentTitle: String?, exclusion: FrameExclusionPolicy, limits: SeeUImageLimits) async throws -> RecognizedChatFrame {
        let bitmap = try FrameBitmap(imageData: jpeg, limits: limits)
        let started = Date()
        let rawLines = try await ocr.recognize(bitmap.image)
        let filtered = exclusion.filter(rawLines, bitmap.size)
        let lines = filtered.lines, keyboardTop = filtered.keyboardTop, occluders = filtered.occluders
        let parser = ChatLayoutParser()
        var parsed = parser.parse(lines: lines, bitmap: bitmap, frameID: frameID, capturedAt: capturedAt,
                                  anchors: anchors, excludedKeyboardTop: keyboardTop, occluders: occluders)
        if let title = parsed.title, let currentTitle,
           !ChatLayoutParser.isTransientTitle(title),
           TextMatch.similarity(TextMatch.normalize(title), TextMatch.normalize(currentTitle)) < 0.6 {
            parsed = parser.parse(lines: lines, bitmap: bitmap, frameID: frameID, capturedAt: capturedAt,
                                  anchors: LayoutAnchors(), excludedKeyboardTop: keyboardTop, occluders: occluders)
        }
        return RecognizedChatFrame(bitmap: bitmap, parsed: parsed,
                                   ocrMilliseconds: Int(Date().timeIntervalSince(started) * 1000))
    }

}
