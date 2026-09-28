import CoreGraphics
import Foundation
import XCTest
@testable import SeeU

/// 真实录屏里暴露的问题：OCR 抖动把同一条消息读成多种写法、误识别条目残留、
/// 键盘弹出把列表上推后被当成新画面拼进长图。
final class TranscriptStabilityTests: XCTestCase {
    private let size = CGSize(width: 390, height: 844)

    private func bitmap(height: Int = 844, rows: (Int) -> UInt8 = { _ in 237 }) throws -> FrameBitmap {
        let width = 390
        var bytes = [UInt8]()
        bytes.reserveCapacity(width * height * 4)
        for y in 0..<height {
            let v = rows(y)
            for _ in 0..<width { bytes.append(contentsOf: [v, v, v, 255]) }
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

    private func bubble(_ text: String, y: CGFloat, side: BubbleSide, width: CGFloat = 200,
                        clippedBottom: Bool = false) -> ChatBubble {
        let x: CGFloat = side == .me ? 390 - 70 - width : 70
        return ChatBubble(kind: .message, text: text, rect: CGRect(x: x, y: y, width: width, height: 40),
                          side: side, sideConfidence: 0.95, clippedTop: false, clippedBottom: clippedBottom,
                          senderName: nil, quote: nil, color: nil)
    }

    private func frame(_ bubbles: [ChatBubble], at second: Double, contentBottom: CGFloat = 740,
                       keyboard: Bool = false) -> ParsedChatFrame {
        ParsedChatFrame(frameID: UUID(), capturedAt: Date(timeIntervalSince1970: second), pixelSize: size,
                        chatScore: 0.9, isChat: true, title: "小林", titleAnchored: true,
                        contentTop: 100, contentBottom: contentBottom, headerBottom: 90, bubbles: bubbles,
                        keyboardVisible: keyboard, inputBarVisible: true, bodyLineHeight: 40,
                        occluders: [], rejectReason: nil)
    }

    private func stableBubbles(_ tail: String) -> [ChatBubble] {
        [bubble("今天晚上一起吃饭吗", y: 200, side: .other),
         bubble("好呀几点见面比较合适", y: 280, side: .me),
         bubble(tail, y: 360, side: .other, width: 160)]
    }

    // MARK: - 文字

    func testSplitRadicalReadingsNormalizeToTheSameText() {
        XCTAssertEqual(TextMatch.normalize("口合口合哈哈"), TextMatch.normalize("哈哈哈哈"))
        XCTAssertEqual(TextMatch.normalize("口合口合口合口合"), TextMatch.normalize("哈哈哈哈"))
        XCTAssertEqual(TextMatch.normalize("好口巴"), "好吧")
        // 真实词语不在拆字表里，不被合并。
        XCTAssertEqual(TextMatch.normalize("口令"), "口令")
        XCTAssertEqual(TextMatch.normalize("可口可乐"), "可口可乐")
    }

    func testWidthEvidenceRepairsOverlongSplitReadingOnly() {
        // 4 个字宽的气泡读出了 8 个字：按合字修复。
        XCTAssertEqual(TextMatch.repairSplitRadicals("口合口合口合口合", width: 160, height: 40), "哈哈哈哈")
        // 宽度确实容得下两个字：保留原文。
        XCTAssertEqual(TextMatch.repairSplitRadicals("口合", width: 80, height: 40), "口合")
        XCTAssertEqual(TextMatch.repairSplitRadicals("普通文字", width: 160, height: 40), "普通文字")
    }

    // MARK: - 消息身份

    func testJitteringReadingsAtOneSlotStayOneMessageAndSettleOnMajority() throws {
        let stitcher = ChatStitcher()
        let image = try bitmap()
        let readings = ["哈哈哈哈", "唅唅唅唅", "哈哈哈哈", "口合口合哈哈", "唅唅唅唅"]
        for (i, tail) in readings.enumerated() {
            _ = stitcher.ingest(frame(stableBubbles(tail), at: Double(i) * 0.5), bitmap: image)
        }
        let entries = try XCTUnwrap(stitcher.currentSegment).entries.filter { $0.kind == .message }
        XCTAssertEqual(entries.count, 3, entries.map(\.text).description)
        XCTAssertEqual(entries.last?.text, "哈哈哈哈")
    }

    func testMinorityReadingDoesNotFlipDisplayedText() throws {
        var entry = TranscriptEntry(
            id: UUID(), kind: .message, variants: [:], normalized: "", side: .other, sideConfidence: 0.9,
            top: 0, bottom: 40, minX: 70, maxX: 230, clippedTop: false, clippedBottom: false,
            senderName: nil, quote: nil, textConfirmed: true, observations: 1, misses: 0,
            firstSeen: .distantPast, lastSeen: .distantPast
        )
        entry.observe(normalized: "好的", text: "好的")
        entry.observe(normalized: "好白", text: "好白")
        XCTAssertEqual(entry.text, "好的")
        entry.observe(normalized: "好的", text: "好的")
        entry.observe(normalized: "好白", text: "好白")
        XCTAssertEqual(entry.text, "好的", "票数持平不切换")
        entry.observe(normalized: "好白", text: "好白")
        entry.observe(normalized: "好白", text: "好白")
        XCTAssertEqual(entry.text, "好白", "挑战者明显领先后才切换")
    }

    func testGhostSeenTwiceIsRemovedAfterRepeatedAbsence() throws {
        let stitcher = ChatStitcher()
        let image = try bitmap()
        let ghost = bubble("画中画残留文字", y: 520, side: .other)
        for i in 0..<2 {
            _ = stitcher.ingest(frame(stableBubbles("哈哈哈哈") + [ghost], at: Double(i) * 0.5), bitmap: image)
        }
        XCTAssertTrue(try XCTUnwrap(stitcher.currentSegment).entries.contains { $0.text == "画中画残留文字" })
        for i in 2..<6 {
            _ = stitcher.ingest(frame(stableBubbles("哈哈哈哈"), at: Double(i) * 0.5), bitmap: image)
        }
        XCTAssertFalse(try XCTUnwrap(stitcher.currentSegment).entries.contains { $0.text == "画中画残留文字" })
        XCTAssertEqual(try XCTUnwrap(stitcher.currentSegment).entries.count, 3)
    }

    /// 贴着输入栏的最后一条拿不到文字佐证，此前会一直卡在"未确认"，上下文塌缩成当前一屏。
    /// 同一槽位再看到一次就该确认。
    func testClippedTailIsConfirmedOnSecondObservation() throws {
        let stitcher = ChatStitcher()
        let image = try bitmap()
        let bubbles = stableBubbles("我大概七点半到公司楼下")
            + [bubble("路上有点堵，可能晚十分钟", y: 440, side: .other, clippedBottom: true)]
        _ = stitcher.ingest(frame(bubbles, at: 0), bitmap: image)
        let once = try XCTUnwrap(try XCTUnwrap(stitcher.currentSegment).entries.last)
        XCTAssertEqual(once.text, "路上有点堵，可能晚十分钟")
        XCTAssertTrue(once.clippedBottom)
        XCTAssertFalse(once.textConfirmed, "只看到一次还不算确认")

        _ = stitcher.ingest(frame(bubbles, at: 0.5), bitmap: image)
        let twice = try XCTUnwrap(try XCTUnwrap(stitcher.currentSegment).entries.last)
        XCTAssertTrue(twice.textConfirmed, "同槽位第二次观察应确认")
    }

    // MARK: - 片段链

    /// 纹理必须整帧唯一，否则对齐会在错误偏移上匹配成功。
    /// 这里没有针对"另起一段并继承方向"的用例：那个分支只由丢帧触发，合成帧造不出来，
    /// 交给真实录屏的 `ReplayTests`。这个辅助函数留给需要真实位移的用例。
    private func scrolledBitmap(_ scroll: Int) throws -> FrameBitmap {
        let width = 390, height = 844
        var bytes = [UInt8](repeating: 240, count: width * height * 4)
        // 整帧唯一的高频纹理：背景是均匀噪声，错位匹配会得到很大的误差，不会假成功。
        // 用 &* 和截断，避免 y - scroll 为负时溢出。
        func texture(_ x: Int, _ y: Int) -> UInt8 {
            let value = UInt64(bitPattern: Int64(x) &* 73_856_093) ^ UInt64(bitPattern: Int64(y) &* 19_349_663)
            return UInt8(truncatingIfNeeded: value ^ (value >> 13) ^ (value >> 23))
        }
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                let value = texture(x, y - scroll)
                bytes[index] = value; bytes[index + 1] = value; bytes[index + 2] = value
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

    func testOverlappingDuplicatesCollapseIntoTheBetterObservedEntry() {
        func entry(_ text: String, observations: Int) -> TranscriptEntry {
            TranscriptEntry(
                id: UUID(), kind: .message, variants: [TextMatch.normalize(text): (text, observations)],
                normalized: TextMatch.normalize(text), side: .other, sideConfidence: 0.9,
                top: 100, bottom: 140, minX: 70, maxX: 230, clippedTop: false, clippedBottom: false,
                senderName: nil, quote: nil, textConfirmed: true, observations: observations, misses: 0,
                firstSeen: .distantPast, lastSeen: .distantPast
            )
        }
        let strong = entry("哈哈哈哈", observations: 5)
        var entries = [entry("唅唅唅唅", observations: 1), strong]
        entries.sort { $0.top < $1.top }
        XCTAssertTrue(ChatStitcher.collapseOverlapping(&entries))
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].id, strong.id)
        XCTAssertEqual(entries[0].text, "哈哈哈哈")
    }

    // MARK: - 长图

    func testLadderSkipsFramesWithoutNewCoverage() throws {
        let ladder = ChatLadder(width: 390, capacity: 3)
        let image = try bitmap()
        func add(offset: CGFloat, bottom: CGFloat = 740, at second: Double) -> Bool {
            ladder.add(bitmap: image, contentTop: 100, contentBottom: bottom, offset: offset, bubbleRects: [],
                       capturedAt: Date(timeIntervalSince1970: second), header: nil, footer: nil,
                       minimumNewHeight: 20)
        }
        XCTAssertTrue(add(offset: 0, at: 0))
        XCTAssertFalse(add(offset: 0, at: 1), "原地静止帧")
        // 键盘弹起：列表上推 300，可见区缩到 440，全部落在已覆盖范围内。
        XCTAssertFalse(add(offset: 300, bottom: 440, at: 2), "键盘帧")
        XCTAssertFalse(add(offset: 10, at: 3), "不足半行的抖动")
        XCTAssertTrue(add(offset: 120, at: 4), "新消息把内容往上推")
        XCTAssertEqual(ladder.rungCount, 2)
    }

    // MARK: - 键盘

    func testInputBarAboveKeyboardIsExcludedFromContent() throws {
        // 0..<500 聊天背景，500..<560 输入栏，560 起键盘。键盘标记在 570。
        let image = try bitmap { y in y < 500 ? 237 : (y < 560 ? 250 : 205) }
        let top = try XCTUnwrap(ChatLayoutParser.detectInputBarTop(image, above: 570))
        XCTAssertEqual(top, 500, accuracy: 6)
    }
}
