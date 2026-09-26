import CoreGraphics
import Foundation

/// 拼接后的一条消息，供主线程展示和分析。
nonisolated public struct LiveMessage: Sendable, Equatable {
    public let id: UUID
    public let kind: BubbleKind
    public let side: BubbleSide
    public let sideConfidence: Double
    public let text: String
    public let senderName: String?
    public let quote: String?
    public let observations: Int
    public let clipped: Bool
    public var sources: [SeeUObservation] = []
}

/// 一段拼接片段的摘要。
nonisolated public struct LiveSegmentSummary: Sendable {
    public let id: UUID
    public let isLive: Bool
    public let messages: [LiveMessage]
    public let imageSpan: Int
    /// 长梯当前保留的截图张数（去重后）。
    public let rungCount: Int
    /// 在段链里的位置：0 = 含最新消息，越大越早；nil = 没接上链的孤立片段。
    public let chainIndex: Int?
}

/// 引擎每处理一帧给出的状态快照。只含展示和分析需要的数据，不含像素。
nonisolated public struct EngineUpdate: Sendable {
    public enum Detection: Sendable, Equatable {
        case waiting
        case notChat(reason: String)
        case chat
    }

    public let sessionID: UUID
    public let frameID: UUID
    public let detection: Detection
    /// 单帧版式证据充分，或连续观察到聊天页后为 true。
    public let confirmed: Bool
    public let conversationID: UUID?
    public let title: String?
    /// 实时段内容（side + 文字）变化时递增。展示状态变化不递增。
    public let revision: Int
    public let segments: [LiveSegmentSummary]
    public let currentMessages: [LiveMessage]
    public let contextMessages: [LiveMessage]
    /// 兼容展示层，等同 contextMessages。
    public let liveMessages: [LiveMessage]
    /// 当前屏尚未和已知消息链对齐，liveMessages 只包含本段，不推断与其他段的先后。
    public let currentContextIsIsolated: Bool
    public let currentSegmentIsLive: Bool
    /// 画面停在实时段底部（没有在翻历史）。
    public let viewingLiveTail: Bool
    public let placement: StitchPlacement.Kind?
    public let skippedUnchanged: Bool
    public let ocrMilliseconds: Int
    public let framesProcessed: Int
    public let framesSkipped: Int
    public var currentFrameItems: [SeeUConversationItem] = []
}

nonisolated public struct EngineOutput: Sendable {
    public let update: EngineUpdate
    public let longScreenshot: LongScreenshotInput?
}
