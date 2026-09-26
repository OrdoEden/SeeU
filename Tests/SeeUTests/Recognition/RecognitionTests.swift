import CoreGraphics
import Foundation
import XCTest
@testable import SeeU

final class RecognitionTests: XCTestCase {
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
}
