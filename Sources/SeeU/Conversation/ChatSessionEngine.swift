import CoreGraphics
import Foundation

/// 屏幕帧 → 聊天会话的后台引擎。
///
/// actor 串行化所有状态；Vision 识别在自己的队列里跑，await 期间不占用 actor。
/// 采集会话切换时自动重置，旧会话的帧在 OCR 返回后被丢弃，不会写进新会话。
public actor ChatSessionEngine {
    private let limits: SeeUImageLimits

    public init(limits: SeeUImageLimits = .init()) { self.limits = limits }

    private let recognizer = ChatFrameRecognizer()
    private let stitcher = ChatStitcher()
    private var anchors = LayoutAnchors()
    private var epoch: UUID?
    private var currentMessages: [LiveMessage] = []
    private var currentFrameItems: [SeeUConversationItem] = []
    private var currentHistoryIDs: Set<UUID> = []

    private var sessionID: UUID?
    private var frameSize: CGSize?

    private var inChat = false
    private var chatStreak = 0
    private var nonChatStreak = 0
    private var interrupted = false
    private var lastRejectReason = "不是聊天页"

    private var conversationID: UUID?
    private var conversationTitle: String?
    /// 规范化标题 → 会话 id。切走再切回来时沿用同一个 id。
    private var conversationIdentities: [String: UUID] = [:]
    /// 上面字典的访问顺序，用来淘汰久未使用的会话。
    private var conversationIdentityOrder: [String] = []
    /// 片段 → 所属会话。段不随会话切换清掉，所以要记住它归谁。
    private var segmentOwner: [UUID: UUID] = [:]
    /// 不在前台的会话各自的段链，切回来时恢复。当前会话的链在拼接器里。
    private var chains: [UUID: [UUID]] = [:]
    /// 最多记住多少个会话的身份。
    static let rememberedConversations = 8
    private var confirmed = false
    private var pendingTitle: (title: String, count: Int)?
    private var revision = 0
    private var contentHash = 0

    private var framesProcessed = 0
    private var framesSkipped = 0

    public func clear() {
        resetConversation()
        sessionID = nil
        frameSize = nil
        inChat = false
        chatStreak = 0
        nonChatStreak = 0
        framesProcessed = 0
        framesSkipped = 0
        epoch = nil
    }

    /// 处理一帧。画中画标记必须组成版式一致的多行簇，才用于排除自己的界面。
    public func process(
        jpeg: Data, frameID: UUID, sessionID frameSession: UUID, capturedAt: Date,
        exclusion: FrameExclusionPolicy = .none, epoch frameEpoch: UUID
    ) async throws -> EngineOutput? {
        if epoch != frameEpoch || sessionID != frameSession {
            clear()
            sessionID = frameSession
            epoch = frameEpoch
        }
        let recognized = try await recognizer.recognize(jpeg: jpeg, frameID: frameID, capturedAt: capturedAt,
                                                          anchors: anchors, currentTitle: conversationTitle,
                                                          exclusion: exclusion, limits: limits)
        guard sessionID == frameSession, epoch == frameEpoch else { return nil }
        let bitmap = recognized.bitmap
        currentFrameItems = []
        var parsed = recognized.parsed
        let ocrMs = recognized.ocrMilliseconds
        if let frameSize, frameSize != bitmap.size {
            // 旋转或分辨率变化后像素坐标不可比，重新开始。
            resetConversation()
            anchors = LayoutAnchors()
            inChat = false
            chatStreak = 0
        }
        frameSize = bitmap.size

        framesProcessed += 1
        // 整屏都是图片、一条文字消息都没有：只要标题还是这个会话，就是同一个聊天页，不能切断会话。
        if !parsed.isChat, inChat, parsed.messageBubbles.isEmpty, conversationID != nil,
           continuesConversation(parsed) {
            parsed = parsed.continuingChat(reason: "这一屏没有文字消息（可能都是图片）")
        }

        guard parsed.isChat else {
            lastRejectReason = parsed.rejectReason ?? "不是聊天页"
            currentMessages = []
            return EngineOutput(update: nonChatFrame(frameID: frameID, reason: lastRejectReason, skipped: false, ocrMs: ocrMs), longScreenshot: nil)
        }
        nonChatStreak = 0
        chatStreak += 1
        inChat = true

        // 会话身份：标题稳定变化两帧才切换，防止单帧 OCR 误读把整段记录清掉。
        let title = ChatLayoutParser.isTransientTitle(parsed.title) ? nil : parsed.title
        if conversationID == nil {
            startConversation(title: title)
        } else if let title, let current = conversationTitle,
                  TextMatch.similarity(TextMatch.normalize(title), TextMatch.normalize(current)) < 0.6 {
            // 标题相同时累加。用相似度而不是全等：OCR 可能把同一个标题读成两种写法，
            // 全等会让计数每帧归零，会话永远切不过去。
            if let pending = pendingTitle,
               TextMatch.similarity(TextMatch.normalize(pending.title), TextMatch.normalize(title)) >= 0.75 {
                pendingTitle = (pending.count >= 2 ? pending.title : title, pending.count + 1)
            } else {
                pendingTitle = (title, 1)
            }
            // 标题变了但要连续两帧才确认。确认不够时**照常按原会话拼接**：直接丢弃这一帧
            // 会让画面抖动/键盘弹起时的文字白丢，返回 .waiting 还会让上层清空上下文。
            // 内容接不上时拼接器自己会另起孤立片段，不会污染原会话。
            if (pendingTitle?.count ?? 0) >= 2 { startConversation(title: title) }
        } else if conversationTitle == nil, let title {
            // 无名会话第一次读到标题：切到这个标题的身份（认识就切回去，不认识就新建），
            // 不能把无名会话原地改名。无名期间的画面可能是别的 App 页面，不能记到这个人头上；
            // 它的片段归属随机 id，切走后即被回收；这一帧本身照常拼进新身份的链。
            startConversation(title: title)
        } else {
            // 回到聊天页但标题没读出来：沿用原来的会话。像素对齐不能拿上一帧当参考，
            // 内容接不上时只会另起孤立片段，等标题读出来再按上面的两帧规则切换。
            pendingTitle = nil
        }
        if chatStreak >= 2 || parsed.hasReliableSingleFrameEvidence { confirmed = true }
        interrupted = false

        // 只能认领同一会话的片段。没登记过归属的片段（会话刚建立的首帧）视为本会话的。
        let owner = conversationID
        let placement = stitcher.ingest(parsed, bitmap: bitmap) { [segmentOwner] segment in
            guard let recorded = segmentOwner[segment] else { return true }
            return recorded == owner
        }
        // 记住这一段归谁：片段不随会话切换清掉，`rejoin` 时要能认出来。
        if let placement, let conversationID { segmentOwner[placement.segmentID] = conversationID }
        // 会话身份被淘汰后，它留下的片段不会再有人回来认领，回收掉。
        // 当前会话本身也算活跃：无名会话的 id 不在标题映射里，但它自己的段不能被回收。
        let active = Set(conversationIdentities.values).union(conversationID.map { [$0] } ?? [])
        if segmentOwner.values.contains(where: { !active.contains($0) }) {
            segmentOwner = segmentOwner.filter { active.contains($0.value) }
            chains = chains.filter { active.contains($0.key) }
            // 当前这一帧的段归属刚记上，一定在保留集合里。
            stitcher.keepSegments(Set(segmentOwner.keys))
        }
        var usedIDs = Set<UUID>()
        var usedEntryIDs = Set<UUID>()
        var matchedHistoryIDs = Set<UUID>()
        let previousMessages = currentMessages
        currentMessages = parsed.messageBubbles.enumerated().map { index, bubble in
            let normalized = TextMatch.normalize(bubble.text)
            let shift = placement?.offset ?? 0
            let candidates = stitcher.currentSegment?.entries.filter {
                $0.kind == .message && !usedEntryIDs.contains($0.id)
            } ?? []
            let byText = candidates.filter {
                ($0.side == bubble.side || $0.side == .unknown || bubble.side == .unknown)
                    && abs($0.top - bubble.rect.minY - shift) < max(14, bubble.rect.height)
                    && TextMatch.similarity($0.normalized, normalized) >= 0.7
            }
            // 文字没对上时按槽位认回历史条目，否则 OCR 抖动会让当前屏看起来“接不上”历史。
            let bySlot = placement == nil ? [] : candidates.filter {
                ChatStitcher.sameSlot($0, top: bubble.rect.minY + shift, bottom: bubble.rect.maxY + shift,
                                      minX: bubble.rect.minX, maxX: bubble.rect.maxX, side: bubble.side,
                                      sideConfidence: bubble.sideConfidence, clipped: bubble.clipped)
            }
            let entry = (byText.isEmpty ? bySlot : byText)
                .min { abs($0.top - bubble.rect.minY - shift) < abs($1.top - bubble.rect.minY - shift) }
            let prior = previousMessages.enumerated().filter {
                !usedIDs.contains($0.element.id) && $0.element.side == bubble.side
                    && TextMatch.similarity(TextMatch.normalize($0.element.text), normalized) >= 0.7
            }.min { abs($0.offset - index) < abs($1.offset - index) }?.element
            let sameSequence = previousMessages.count == parsed.messageBubbles.count
                && previousMessages.indices.contains(index)
                && TextMatch.normalize(previousMessages[index].text) == normalized
                && previousMessages[index].side == bubble.side
                && !usedIDs.contains(previousMessages[index].id)
            let id = sameSequence ? previousMessages[index].id : (entry?.id ?? prior?.id ?? UUID())
            usedIDs.insert(id)
            if let entry {
                usedEntryIDs.insert(entry.id)
                matchedHistoryIDs.insert(entry.id)
            }
            return LiveMessage(id: id, kind: .message,
                        side: bubble.side, sideConfidence: bubble.sideConfidence,
                        text: entry.map { $0.clipped && !bubble.clipped ? bubble.text : $0.text } ?? bubble.text,
                        senderName: bubble.senderName, quote: bubble.quote,
                        observations: entry?.observations ?? ((prior?.observations ?? 0) + 1), clipped: bubble.clipped,
                        sources: [SeeUObservation(frame: parsed, bubble: bubble)])
        }
        currentHistoryIDs = matchedHistoryIDs
        var messageIndex = 0
        currentFrameItems = parsed.bubbles.map { bubble in
            let message: LiveMessage
            if bubble.kind == .message {
                message = currentMessages[messageIndex]
                messageIndex += 1
            } else {
                message = LiveMessage(id: UUID(), kind: bubble.kind, side: bubble.side,
                                      sideConfidence: bubble.sideConfidence, text: bubble.text,
                                      senderName: bubble.senderName, quote: bubble.quote,
                                      observations: 1, clipped: bubble.clipped,
                                      sources: [SeeUObservation(frame: parsed, bubble: bubble)])
            }
            return SeeUConversationItem(message)
        }
        let screenshotInput: LongScreenshotInput? = placement.map {
            LongScreenshotInput(epoch: frameEpoch, sessionID: frameSession, conversationID: conversationID,
                                frameID: frameID, bitmap: bitmap, parsed: parsed,
                                messageIDs: currentFrameItems.map { $0.kind == .message ? $0.id : nil },
                                placement: $0,
                                activeSegmentIDs: Set(stitcher.segments.map(\.id)), preferredSegmentID: $0.segmentID)
        }
        anchors.record(parsed)

        let detection: EngineUpdate.Detection = currentMessages.isEmpty ? .waiting : .chat
        return EngineOutput(update: makeUpdate(frameID: frameID, detection: detection, placement: placement?.kind, skipped: false, ocrMs: ocrMs), longScreenshot: screenshotInput)
    }

    // MARK: - 内部

    /// 无文字消息的帧必须仍看得清同一个标题，不能仅凭上帧还在聊天页继续沿用。
    private func continuesConversation(_ parsed: ParsedChatFrame) -> Bool {
        guard let current = conversationTitle,
              let title = parsed.title,
              !ChatLayoutParser.isTransientTitle(title) else { return false }
        return TextMatch.similarity(TextMatch.normalize(title), TextMatch.normalize(current)) >= 0.6
    }

    private func nonChatFrame(frameID: UUID, reason: String, skipped: Bool, ocrMs: Int) -> EngineUpdate {
        nonChatStreak += 1
        chatStreak = 0
        if inChat && nonChatStreak >= 2 {
            inChat = false
            interrupted = true
            stitcher.markInterrupted()
            // 只闪了一下、从未确认的会话不保留。
            if !confirmed { resetConversation() }
        }
        let detection: EngineUpdate.Detection = inChat ? .waiting : .notChat(reason: reason)
        return makeUpdate(frameID: frameID, detection: detection, placement: nil, skipped: skipped, ocrMs: ocrMs)
    }

    private func startConversation(title: String?) {
        // 切会话**不重置拼接器**：片段保留，切回来时画面文字能接上自己的旧段（rejoin），
        // 历史不用重新攒。链按会话各存一条（链首 = 含最新消息的段）。
        let next = identity(for: title)
        if let previous = conversationID, previous != next { chains[previous] = stitcher.chain }
        let incoming = chains.removeValue(forKey: next) ?? []
        // 别的会话的段：包括它们暂存的链，以及登记在它们名下、但不在链上的孤立段。
        let parked = Set(segmentOwner.filter { $0.value != next }.keys)
            .union(chains.values.flatMap { $0 })
        stitcher.switchChain(to: incoming, parked: parked)
        currentMessages = []
        currentHistoryIDs = []
        currentFrameItems = []
        anchors = LayoutAnchors()
        conversationID = next
        conversationTitle = title
        confirmed = false
        pendingTitle = nil
        interrupted = false
        contentHash = 0
        revision += 1
    }

    /// 会话身份按标题稳定映射。同一个标题永远得到同一个 `conversationID`，
    /// A→B→A 切回来还是原来的 id，上层的记录归属和联系人绑定不会断。
    ///
    /// 标题读不出来时（nil）退回随机 id：那说明这一帧无法确认是谁，不能瞎认领。
    private func identity(for title: String?) -> UUID {
        guard let title, !ChatLayoutParser.isTransientTitle(title) else { return UUID() }
        let key = TextMatch.normalize(title)
        guard !key.isEmpty else { return UUID() }
        if let existing = conversationIdentities[key] {
            conversationIdentityOrder.removeAll { $0 == key }
            conversationIdentityOrder.append(key)
            return existing
        }
        let id = UUID()
        conversationIdentities[key] = id
        conversationIdentityOrder.append(key)
        // 只记最近用过的若干个会话，多了会一直占内存。被淘汰的会话下次当新会话看待。
        while conversationIdentityOrder.count > Self.rememberedConversations {
            let dropped = conversationIdentityOrder.removeFirst()
            if let evicted = conversationIdentities.removeValue(forKey: dropped) {
                segmentOwner = segmentOwner.filter { $0.value != evicted }
                chains[evicted] = nil
            }
        }
        return id
    }

    private func resetConversation() {
        stitcher.reset()
        conversationIdentities.removeAll()
        conversationIdentityOrder.removeAll()
        segmentOwner.removeAll()
        chains.removeAll()
        currentMessages = []
        currentHistoryIDs = []
        currentFrameItems = []
        anchors = LayoutAnchors()
        conversationID = nil
        conversationTitle = nil
        confirmed = false
        pendingTitle = nil
        interrupted = false
        contentHash = 0
        revision += 1
    }

    private func makeUpdate(
        frameID: UUID, detection: EngineUpdate.Detection, placement: StitchPlacement.Kind?, skipped: Bool, ocrMs: Int
    ) -> EngineUpdate {
        let chain = stitcher.chain
        let summaries = stitcher.segments.map { segment in
            LiveSegmentSummary(
                id: segment.id, isLive: segment.isLive,
                // 只把文字确认过的消息交给对话列表和分析：画面位移放进来的图片小字不进上下文。
                messages: segment.entries.filter(\.textConfirmed).map(Self.message),
                imageSpan: 0,
                rungCount: 0,
                chainIndex: chain.firstIndex(of: segment.id)
            )
        }
        let isolated = summaries.first { $0.id == stitcher.currentSegmentID && $0.chainIndex == nil }
        // 未对齐的新屏独立分析，不能让旧链的签名替代当前可读内容、持续续期旧候选。
        // 已在链内时仍沿用最新消息，向上滚动只补历史上下文。
        // 链按会话切换（`switchChain`），所以这里的链只含本会话的段。
        let contextIDs = isolated.map { [$0.id] } ?? Array(chain.reversed())
        var live: [LiveMessage] = []
        for id in contextIDs {
            guard let segment = summaries.first(where: { $0.id == id }) else { continue }
            if !live.isEmpty {
                live.append(LiveMessage(
                    id: segment.id, kind: .gap, side: .unknown, sideConfidence: 0,
                    text: "中间有未识别的聊天记录", senderName: nil, quote: nil, observations: 0, clipped: false
                ))
            }
            live += segment.messages
        }
        let currentTailMissing = currentMessages.last.map { tail in
            !live.contains {
                $0.id == tail.id || (currentHistoryIDs.contains($0.id) && $0.side == tail.side && $0.kind == .message
                    && TextMatch.normalize($0.text) == TextMatch.normalize(tail.text))
            }
        } ?? true
        if currentTailMissing { live = currentMessages }
        var hasher = Hasher()
        hasher.combine(conversationID)
        for message in live where message.kind != .gap {
            hasher.combine(message.kind.rawValue)
            hasher.combine(message.side.rawValue)
            hasher.combine(TextMatch.normalize(message.text))
            hasher.combine(message.quote)
        }
        let hash = hasher.finalize()
        if hash != contentHash {
            contentHash = hash
            revision += 1
        }
        let update = EngineUpdate(
            sessionID: sessionID ?? UUID(),
            frameID: frameID,
            detection: detection,
            confirmed: confirmed,
            conversationID: conversationID,
            title: conversationTitle,
            revision: revision,
            segments: summaries,
            currentMessages: currentMessages,
            contextMessages: live,
            liveMessages: live,
            currentContextIsIsolated: isolated != nil || currentTailMissing,
            currentSegmentIsLive: stitcher.currentSegment?.isLive ?? false,
            viewingLiveTail: stitcher.isViewingLiveTail,
            placement: placement,
            skippedUnchanged: skipped,
            ocrMilliseconds: ocrMs,
            framesProcessed: framesProcessed,
            framesSkipped: framesSkipped,
            currentFrameItems: currentFrameItems
        )
        return update
    }

    private static func message(_ entry: TranscriptEntry) -> LiveMessage {
        LiveMessage(
            id: entry.id, kind: entry.kind, side: entry.side, sideConfidence: entry.sideConfidence, text: entry.text,
            senderName: entry.senderName, quote: entry.quote, observations: entry.observations, clipped: entry.clipped,
            sources: entry.sources
        )
    }
}
