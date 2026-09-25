import CoreGraphics
import Foundation

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

nonisolated public struct SeeUConversationItem: Codable, Sendable, Equatable {
    public let id: UUID
    public let kind: BubbleKind
    public let side: BubbleSide
    public let sideConfidence: Double
    /// gap 无原文；不将 App 的提示词或缺口说明写成聊天原文。
    public let text: String?
    public let senderNameCandidate: String?
    public let quote: String?
    public let clipped: Bool
    public let observations: Int
    public let sources: [SeeUObservation]

    init(_ message: LiveMessage) {
        id = message.id
        kind = message.kind
        side = message.side
        sideConfidence = message.sideConfidence
        text = message.kind == .gap ? nil : message.text
        senderNameCandidate = message.senderName
        quote = message.quote
        clipped = message.clipped
        observations = message.observations
        sources = message.sources
    }
}

nonisolated public struct SeeUConversationSegment: Codable, Sendable {
    public let id: UUID
    /// 0 是最新段，数值越大越早；nil 表示没有证据与其他段建立顺序。
    public let chainIndex: Int?
    public let items: [SeeUConversationItem]
}

/// 短期识别会话快照；名称均为未确认观察值，不承担联系人身份与持久化。
/// 时间标记保留原文，不推断发送日期；未连接的片段保持独立。
nonisolated public struct SeeUConversation: Codable, Sendable {
    public enum Detection: String, Codable, Sendable {
        case waiting, notChat, chat
    }

    public let schemaVersion: Int
    public let captureSessionID: UUID
    public let conversationInstanceID: UUID?
    public let frameID: UUID
    public let revision: Int
    public let titleCandidate: String?
    /// 聊天版式证据已确认，不表示联系人身份已确认。
    public let confirmed: Bool
    public let detection: Detection
    public let rejectionReason: String?
    public let currentContextIsIsolated: Bool
    public let segments: [SeeUConversationSegment]
    public let currentItems: [SeeUConversationItem]
    public let contextItems: [SeeUConversationItem]

    init(_ update: EngineUpdate) {
        schemaVersion = 1
        captureSessionID = update.sessionID
        conversationInstanceID = update.conversationID
        frameID = update.frameID
        revision = update.revision
        titleCandidate = update.title
        confirmed = update.confirmed
        switch update.detection {
        case .waiting:
            detection = .waiting
            rejectionReason = nil
        case let .notChat(reason):
            detection = .notChat
            rejectionReason = reason
        case .chat:
            detection = .chat
            rejectionReason = nil
        }
        currentContextIsIsolated = update.currentContextIsIsolated
        segments = update.segments.map {
            SeeUConversationSegment(id: $0.id, chainIndex: $0.chainIndex,
                                    items: $0.messages.map(SeeUConversationItem.init))
        }
        currentItems = update.currentFrameItems
        contextItems = update.contextMessages.map(SeeUConversationItem.init)
    }

    public func jsonData(prettyPrinted: Bool = false) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = prettyPrinted ? [.sortedKeys, .prettyPrinted] : [.sortedKeys]
        return try encoder.encode(self)
    }

    public static func decodeJSON(_ data: Data) throws -> SeeUConversation {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let header = try decoder.decode(SchemaHeader.self, from: data)
        guard header.schemaVersion == 1 else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [CodingKeys.schemaVersion],
                debugDescription: "Unsupported SeeU conversation schemaVersion: \(header.schemaVersion)"
            ))
        }
        return try decoder.decode(SeeUConversation.self, from: data)
    }

    private struct SchemaHeader: Decodable {
        let schemaVersion: Int
    }
}

extension EngineUpdate {
    public var conversation: SeeUConversation { SeeUConversation(self) }
}
