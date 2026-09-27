import CoreGraphics
import Foundation
import XCTest
@testable import SeeU

final class ImageRegionTests: XCTestCase {
    private func patch(_ color: (Int, Int) -> (UInt8, UInt8, UInt8)) -> [UInt8] {
        var bytes = [UInt8]()
        for y in 0..<24 {
            for x in 0..<24 {
                let (r, g, b) = color(x, y)
                bytes.append(contentsOf: [r, g, b, 255])
            }
        }
        return bytes
    }

    private func bitmap(width: Int, height: Int,
                        pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) throws -> FrameBitmap {
        var bytes = [UInt8]()
        bytes.reserveCapacity(width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = pixel(x, y)
                bytes.append(contentsOf: [r, g, b, 255])
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8,
                                          bitsPerPixel: 32, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                          provider: provider, decode: nil, shouldInterpolate: false,
                                          intent: .defaultIntent))
        return try FrameBitmap(image: image)
    }

    private func bubble(_ rect: CGRect, side: BubbleSide = .other, kind: BubbleKind = .message) -> ChatBubble {
        ChatBubble(kind: kind, text: "文字", rect: rect, side: side, sideConfidence: 0.9,
                   clippedTop: false, clippedBottom: false, senderName: nil, quote: nil, color: nil)
    }

    private func parsed(size: CGSize, bubbles: [ChatBubble], occluders: [CGRect] = []) -> ParsedChatFrame {
        ParsedChatFrame(frameID: UUID(), capturedAt: Date(), pixelSize: size, chatScore: 0.9, isChat: true,
                        title: "小林", titleAnchored: true, contentTop: 100, contentBottom: size.height - 100,
                        headerBottom: 90, bubbles: bubbles, keyboardVisible: false, inputBarVisible: true,
                        bodyLineHeight: 30, occluders: occluders, rejectReason: nil)
    }

    func testAvatarGeometryAcceptsBothColumnsOnly() {
        let width: CGFloat = 1_000
        XCTAssertTrue(SeeUChatImageDetector.isAvatarShaped(CGRect(x: 30, y: 200, width: 100, height: 100),
                                                          imageWidth: width, side: .other))
        XCTAssertTrue(SeeUChatImageDetector.isAvatarShaped(CGRect(x: 870, y: 200, width: 100, height: 100),
                                                          imageWidth: width, side: .me))
        XCTAssertFalse(SeeUChatImageDetector.isAvatarShaped(CGRect(x: 870, y: 200, width: 100, height: 100),
                                                           imageWidth: width, side: .other))
        XCTAssertFalse(SeeUChatImageDetector.isAvatarShaped(CGRect(x: 30, y: 200, width: 300, height: 300),
                                                           imageWidth: width, side: .other))
        XCTAssertFalse(SeeUChatImageDetector.isAvatarShaped(CGRect(x: 30, y: 200, width: 100, height: 60),
                                                           imageWidth: width, side: .other))
    }

    func testPatchTextureColorAndDifference() throws {
        XCTAssertFalse(ImagePatch.hasTexture(patch { _, _ in (120, 160, 200) }))
        XCTAssertTrue(ImagePatch.hasTexture(patch { x, y in (x / 4 + y / 4) % 2 == 0 ? (30, 30, 30) : (220, 220, 220) }))

        let mixed = patch { x, _ in [(0, 0, 0), (255, 255, 255), (200, 60, 40)][x % 3] }
        let color = try XCTUnwrap(ImagePatch.dominantColor(mixed))
        XCTAssertEqual(color.red, 200.0 / 255, accuracy: 0.001)
        XCTAssertEqual(color.green, 60.0 / 255, accuracy: 0.001)
        XCTAssertEqual(color.blue, 40.0 / 255, accuracy: 0.001)

        let first = patch { x, y in (UInt8(x * 10), UInt8(y * 10), 90) }
        let near = patch { x, y in (UInt8(x * 10 + 2), UInt8(y * 10), 90) }
        let other = patch { x, y in (UInt8(240 - x * 10), 20, UInt8(y * 10)) }
        XCTAssertLessThan(ImagePatch.difference(first, near), ImageHarvester.sameImageThreshold)
        XCTAssertGreaterThan(ImagePatch.difference(first, other), ImageHarvester.sameImageThreshold)
    }

    func testAlignedBubbleMatchesSameRowAndSide() {
        let frame = parsed(size: CGSize(width: 1_000, height: 2_000), bubbles: [
            bubble(CGRect(x: 150, y: 400, width: 300, height: 60)),
            bubble(CGRect(x: 500, y: 400, width: 300, height: 60), side: .me)
        ])
        let avatar = CGRect(x: 30, y: 390, width: 100, height: 100)
        XCTAssertEqual(SeeUChatImageDetector.alignedBubble(for: avatar, side: .other, in: frame), 0)
        XCTAssertEqual(SeeUChatImageDetector.alignedBubble(for: avatar, side: .me, in: frame), 1)
        XCTAssertNil(SeeUChatImageDetector.alignedBubble(for: avatar.offsetBy(dx: 0, dy: 400), side: .other, in: frame))
    }

    func testImageMessageRectFindsStickerBesideAvatarAndSkipsNickname() throws {
        let size = CGSize(width: 600, height: 1_200)
        // 白底；昵称细行 y 300–312；表情包 x 120–300, y 320–500。
        let image = try bitmap(width: 600, height: 1_200) { x, y in
            if (120..<200).contains(x), (300..<312).contains(y) { return (90, 90, 90) }
            if (120..<300).contains(x), (320..<500).contains(y) { return ((x + y) % 20 < 10) ? (240, 180, 40) : (60, 40, 30) }
            return (255, 255, 255)
        }
        let frame = SeeUImageFrame(bitmap: image, parsed: parsed(size: size, bubbles: [
            bubble(CGRect(x: 120, y: 200, width: 200, height: 40)),
            bubble(CGRect(x: 120, y: 700, width: 200, height: 40))
        ]))
        let avatar = SeeUChatImageDetector.Avatar(rect: CGRect(x: 20, y: 300, width: 60, height: 60),
                                                  side: .other, alignedBubbleIndex: nil)
        let rect = try XCTUnwrap(SeeUChatImageDetector().imageMessageRect(beside: avatar, avatars: [avatar], in: frame))
        XCTAssertEqual(rect.minX, 120, accuracy: 4)
        XCTAssertEqual(rect.minY, 320, accuracy: 4)
        XCTAssertEqual(rect.maxX, 300, accuracy: 4)
        XCTAssertEqual(rect.maxY, 500, accuracy: 4)
    }

    func testImageMessageRectRejectsOccludedContent() throws {
        let size = CGSize(width: 600, height: 1_200)
        let image = try bitmap(width: 600, height: 1_200) { x, y in
            (120..<300).contains(x) && (320..<500).contains(y) ? (200, 60, 40) : (255, 255, 255)
        }
        let frame = SeeUImageFrame(bitmap: image, parsed: parsed(size: size, bubbles: [],
                                                                 occluders: [CGRect(x: 200, y: 400, width: 300, height: 80)]))
        let avatar = SeeUChatImageDetector.Avatar(rect: CGRect(x: 20, y: 320, width: 60, height: 60),
                                                  side: .other, alignedBubbleIndex: nil)
        XCTAssertNil(SeeUChatImageDetector().imageMessageRect(beside: avatar, avatars: [avatar], in: frame))
    }

    func testAnchorsUseNearestMessagesAndSkipTimeItems() {
        let ids = [UUID(), nil, UUID(), UUID()]
        let bubbles = [
            bubble(CGRect(x: 100, y: 100, width: 200, height: 40)),
            bubble(CGRect(x: 250, y: 200, width: 100, height: 20), kind: .time),
            bubble(CGRect(x: 100, y: 260, width: 200, height: 40)),
            bubble(CGRect(x: 100, y: 600, width: 200, height: 40))
        ]
        let anchors = ImageHarvester.anchors(for: CGRect(x: 100, y: 320, width: 150, height: 150),
                                             alignedIndex: nil, bubbles: bubbles, ids: ids)
        XCTAssertEqual(anchors.preceding, ids[2])
        XCTAssertEqual(anchors.following, ids[3])
        XCTAssertNil(anchors.aligned)

        let mismatched = ImageHarvester.anchors(for: .zero, alignedIndex: nil, bubbles: bubbles, ids: [UUID()])
        XCTAssertNil(mismatched.preceding)
    }
}
