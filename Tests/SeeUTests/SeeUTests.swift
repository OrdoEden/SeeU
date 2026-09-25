import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import SeeU

final class SeeUTests: XCTestCase {
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

    func testNoExclusionPolicyDoesNotRemoveHostLikeText() {
        let lines = [OCRLine(text: "我的应用 意图", rect: CGRect(x: 10, y: 20, width: 100, height: 20), confidence: 0.9)]
        let result = FrameExclusionPolicy.none.filter(lines, CGSize(width: 400, height: 800))
        XCTAssertEqual(result.lines, lines)
        XCTAssertNil(result.keyboardTop)
        XCTAssertTrue(result.occluders.isEmpty)
    }

    func testObservationPreservesPixelCoordinatesAndOCRConfidence() throws {
        let bubble = ChatBubble(kind: .message, text: "原文", rect: CGRect(x: 20, y: 80, width: 100, height: 24),
                                side: .other, sideConfidence: 0.8, clippedTop: false, clippedBottom: false,
                                senderName: "小林", quote: nil, color: nil, recognitionConfidence: 0.7)
        let frame = ParsedChatFrame(
            frameID: UUID(), capturedAt: Date(timeIntervalSince1970: 100), pixelSize: CGSize(width: 400, height: 800),
            chatScore: 0.9, isChat: true, title: "小林", titleAnchored: true, contentTop: 70, contentBottom: 700,
            headerBottom: 60, bubbles: [bubble], keyboardVisible: false, inputBarVisible: true,
            bodyLineHeight: 24, occluders: [], rejectReason: nil
        )
        let source = SeeUObservation(frame: frame, bubble: bubble)
        let decoded = try JSONDecoder().decode(SeeUObservation.self, from: JSONEncoder().encode(source))
        XCTAssertEqual(decoded, source)
        XCTAssertEqual(decoded.x, 20)
        XCTAssertEqual(decoded.y, 80)
        XCTAssertEqual(decoded.pixelHeight, 800)
        XCTAssertEqual(decoded.recognitionConfidence, 0.7)
        XCTAssertEqual(decoded.observedAt, frame.capturedAt)
    }

    func testEncodedAndPixelBudgetsFailExplicitlyBeforeOCR() throws {
        XCTAssertThrowsError(try FrameBitmap(imageData: Data(repeating: 0, count: 2),
                                            limits: SeeUImageLimits(maximumEncodedBytes: 1))) {
            guard case SeeUImageError.encodedSizeExceeded = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        XCTAssertThrowsError(try FrameBitmap(imageData: data as Data, limits: SeeUImageLimits(maximumPixels: 3))) {
            guard case SeeUImageError.pixelBudgetExceeded = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
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
