import CoreGraphics
import Foundation
import XCTest
@testable import SeeU

/// 用真实截图数据集跑识别，输出逐帧报告供人工核对。
///
/// 这些是普通截图，不是录屏帧，所以：
/// - 没有旁注（键盘顶部、画中画遮挡区），键盘只能靠帧内的文字自己认；
/// - 相邻截图的时间由文件名顺序合成（每张间隔 0.3 秒），用来检验滚动拼接。
///
/// 用法：
/// ```
/// SEEU_DATASET_DIR=/path/to/截图 xcodebuild test -scheme SeeU \
///   -destination 'platform=iOS Simulator,id=<id>' -only-testing:SeeUTests/DatasetTests
/// ```
/// 报告写到该目录的 `dataset-report.txt`。未设置环境变量时跳过。
final class DatasetTests: XCTestCase {
    private struct Row {
        let name: String
        var detection: String
        var conversation: String
        var title: String
        var current: Int
        var context: Int
        var isolated: Bool
        var liveTail: Bool
        var placement: String
        var note: String
    }

    func testDatasetRecognition() async throws {
        guard let path = ProcessInfo.processInfo.environment["SEEU_DATASET_DIR"], !path.isEmpty else {
            throw XCTSkip("设置 SEEU_DATASET_DIR 后跑真实截图数据集")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        // 数据集里的图可能放在子目录里，逐层收集。
        let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { ["png", "jpg"].contains($0.pathExtension.lowercased()) }
            .filter { !$0.lastPathComponent.hasPrefix("dataset-") }
            .sorted { $0.path < $1.path } ?? []
        XCTAssertFalse(files.isEmpty, "目录里没有图片")

        let engine = SeeUConversationEngine()
        let session = UUID(), epoch = UUID()
        let start = Date(timeIntervalSince1970: 0)
        var rows: [Row] = []
        var conversations = Set<String>()
        var titles = Set<String>()
        var chatFrames = 0

        for (position, url) in files.enumerated() {
            guard let data = try? Data(contentsOf: url),
                  let output = try await engine.process(
                      jpeg: data, frameID: UUID(), sessionID: session,
                      capturedAt: start.addingTimeInterval(Double(position) * 0.3),
                      exclusion: .none, epoch: epoch) else { continue }
            let update = output.update
            let conversation = update.conversationID.map { String($0.uuidString.prefix(4)) } ?? "-"
            if update.conversationID != nil { conversations.insert(conversation) }
            if let title = update.title { titles.insert(title) }
            let detection: String
            switch update.detection {
            case .chat: detection = "chat"; chatFrames += 1
            case .waiting: detection = "wait"
            case .notChat(let reason): detection = "no(\(reason))"
            }
            let place: String
            switch update.placement {
            case .extended?: place = "ext"
            case .rejoined?: place = "rej"
            case .newSegment?: place = "NEW-SEG"
            case nil: place = "-"
            }
            let tail = update.contextMessages.last { $0.kind == .message }
            rows.append(Row(
                name: url.lastPathComponent, detection: detection, conversation: conversation,
                title: update.title ?? "-", current: update.currentMessages.filter { $0.kind == .message }.count,
                context: update.contextMessages.filter { $0.kind == .message }.count,
                isolated: update.currentContextIsIsolated, liveTail: update.viewingLiveTail,
                placement: place,
                note: tail.map { "\($0.side == .me ? "我" : ($0.side == .other ? "对方" : "?"))：\($0.text.prefix(20))" } ?? ""
            ))
        }

        let summary = """
        图片 \(files.count) · 识别为聊天页 \(chatFrames) · 会话数 \(conversations.count) · 标题 \(titles.sorted())
        """
        let log = rows.map {
            String(format: "%@ %@ conv=%@ title=%@ 当前=%d 上下文=%d iso=%@ live=%@ %@  %@",
                   $0.name, $0.detection, $0.conversation, $0.title, $0.current, $0.context,
                   $0.isolated ? "y" : "n", $0.liveTail ? "y" : "n", $0.placement, $0.note)
        }
        let report = ([summary, ""] + log).joined(separator: "\n")
        try report.write(to: directory.appendingPathComponent("dataset-report.txt"), atomically: true, encoding: .utf8)
        print(summary)
    }

    /// 会话身份必须按标题稳定，而不是每帧新生成。用数据集里同一聊天的多张截图验证：
    /// 标题相同的帧必须拿到同一个 id。
    ///
    /// 这条不变量是"切走再切回联系人不断"的基础。数据集里需要有同一聊天的多张截图
    /// （这批数据里是「上海虹桥<>福州」和「TEAMBOOM Chat」）。
    func testSameTitleKeepsSameConversationIdentity() async throws {
        guard let path = ProcessInfo.processInfo.environment["SEEU_DATASET_DIR"], !path.isEmpty else {
            throw XCTSkip("设置 SEEU_DATASET_DIR 后验证会话身份稳定")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension.lowercased() == "png" }
            .sorted { $0.path < $1.path } ?? []
        let engine = SeeUConversationEngine()
        let session = UUID(), epoch = UUID()
        var byTitle: [String: UUID] = [:]
        for (position, url) in files.enumerated() {
            guard let output = try await engine.process(
                jpeg: try Data(contentsOf: url), frameID: UUID(), sessionID: session,
                capturedAt: Date(timeIntervalSince1970: Double(position) * 0.4),
                exclusion: .none, epoch: epoch) else { continue }
            let update = output.update
            guard update.detection == .chat, let title = update.title,
                  let id = update.conversationID else { continue }
            if let seen = byTitle[title] {
                XCTAssertEqual(id, seen, "标题「\(title)」的两帧拿到了不同的会话 id")
            } else {
                byTitle[title] = id
            }
        }
        XCTAssertGreaterThanOrEqual(byTitle.count, 2, "数据集里应至少有两个能读出标题的聊天")
    }
}
