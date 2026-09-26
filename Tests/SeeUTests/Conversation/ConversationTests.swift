import Foundation
import XCTest
@testable import SeeU

final class ConversationTests: XCTestCase {
    func testMergedSourcesDeduplicateFramesKeepLatestThreeAndPreserveText() throws {
        func source(_ id: UUID, time: Int, confidence: Double) throws -> SeeUObservation {
            let object: [String: Any] = [
                "frameID": id.uuidString, "observedAt": time,
                "pixelWidth": 400, "pixelHeight": 800,
                "x": 20, "y": 80, "width": 100, "height": 24,
                "recognitionConfidence": confidence
            ]
            return try JSONDecoder().decode(SeeUObservation.self, from: JSONSerialization.data(withJSONObject: object))
        }
        let ids = (0..<4).map { _ in UUID() }
        let observations = try ids.enumerated().map { try source($0.element, time: $0.offset, confidence: 0.9) }
        let olderDuplicate = try source(ids[2], time: 2, confidence: 0.4)
        var entry = TranscriptEntry(
            id: UUID(), kind: .message, variants: ["原文": ("原文", 3)], normalized: "原文",
            side: .other, sideConfidence: 0.9, top: 80, bottom: 104, minX: 20, maxX: 120,
            clippedTop: false, clippedBottom: false, senderName: "小林", quote: "引用",
            textConfirmed: true, observations: 3, misses: 0, firstSeen: .distantPast, lastSeen: .distantPast,
            sources: [observations[2], observations[0]]
        )
        entry.mergeSources([observations[3], olderDuplicate, observations[1]])
        XCTAssertEqual(entry.sources.map(\.frameID), Array(ids.suffix(3)))
        XCTAssertEqual(entry.sources[1].recognitionConfidence, 0.9)
        XCTAssertEqual(entry.text, "原文")
        XCTAssertEqual(entry.quote, "引用")
    }

    func testUnknownConversationSchemaIsRejectedBeforeReadingPayload() {
        XCTAssertThrowsError(try SeeUConversation.decodeJSON(Data(#"{"schemaVersion":2}"#.utf8))) {
            guard case let DecodingError.dataCorrupted(context) = $0 else {
                return XCTFail("Expected schema rejection: \($0)")
            }
            XCTAssertEqual(context.codingPath.last?.stringValue, "schemaVersion")
            XCTAssertTrue(context.debugDescription.contains("Unsupported SeeU conversation schemaVersion: 2"))
        }
    }

    func testSemanticItemsPreserveQuoteNameAndGapWithoutInventingText() throws {
        let message = LiveMessage(id: UUID(), kind: .message, side: .unknown,
                                  sideConfidence: 0.4, text: "今晚可以吗？",
                                  senderName: "小林", quote: "昨天的计划", observations: 1, clipped: true)
        let item = SeeUConversationItem(message)
        let decoded = try JSONDecoder().decode(SeeUConversationItem.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(decoded, item)
        XCTAssertEqual(decoded.senderNameCandidate, "小林")
        XCTAssertEqual(decoded.quote, "昨天的计划")
        XCTAssertEqual(decoded.side, .unknown)
        XCTAssertTrue(decoded.clipped)
        let gap = LiveMessage(id: UUID(), kind: .gap, side: .unknown, sideConfidence: 0,
                              text: "中间有未识别的聊天记录", senderName: nil,
                              quote: nil, observations: 0, clipped: false)
        XCTAssertNil(SeeUConversationItem(gap).text)
    }

    func testConversationJSONRoundTripPreservesVersionAndTimeMarker() throws {
        let frameID = UUID(), sessionID = UUID()
        let time = LiveMessage(id: UUID(), kind: .time, side: .unknown, sideConfidence: 0,
                               text: "昨天 20:30", senderName: nil, quote: nil, observations: 1, clipped: false)
        let update = EngineUpdate(
            sessionID: sessionID, frameID: frameID, detection: .chat, confirmed: true,
            conversationID: UUID(), title: "小林", revision: 3, segments: [], currentMessages: [],
            contextMessages: [time], liveMessages: [time], currentContextIsIsolated: false,
            currentSegmentIsLive: true, viewingLiveTail: true, placement: nil, skippedUnchanged: false,
            ocrMilliseconds: 0, framesProcessed: 1, framesSkipped: 0,
            currentFrameItems: [SeeUConversationItem(time)]
        )
        let decoded = try SeeUConversation.decodeJSON(update.conversation.jsonData())
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.captureSessionID, sessionID)
        XCTAssertEqual(decoded.titleCandidate, "小林")
        XCTAssertEqual(decoded.currentItems.first?.kind, .time)
        XCTAssertEqual(decoded.currentItems.first?.text, "昨天 20:30")
    }
}
