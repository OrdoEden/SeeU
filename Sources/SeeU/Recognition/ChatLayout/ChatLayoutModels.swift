import CoreGraphics
import Foundation

nonisolated struct RecognizedChatFrame: Sendable {
    let bitmap: FrameBitmap
    public let parsed: ParsedChatFrame
    public let ocrMilliseconds: Int
}

/// 气泡的发言方判断。和 `Speaker` 分开，是因为 OCR 层还要带置信度。
nonisolated public enum BubbleSide: String, Sendable, Codable {
    case me
    case other
    case unknown
}

/// 对话列表里的条目类型。时间分隔线也保留：它是跨帧对齐的锚点，也是后续分析的时间上下文。
nonisolated public enum BubbleKind: String, Sendable, Codable {
    case message
    case time
    /// 不是识别出来的内容，而是“这里有一段没截到的聊天记录”的占位。
    case gap
}

/// 一帧里解析出的一个聊天气泡（一条或多条相邻 OCR 行），或一条时间分隔线。
nonisolated public struct ChatBubble: Sendable {
    public let kind: BubbleKind
    public let text: String
    /// 文字外接框（帧像素）。气泡背景比它略大。
    public let rect: CGRect
    public let side: BubbleSide
    public let sideConfidence: Double
    /// 贴着内容区上/下边缘，可能只露出一部分，文字不完整。
    public let clippedTop: Bool
    public let clippedBottom: Bool
    /// 群聊气泡上方的昵称，单聊为 nil。
    public let senderName: String?
    /// 气泡下方的引用块（微信“引用回复”），例如 “Gidon：不对，今晚…”。
    public let quote: String?
    /// 气泡背景色（文字框外侧取样），用于学习本会话两侧气泡的颜色。
    let color: RGB?
    var recognitionConfidence: Float? = nil

    public var clipped: Bool { clippedTop || clippedBottom }
}

/// 一帧的版式解析结果。
nonisolated public struct ParsedChatFrame: Sendable {
    public let frameID: UUID
    public let capturedAt: Date
    public let pixelSize: CGSize
    /// 0...1，越高越像聊天页。
    public let chatScore: Double
    public let isChat: Bool
    public let title: String?
    /// 标题是本帧识别到的（而不是沿用本会话学到的标题栏位置）。
    public let titleAnchored: Bool
    /// 聊天内容区在帧中的纵向范围（排除标题栏、输入栏、键盘）。
    public let contentTop: CGFloat
    public let contentBottom: CGFloat
    /// 长截图标题栏的截取高度：紧贴标题下方，宁短勿长，避免带进聊天内容。
    public let headerBottom: CGFloat
    /// 从上到下排序，包括时间分隔线。
    public let bubbles: [ChatBubble]
    public let keyboardVisible: Bool
    public let inputBarVisible: Bool
    /// 本帧测到的正文字高，用来过滤图片里的小字，也用于学习本会话的稳定字高。
    public let bodyLineHeight: CGFloat
    /// 宿主 自己的界面（画中画）在帧里占掉的区域，压住的气泡按“显示不完整”处理。
    public let occluders: [CGRect]
    /// 不是聊天页时的原因，只用于状态展示，不含聊天内容。
    public let rejectReason: String?

    public var messageBubbles: [ChatBubble] { bubbles.filter { $0.kind == .message } }

    /// 单张截图足够清楚即可分析；无标题时需要更强的版式或输入栏证据。
    public var hasReliableSingleFrameEvidence: Bool {
        guard isChat else { return false }
        // 裁切表示内容可能不完整，不代表无法识别聊天身份；业务仍保留此质量标记。
        let complete = messageBubbles.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.sideConfidence >= 0.8 }
        guard !complete.isEmpty else { return false }
        if titleAnchored, !ChatLayoutParser.isTransientTitle(title), chatScore >= 0.64 { return true }
        if complete.count >= 2, chatScore >= 0.75 { return true }
        if complete.count >= 2, (keyboardVisible || inputBarVisible), chatScore >= 0.68 {
            return true
        }
        return false
    }

    /// 一条消息都没有，但确实是同一个聊天页（整屏都是图片时会出现）。
    /// 不能当成“不是聊天页”，否则会把会话切断。
    func continuingChat(reason: String) -> ParsedChatFrame {
        ParsedChatFrame(
            frameID: frameID, capturedAt: capturedAt, pixelSize: pixelSize, chatScore: chatScore, isChat: true,
            title: title, titleAnchored: titleAnchored, contentTop: contentTop, contentBottom: contentBottom,
            headerBottom: headerBottom, bubbles: bubbles, keyboardVisible: keyboardVisible, inputBarVisible: inputBarVisible,
            bodyLineHeight: bodyLineHeight, occluders: occluders, rejectReason: reason
        )
    }

    /// 帧里有没有被 宿主 界面压住的行（判断能否放宽跨帧对齐的冲突阈值）。
    public var hasOcclusion: Bool { !occluders.isEmpty }
}

/// OCR 观察证据。observedAt 是截图时间，不是消息发送时间。
/// 坐标为原图像素、左上原点；每条历史消息仅保留最近三次证据。
nonisolated public struct SeeUObservation: Codable, Sendable, Equatable {
    public let frameID: UUID
    public let observedAt: Date
    public let pixelWidth: Double
    public let pixelHeight: Double
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public let recognitionConfidence: Float?

    init(frame: ParsedChatFrame, bubble: ChatBubble) {
        frameID = frame.frameID
        observedAt = frame.capturedAt
        pixelWidth = Double(frame.pixelSize.width)
        pixelHeight = Double(frame.pixelSize.height)
        x = Double(bubble.rect.minX)
        y = Double(bubble.rect.minY)
        width = Double(bubble.rect.width)
        height = Double(bubble.rect.height)
        recognitionConfidence = bubble.recognitionConfidence
    }
}
