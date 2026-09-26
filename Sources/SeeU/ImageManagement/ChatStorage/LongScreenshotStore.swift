import CoreGraphics
import Foundation

nonisolated public struct LongScreenshotSummary: Sendable {
    public let imageSpan: Int
    public let rungCount: Int
}

/// 独占长图像素存储和编码。调用方先发布文字上下文，再通过有界队列提交图片。
public actor LongScreenshotStore {
    private var epoch: UUID?
    private var sessionID: UUID?
    private var conversationID: UUID?
    private var lastCapturedAt = Date.distantPast
    private var ladders: [UUID: ChatLadder] = [:]
    private var preferredSegmentID: UUID?
    private var capacity: Int

    public init(capacity: Int = 10) { self.capacity = max(2, capacity) }

    /// 仅由协调器显式切换世代；入队的旧图片不能自动切回旧会话。
    public func reset(to epoch: UUID) {
        self.epoch = epoch
        sessionID = nil
        conversationID = nil
        lastCapturedAt = .distantPast
        ladders = [:]
        preferredSegmentID = nil
    }

    public func clear(epoch: UUID) { reset(to: epoch) }

    public func setCapacity(_ value: Int) {
        capacity = max(2, value)
        for ladder in ladders.values { ladder.setCapacity(capacity) }
    }

    public func ingest(_ input: LongScreenshotInput, merges: [LongScreenshotMerge] = []) {
        guard input.epoch == epoch, input.parsed.capturedAt >= lastCapturedAt else { return }
        if let sessionID, sessionID != input.sessionID { return }
        sessionID = input.sessionID
        if conversationID != input.conversationID {
            ladders = [:]
            conversationID = input.conversationID
        }
        // 图片帧可以被队列覆盖，但坐标系合并事件必须按顺序消费。
        for merge in merges where merge.conversationID == input.conversationID && merge.sourceID != merge.targetID {
            guard let source = ladders.removeValue(forKey: merge.sourceID) else { continue }
            let target: ChatLadder
            if let existing = ladders[merge.targetID] {
                target = existing
            } else {
                target = ChatLadder(width: source.width, capacity: capacity)
                ladders[merge.targetID] = target
            }
            target.absorb(source, shift: merge.shift)
        }
        lastCapturedAt = input.parsed.capturedAt
        preferredSegmentID = input.preferredSegmentID
        let placement = input.placement, parsed = input.parsed, bitmap = input.bitmap
        let target: ChatLadder
        if let existing = ladders[placement.segmentID], existing.width == bitmap.width {
            target = existing
        } else {
            target = ChatLadder(width: bitmap.width, capacity: capacity)
            ladders[placement.segmentID] = target
        }
        let headerRect = CGRect(x: 0, y: 0, width: CGFloat(bitmap.width), height: parsed.headerBottom)
        let header: (jpeg: Data, height: Int)? = parsed.titleAnchored && !parsed.occluders.contains(where: { $0.intersects(headerRect) })
            ? bitmap.pngStrip(y: 0, height: Int(parsed.headerBottom)).map { ($0, Int(parsed.headerBottom)) } : nil
        let footerTop = Int(parsed.contentBottom.rounded())
        let footerRect = CGRect(x: 0, y: footerTop, width: bitmap.width, height: bitmap.height - footerTop)
        let footer: (jpeg: Data, height: Int)? = parsed.keyboardVisible || parsed.occluders.contains(where: { $0.intersects(footerRect) })
            ? nil : bitmap.pngStrip(y: footerTop, height: bitmap.height - footerTop).map { ($0, bitmap.height - footerTop) }
        target.add(bitmap: bitmap, contentTop: parsed.contentTop, contentBottom: parsed.contentBottom,
                   offset: placement.offset, bubbleRects: parsed.bubbles.map(\.rect),
                   capturedAt: parsed.capturedAt, header: header, footer: footer, exclusions: parsed.occluders,
                   seamRange: placement.matchingRange)
        ladders = ladders.filter { input.activeSegmentIDs.contains($0.key) }
    }

    public func render(maxPixelHeight: Int) -> Data? {
        guard let preferredSegmentID, let ladder = ladders[preferredSegmentID],
              let image = ladder.render(maxPixelHeight: maxPixelHeight) else { return nil }
        return FrameBitmap.encodeJPEG(image, quality: 0.92)
    }

    public func summary() -> [UUID: LongScreenshotSummary] {
        ladders.mapValues { LongScreenshotSummary(imageSpan: $0.span, rungCount: $0.rungCount) }
    }
}
