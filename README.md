# SeeU

独立的 iOS 截图 OCR、聊天版式识别、跨帧消息合并与长图拼接库。仅使用 Apple
Vision、CoreGraphics、ImageIO；不依赖采集框架、模型网关、Realm 或联系人业务。

Swift Package 使用 tools-version 6.2（源码使用类型级 nonisolated）、Swift 5 语言模式，
最低 iOS 16，不继承宿主 App 的默认 MainActor 隔离。主要入口：

- SeeUConversationEngine：单屏 OCR 与文字会话，process 是 async throws。
- EngineUpdate.conversation：SeeUConversation 值对象，jsonData() 输出 schemaVersion 1 JSON。
- SeeULongScreenshotStore：独立 actor 保存图片条带并导出 JPEG，不参与文字分析。
- SeeUImageStitcher：不依赖 OCR 的通用纵向图片拼接，直接接收图片和可选几何区域。
- FrameExclusionPolicy：宿主每帧传入不可变遮挡规则，默认不排除任何宿主 UI。

## 目录与职责

```text
Sources/SeeU/
├── SeeU.swift                         # 对外入口别名
├── Recognition/                      # 单帧识别与文本处理
│   ├── OCR/                          # Vision OCR、文字行、宿主排除策略
│   ├── ChatLayout/                   # 聊天版式、气泡、布局锚点与识别证据
│   └── Text/                         # 文本规范化和相似度匹配
├── Conversation/                     # 会话状态、跨帧消息合并、上下文与 JSON
├── Stitching/                        # 通用图像对齐、拼接入口和条带合成
└── ImageManagement/                  # 位图解码、取色、编码、图片预算
    └── ChatStorage/                  # 聊天图片存储、10 条带策略、头尾装饰

Tests/SeeUTests/
├── Recognition/
├── Conversation/
├── Stitching/
└── ImageManagement/
```

`OCRModels.swift` 原先混放的类型已按职责拆开：`OCRLine` 和排除策略属于 OCR，
气泡、`ParsedChatFrame`、`SeeUObservation` 属于聊天版式；`EngineOutput` 和会话快照
属于 Conversation；`LongScreenshotInput/Merge` 属于 ChatStorage。图片限制与错误类型
放在 `ImageManagement/ImageLimits.swift`，根入口不再承载这些模型。

通用 `Stitching` 仅使用图片基础能力，不依赖 OCR 或聊天会话；`Recognition` 依赖图片
解码和取色，输出单帧观察；`Conversation` 消费观察并调用图像对齐，产出文字上下文和
图片放置信息；`ChatStorage` 消费这些信息，调用通用合成并执行聊天保留策略。
这里的 ChatStorage 明确是业务适配，不是供底层依赖的通用缓存。

这些文件夹是同一 `SeeU` target 内的职责边界，不是独立编译模块。Swift Package 自动
递归发现源文件，宿主继续 `import SeeU`；公开类型名、访问权限和调用签名保持不变。
本次整理只移动完整实现、拆分模型，不调整识别或拼接算法。测试目录同步分类，原
`SeeUTests` 测试类拆为 `ConversationTests`、`RecognitionTests` 和 `ImageLimitsTests`；
如宿主 Scheme 配置了测试类过滤器，应同步选择新类。

## 通用图片拼接（不运行 OCR）

`ImageAligner` 负责局部像素匹配，`ImageStripCanvas` 负责无损条带与接缝合成。
聊天页判断、会话、保留 10 条带及页面头尾属于 `ChatSessionEngine` / `ChatLadder`
业务适配；普通图片入口不依赖这些规则。现有聊天 API 保持兼容，也使用新的图像匹配和合成。

```swift
let stitcher = SeeUImageStitcher()
for data in screenshots {
    let result = try await stitcher.ingest(data)
    if result.status == .unmatched {
        // 本帧未接入，已有图和参考帧保持不变。由业务提示补图或另开一段。
        break
    }
}
let png = await stitcher.renderPNG(maxPixelHeight: 16_000)
// 也可最终只编码一次 JPEG：
let jpeg = await stitcher.renderJPEG(maxPixelHeight: 16_000, quality: 0.92)
```

同一实例按序 await 输入，换页面或开始新批次调用 `reset()`。需要裁去固定工具栏或
排除浮窗时，传 `ImageStitchRegion(rect: ..., exclusions: [...])`，坐标为原图像素、
左上原点。默认整图匹配和合成；算法验证过的移动区域用于约束接缝，避免无关顶底栏主导选缝。
无来源覆盖的遮挡区域显示中性空缺；不会恢复被遮挡且从未采到的内容。

对齐会抑制同位置不变的壁纸像素，要求多个局部块支持相同位移，并在原像素网格上搜索、
用独立的密集 RGB 采样复核。`alignment.offset` 满足“当前图 y + offset = 上一图 y”；
`ImageStitchUpdate.offset` 是当前图到累计画布的偏移。`score` 是匹配评分，不是成功概率。
输出区分 `started / appended / unchanged / unmatched`；失败原因保留在 `alignment.reason`。

目标是滚动内容完整连续，固定照片壁纸可以在接缝处跳变。只支持同宽图片的纵向平移，
不处理旋转、缩放、横移和透视。低纹理、重复内容、动态加载或没有可靠重叠时可能返回
`unmatched`；应在画面稳定后采图，不用预测方向强行消除歧义。

通用入口不设 10 条带上限，也不自动删历史来满足资源预算。无损 PNG 条带默认预算为
128 MiB（`maximumStoredBytes`），预算内替换旧来源；增长超限或编码失败显式抛错，
旧图保持不变。预算不包含解码、匹配和导出的临时位图内存。输出限制为 2400 万像素及
调用方指定高度，超限等比缩小；需要完整长图原尺寸归档时由宿主另行设计分片导出。

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

聊天适配每段默认保留 10 个条带，属于有界短期存档；该策略不适用于通用图片入口。
两条路径均保存无损 PNG 条带，最终导出 JPEG 时只做一次有损编码。
取消或切换采集会话后，调用方仍须校验任务世代再发布结果。

## 验证

XCTest 源码覆盖固定壁纸下正反向位移、静止与未知、重复纹理歧义、ROI/遮挡、有效像素
覆盖、旧来源不能删除较新内容、接缝连续性、预算原子性、无 OCR 公共入口，以及原有
JSON、时间标记与图片预算。按项目规则未运行 Swift 编译或 XCTest，请在 Xcode 中执行。

可在 Xcode 测试 Scheme 环境变量中设置 `SEEU_ALIGNMENT_FIXTURE_DIRECTORY` 指向本地
截图目录（包含 `IMG_3253.PNG`、`IMG_3252.PNG`），运行可选真实样本测试，期望正向
1499 像素、反向 -1499 像素。`SEEU_STITCH_OUTPUT_PATH` 可指定公共入口测试的 PNG
导出位置。私人截图不放入仓库。

`Scripts/verify_image_alignment.py` 是独立 Python 算法模型，用于不编译 iOS 时复核样本；
需要运行环境已有 Pillow/numpy。它验证算法思路，不能替代 Swift 实现的 XCTest 或真机性能验证。
还应在 Xcode 中检查聊天跨段合并、键盘开关、PiP 变化、会话切换和长图导出。
