# SeeU

独立的 iOS 截图 OCR、聊天版式识别、跨帧消息合并与长图拼接库。仅使用 Apple
Vision、CoreGraphics、ImageIO；不依赖采集框架、模型网关、Realm 或联系人业务。

Swift Package 使用 tools-version 6.2（源码使用类型级 nonisolated）、Swift 5 语言模式，
最低 iOS 16，不继承宿主 App 的默认 MainActor 隔离。主要入口：

- SeeUConversationEngine：单屏 OCR 与文字会话，process 是 async throws。
- EngineUpdate.conversation：SeeUConversation 值对象，jsonData() 输出 schemaVersion 1 JSON。
- SeeULongScreenshotStore：独立 actor 保存图片条带并导出 JPEG，不参与文字分析。
- FrameExclusionPolicy：宿主每帧传入不可变遮挡规则，默认不排除任何宿主 UI。

## 单张与顺序批次

单张截图也调用 process；清晰的单屏证据可立即确认会话。顺序批次按下面方式逐张 await，
不要套用实时采集的“仅保留最新帧”队列。每个引擎同时只由一个顺序生产者调用；相同
sessionID/epoch 的并发调用不提供排序保证。换采集会话时换 ID 和 epoch。

```swift
import SeeU

let engine = SeeUConversationEngine()
let images = SeeULongScreenshotStore()
let session = UUID(), epoch = UUID()
await images.reset(to: epoch)

// screenshots: [Data]，单张时数组只有一个元素。
for data in screenshots {
    guard let output = try await engine.process(
        jpeg: data, frameID: UUID(), sessionID: session,
        capturedAt: Date(), epoch: epoch
    ) else { continue } // 被新采集会话淘汰

    let json = try output.update.conversation.jsonData(prettyPrinted: true)
    consumeConversation(json) // 先处理文本；这是调用方自己的函数

    if let input = output.longScreenshot {
        let merges = input.placement.merged.map {
            LongScreenshotMerge(conversationID: input.conversationID,
                                sourceID: $0.id, targetID: input.placement.segmentID, shift: $0.shift)
        }
        await images.ingest(input, merges: merges)
    }
}
let jpeg = await images.render(maxPixelHeight: 16_000)
```

上例选择逐张保存长图以保证手动批次没有图片丢失。实时采集可在消费文本后交给独立图片
队列；图片可覆盖，placement.merged 事件必须按序累计，不能随图片覆盖。reset 必须先于
新世代 ingest 完成；render 返回当前首选片段，不能把无可靠重叠的片段强拼成长图。

## 输出语义

schemaVersion 1 包含采集会话、识别会话实例、帧、版本、标题候选、识别状态、独立片段、
currentItems（本帧，包括时间标记）及 contextItems（已对齐上下文）。
条目保留 message/time/gap、me/other/unknown、原文、昵称候选、引用、裁切、
发言方向置信度与 OCR 观察证据。gap 的 text 为 nil，不写入提示词。
片段 chainIndex 为 nil 时不推断顺序；数字 0 表示最新段。
confirmed 仅表示聊天版式证据已确认，不表示联系人已确认。
waiting/notChat 时可能保留上一会话历史，调用方应检查 detection 和 confirmed 后再触发分析。

OCR 证据的坐标是原图像素、左上原点；recognitionConfidence 与 sideConfidence 含义不同。
observedAt 是图片采集时间，时间分隔线保留原文，不推断消息发送时间。历史消息最多
保留最近三次来源证据，避免重复采集无限增长。标题和昵称仅是候选，绝不是联系人主键；
联系人、人设、情绪分析和历史持久化由上层负责。

## 当前边界

版式算法沿用现有中文微信风格竖屏聊天页启发式，不保证所有聊天 App 和任意长图版式。
默认限制编码 20 MiB、800 万像素、单边 16000 像素，在解码前检查；超预算显式抛错，
不自动缩图或把失败伪装成空 OCR。支持 ImageIO 可解码的直立图片（接口 jpeg 标签
为已有调用兼容保留）；带旋转 EXIF 标记的照片拒绝处理，需调用方先归一化。
超长输入切片尚未实现，建议按原始屏幕截图依次输入。

长图每段默认保留 10 个条带，导出同时限制为 2400 万像素，超过时等比缩小，
属于有界短期存档，不是完整历史数据库。
取消或切换采集会话后，调用方仍须校验任务世代再发布结果。

## 验证

附 XCTest 源码覆盖 JSON、缺口、时间标记、无宿主遮挡策略及图片预算。本次仅静态检查，
未运行编译或测试；由使用者在 Xcode 中验证包目标、测试与中文 OCR、跨段合并、PiP
尺寸变化、切换会话、超限图片、长图导出等真机流程。
