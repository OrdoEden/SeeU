import CoreGraphics
import Foundation

nonisolated public struct LongScreenshotInput: Sendable {
    public let epoch: UUID
    public let sessionID: UUID
    public let conversationID: UUID?
    public let frameID: UUID
    let bitmap: FrameBitmap
    public let parsed: ParsedChatFrame
    /// 与 `parsed.bubbles` 一一对应的会话条目 ID；时间线等非消息条目为 nil。
    /// 图片区域据此定位到前后消息，宿主可把图片插回文字上下文。
    public let messageIDs: [UUID?]
    public let placement: StitchPlacement
    public let activeSegmentIDs: Set<UUID>
    public let preferredSegmentID: UUID
}

nonisolated public struct LongScreenshotMerge: Sendable {
    public let conversationID: UUID?
    public let sourceID: UUID
    public let targetID: UUID
    public let shift: CGFloat

    public init(conversationID: UUID?, sourceID: UUID, targetID: UUID, shift: CGFloat) {
        self.conversationID = conversationID
        self.sourceID = sourceID
        self.targetID = targetID
        self.shift = shift
    }
}
