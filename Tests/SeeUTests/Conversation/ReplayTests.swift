import CoreGraphics
import Foundation
import XCTest
@testable import SeeU

/// 回放 Galchat“录制识别帧”保存的真实帧，输出逐帧识别/拼接/新消息判断日志。
///
/// 用法（模拟器可以直接读 Mac 上的目录）：
/// ```
/// TEST_RUNNER_SEEU_REPLAY_DIR=/path/to/SeeUReplay/20260927-122300 \
///   xcodebuild test -scheme SeeU -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
///   -only-testing:SeeUTests/ReplayTests
/// ```
/// 结果写到该目录的 `replay-report.txt` 与 `replay-long.jpg`。未设置环境变量时跳过。
final class ReplayTests: XCTestCase {
    private struct Sidecar: Decodable {
        let index: Int
        let capturedAt: Double
        let keyboardTop: Double?
        let occluders: [[Double]]
    }

    func testReplayRecordedFrames() async throws {
        guard let path = ProcessInfo.processInfo.environment["SEEU_REPLAY_DIR"], !path.isEmpty else {
            throw XCTSkip("设置 SEEU_REPLAY_DIR 后回放录制的帧")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let frames = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "jpg" && !$0.lastPathComponent.hasPrefix("replay") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(frames.isEmpty, "目录里没有 .jpg 帧")

        let engine = SeeUConversationEngine()
        let store = SeeULongScreenshotStore()
        let session = UUID(), epoch = UUID()
        await store.reset(to: epoch)

        var log: [String] = []
        var lastTailID: UUID?
        var newTailEvents = 0, imageAdds = 0, imageSkips = 0, revisions = Set<Int>()
        var context: [LiveMessage] = []
        let start = Date()
        for (position, url) in frames.enumerated() {
            let sidecar = try? JSONDecoder().decode(
                Sidecar.self, from: Data(contentsOf: url.deletingPathExtension().appendingPathExtension("json")))
            let keyboardTop = sidecar?.keyboardTop.map { CGFloat($0) }
            let occluders = (sidecar?.occluders ?? []).compactMap { values -> CGRect? in
                values.count == 4 ? CGRect(x: values[0], y: values[1], width: values[2], height: values[3]) : nil
            }
            // 与 Galchat AppFrameExclusion 相同的过滤规则：键盘标记以下、画中画区域内的文字不参与识别。
            let policy = FrameExclusionPolicy { lines, size in
                // 没有录制旁注（例如普通截图）时，按 Galchat 键盘标记自行定位键盘。
                let keyboardTop = keyboardTop ?? lines.filter {
                    ($0.text.hasPrefix("Jarvis 键盘") || $0.text.hasPrefix("Jarvis键盘")) && $0.rect.midY > 0.4 * size.height
                }.map(\.rect.minY).min()
                let kept = lines.filter { line in
                    if let keyboardTop, line.rect.minY >= keyboardTop - 2 { return false }
                    return !occluders.contains { $0.contains(CGPoint(x: line.rect.midX, y: line.rect.midY)) }
                }
                return FrameExclusion(lines: kept, keyboardTop: keyboardTop, occluders: occluders)
            }
            let capturedAt = sidecar.map { Date(timeIntervalSince1970: $0.capturedAt) }
                ?? start.addingTimeInterval(Double(position) * 0.3)
            guard let output = try await engine.process(
                jpeg: Data(contentsOf: url), frameID: UUID(), sessionID: session,
                capturedAt: capturedAt, exclusion: policy, epoch: epoch
            ) else { continue }
            let update = output.update
            revisions.insert(update.revision)
            if update.detection == .chat { context = update.contextMessages }

            var image = "·"
            if let input = output.longScreenshot {
                let merges = input.placement.merged.map {
                    LongScreenshotMerge(conversationID: input.conversationID, sourceID: $0.id,
                                        targetID: input.placement.segmentID, shift: $0.shift)
                }
                if await store.ingest(input, merges: merges) {
                    image = "+"
                    imageAdds += 1
                } else {
                    image = "="
                    imageSkips += 1
                }
            }
            let tail = update.contextMessages.last { $0.kind == .message }
            let passesGate = update.detection == .chat && update.confirmed
                && update.viewingLiveTail && !update.currentContextIsIsolated
            let isNew = passesGate && tail != nil && tail?.id != lastTailID
            if passesGate, let tail { lastTailID = tail.id }
            if isNew { newTailEvents += 1 }

            let detection: String
            switch update.detection {
            case .chat: detection = "chat"
            case .waiting: detection = "wait"
            case .notChat(let reason): detection = "no(\(reason))"
            }
            let keyboard = output.longScreenshot?.parsed.keyboardVisible == true || keyboardTop != nil ? "⌨︎" : " "
            let place: String
            switch update.placement {
            case .extended?: place = "ext"
            case .rejoined?: place = "rej"
            case .newSegment?: place = "NEW-SEG"
            case nil: place = "-"
            }
            let side = tail.map { $0.side == .me ? "我" : ($0.side == .other ? "对方" : "?") } ?? ""
            // 会话标识只看前 4 位：回放里最该发现的是"会话被重置了"，不是具体是哪个会话。
            let conversation = update.conversationID.map { String($0.uuidString.prefix(4)) } ?? "-"
            log.append(String(
                format: "%@ %@ %@ conv=%@ place=%@ img=%@ rev=%d live=%@ iso=%@ ctx=%d tail=%@:%@%@",
                url.deletingPathExtension().lastPathComponent, keyboard, detection, conversation,
                place, image, update.revision,
                update.viewingLiveTail ? "y" : "n", update.currentContextIsIsolated ? "y" : "n",
                update.contextMessages.filter { $0.kind == .message }.count, side,
                String((tail?.text ?? "").prefix(24)), isNew ? "  ◀︎ 新消息" : ""
            ))
        }

        // 最终上下文，以及相邻两条同一方、文字高度相似的疑似重复。
        var final: [String] = []
        var suspects = 0
        var previous: LiveMessage?
        for message in context {
            if message.kind == .gap { final.append("—— 缺口 ——"); previous = nil; continue }
            guard message.kind == .message else { continue }
            if let previous, previous.side == message.side,
               TextMatch.similarity(TextMatch.normalize(previous.text), TextMatch.normalize(message.text)) >= 0.8 {
                suspects += 1
                final.append("⚠︎ 疑似重复")
            }
            final.append("\(message.side == .me ? "我" : (message.side == .other ? "对方" : "?"))：\(message.text)")
            previous = message
        }
        let summary = """
        帧数 \(frames.count) · 长图加入 \(imageAdds) · 长图跳过 \(imageSkips) · 新消息事件 \(newTailEvents) · \
        revision 变化 \(revisions.count) · 疑似重复 \(suspects)
        """
        let report = ([summary, ""] + log + ["", "== 最终上下文 =="] + final).joined(separator: "\n")
        try report.write(to: directory.appendingPathComponent("replay-report.txt"), atomically: true, encoding: .utf8)
        if let jpeg = await store.render(maxPixelHeight: 16_000) {
            try jpeg.write(to: directory.appendingPathComponent("replay-long.jpg"))
        }
        print(summary)
    }
}
