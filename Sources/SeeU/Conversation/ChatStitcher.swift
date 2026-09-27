import CoreGraphics
import Foundation

/// 聊天业务适配：优先使用通用图像对齐，文字匹配补充消息身份和跨片段重连。
///
/// 规则对应架构文档 §6.2：
/// - 同一画面重复出现不新增消息；
/// - 有可靠重叠时只补新增部分（向上翻补历史，向下补新消息）；
/// - 没有重叠时另起一段并标记缺口，不追加到最新消息尾部；
/// - 相同文字出现在不同位置保留两条，不做全局字符串去重。
///
/// 图像匹配不依赖聊天语义；会话、片段顺序和文字确认仍由本层管理。
nonisolated final class ChatStitcher {
    private struct Last {
        let segmentID: UUID
        let offset: CGFloat
        let bitmap: FrameBitmap
        let region: ImageStitchRegion
        let top: CGFloat
        let bottom: CGFloat
        /// 本帧相对上一帧的滚动量（帧坐标，正 = 内容上移 = 在看更新的消息）。
        let scrollDelta: CGFloat
    }

    private(set) var segments: [TranscriptSegment] = []
    private(set) var currentSegmentID: UUID?
    /// 段链：链首含最新消息，依次更早。只有链上的段会带来分析上下文。
    private(set) var chain: [UUID] = []
    private var last: Last?
    private var lastCaptureAt = Date.distantPast
    /// 最近一次 offset 估计中有多少条不同消息被文字印证。
    private var lastVotes = 0
    /// 最近一帧的位置是文字证据给的，还是只靠画面位移估的。
    private var lastPlacementFromText = false
    /// 最近一帧的文字偏移和画面位移互相印证（两套独立证据一致）。
    private var lastOffsetCorroborated = false

    /// 相邻两帧间隔超过这个时间就认为中间可能有没截到的内容。
    static let continuityWindow: TimeInterval = 3

    static let maxSegments = 6
    /// 每段最多保留的条目数。超出时丢掉离当前画面最远的一端。
    static let maxEntriesPerSegment = 400

    var currentSegment: TranscriptSegment? {
        segments.first { $0.id == currentSegmentID }
    }

    var liveSegment: TranscriptSegment? {
        segments.first { $0.isLive }
    }

    func reset() {
        segments = []
        chain = []
        currentSegmentID = nil
        last = nil
    }

    /// 链上的段按“从最新到最早”排列。
    var chainedSegments: [TranscriptSegment] {
        chain.compactMap { id in segments.first { $0.id == id } }
    }

    private func refreshLiveFlags() {
        let liveID = chain.first
        for i in segments.indices { segments[i].isLive = segments[i].id == liveID }
    }

    /// 离开聊天页后回来：保留片段，但上一帧不能再作为像素微调参考。
    func markInterrupted() {
        last = nil
        lastCaptureAt = .distantPast
    }

    func ingest(_ frame: ParsedChatFrame, bitmap: FrameBitmap) -> StitchPlacement? {
        let region = ImageStitchRegion(
            rect: CGRect(x: 0, y: frame.contentTop, width: CGFloat(bitmap.width),
                         height: frame.contentBottom - frame.contentTop), exclusions: frame.occluders
        )
        let previous = last
        // 和上一帧差不多是连续的（同一会话、间隔很短）。
        let continuous = previous.map {
            frame.capturedAt.timeIntervalSince(lastCaptureAt) < Self.continuityWindow
                && $0.bitmap.width == bitmap.width && $0.bitmap.height == bitmap.height
        } ?? false

        var kind: StitchPlacement.Kind = .extended
        var target: UUID?
        var offset: CGFloat = 0
        lastPlacementFromText = false
        lastOffsetCorroborated = false

        // 时间窗口只决定业务上的滚动方向连续性，不限制两张截图能否进行图像匹配。
        var visual: ImageAlignment?
        var usedMotion = false
        if let previous, previous.bitmap.size == bitmap.size {
            visual = ImageAligner.align(previous: previous.bitmap, current: bitmap,
                                        previousRegion: previous.region, currentRegion: region,
                                        hint: continuous ? previous.scrollDelta : nil)
        }
        let motionShift: CGFloat? = visual.flatMap { $0.status == .unmatched ? nil : $0.offset }
        if let previous, let shift = motionShift,
           let index = segments.firstIndex(where: { $0.id == previous.segmentID }) {
            target = previous.segmentID
            offset = previous.offset + shift
            usedMotion = true
            // 图像定位不受 OCR 文字框抖动影响，文字只决定这批消息能否立即确认。
            if let textOffset = estimateOffset(frame.bubbles, into: segments[index], hint: offset,
                                               occluders: frame.occluders, motionOffset: offset),
               abs(textOffset - offset) <= 4 {
                lastPlacementFromText = true
                usedMotion = false
            }
        } else if let previous, continuous, let index = segments.firstIndex(where: { $0.id == previous.segmentID }),
           !frame.messageBubbles.isEmpty,
           var found = estimateOffset(frame.bubbles, into: segments[index], hint: previous.offset,
                                      occluders: frame.occluders) {
            found = refine(found, frame: frame, bitmap: bitmap, previous: previous)
            target = previous.segmentID
            offset = found
            lastPlacementFromText = lastVotes >= 1 || lastOffsetCorroborated
        }
        if target == nil, !frame.messageBubbles.isEmpty,
           let (index, found) = bestOtherSegment(frame.bubbles, excluding: continuous ? currentSegmentID : nil,
                                                occluders: frame.occluders) {
            kind = .rejoined
            target = segments[index].id
            offset = found
            lastPlacementFromText = true
        }
        guard let target else {
            // 没有文字也没有可靠位移时既不造空段，也不把未知位置写入长图。
            guard !frame.messageBubbles.isEmpty else {
                markInterrupted()
                return nil
            }
            // 完全接不上：另起一段。按上一帧相对上一段的位置判断新的一段更早还是更新，接到链上。
            let direction: CGFloat? = continuous
                ? motionShift ?? previous.map(\.scrollDelta) : nil
            return startSegment(frame: frame, bitmap: bitmap, previous: previous, region: region,
                                direction: direction)
        }
        guard let index = segments.firstIndex(where: { $0.id == target }) else { return nil }

        let scrollDelta: CGFloat? = {
            guard let previous, previous.segmentID == target, kind == .extended else { return nil }
            return offset - previous.offset
        }()
        let changed = frame.messageBubbles.isEmpty ? false
            : merge(frame, offset: offset, into: index, textBacked: lastPlacementFromText && !usedMotion)
        currentSegmentID = target
        lastCaptureAt = frame.capturedAt
        last = Last(segmentID: target, offset: offset, bitmap: bitmap, region: region,
                    top: frame.contentTop, bottom: frame.contentBottom, scrollDelta: scrollDelta ?? 0)

        let merged = absorbOverlappingSegments(
            into: target, viewTop: frame.contentTop + offset, viewBottom: frame.contentBottom + offset
        )
        return StitchPlacement(
            kind: kind, segmentID: target, chainIndex: chain.firstIndex(of: target) ?? chain.count,
            offset: offset, scrollDelta: scrollDelta, merged: merged, changed: changed || !merged.isEmpty,
            matchingRange: visual?.status == .matched ? visual?.matchingRange : nil
        )
    }

    /// 接不上时另起一段，并按上一帧的位置把它接到链的更早或更新一端。
    private func startSegment(
        frame: ParsedChatFrame, bitmap: FrameBitmap, previous: Last?, region: ImageStitchRegion, direction: CGFloat?
    ) -> StitchPlacement? {
        let segment = TranscriptSegment(id: UUID(), isLive: false, createdAt: frame.capturedAt)
        segments.append(segment)
        if segments.count > Self.maxSegments {
            // 优先丢掉没接进链的段；都接上了就丢链尾（最早的一段）。
            let unlinked = segments.first { !chain.contains($0.id) && $0.id != segment.id }
            if let unlinked {
                segments.removeAll { $0.id == unlinked.id }
            } else if chain.count > 1 {
                // 保留前驱供方向定位，先取 ID，再执行不修改链的谓词。
                if let droppedID = chain.reversed().first(where: { $0 != previous?.segmentID && $0 != chain.first }) {
                    chain.removeAll { $0 == droppedID }
                    segments.removeAll { $0.id == droppedID }
                }
            }
        }
        if chain.isEmpty {
            chain.append(segment.id)
        } else if let previous, let position = chain.firstIndex(of: previous.segmentID),
                  let direction, abs(direction) > 8 {
            chain.insert(segment.id, at: direction < 0 ? position + 1 : position)
        }
        // 方向未知则保留孤立段；等后续文字重叠再并入，不假定它更新或更早。
        refreshLiveFlags()
        currentSegmentID = segment.id
        lastCaptureAt = frame.capturedAt
        last = Last(segmentID: segment.id, offset: 0, bitmap: bitmap, region: region,
                    top: frame.contentTop, bottom: frame.contentBottom, scrollDelta: 0)
        // 新段的第一帧：位置就是它自己，没有可比对的对象，以文字证据为准。
        let changed = merge(frame, offset: 0, into: segments.count - 1, textBacked: true)
        guard let placed = segments.firstIndex(where: { $0.id == segment.id }) else { return nil }
        return StitchPlacement(kind: .newSegment, segmentID: segment.id,
                               chainIndex: chain.firstIndex(of: segment.id) ?? chain.count,
                               offset: 0, scrollDelta: nil, merged: [], changed: changed || placed >= 0)
    }

    /// 画面没变（缩略图相同）时调用：可见范围内的消息多观察一次，用于判断稳定。
    func confirmStable() {
        guard let last, let index = segments.firstIndex(where: { $0.id == last.segmentID }) else { return }
        let top = last.top + last.offset, bottom = last.bottom + last.offset
        for i in segments[index].entries.indices {
            let entry = segments[index].entries[i]
            guard entry.top >= top - 1, entry.bottom <= bottom + 1, !entry.clipped else { continue }
            segments[index].entries[i].observations += 1
        }
    }

    /// 当前画面是否就是实时段的底部附近（没有在翻历史）。
    var isViewingLiveTail: Bool {
        guard let last, let live = liveSegment, last.segmentID == live.id,
              let newest = live.entries.last else { return false }
        // 最新一条只要还露在可见区内就算在看实时尾部：键盘弹起或最后一条被输入栏压住半截都很常见。
        return newest.top < last.bottom + last.offset - 4 && newest.bottom > last.top + last.offset + 4
    }

    // MARK: - 偏移估计

    /// 在片段里找这一屏的位置。返回帧 → 片段的平移量；证据不足返回 nil。
    private func estimateOffset(
        _ bubbles: [ChatBubble], into segment: TranscriptSegment, hint: CGFloat?, occluders: [CGRect] = [],
        motionOffset: CGFloat? = nil
    ) -> CGFloat? {
        guard !segment.entries.isEmpty else { return nil }
        struct Vote { let delta: CGFloat; let weight: Double; let entry: Int }
        var votes: [Vote] = []
        lastVotes = 0
        for bubble in bubbles {
            let normalized = TextMatch.normalize(bubble.text)
            guard !normalized.isEmpty else { continue }
            for (entryIndex, entry) in segment.entries.enumerated() where entry.kind == bubble.kind {
                if bubble.side != .unknown, entry.side != .unknown, bubble.side != entry.side,
                   bubble.sideConfidence >= 0.8, entry.sideConfidence >= 0.8 { continue }
                let similarity = TextMatch.similarity(normalized, entry.normalized)
                guard similarity >= 0.72 else { continue }
                // 被裁切的边不可信：优先用双方都完整的顶边对齐，否则用底边。
                let delta: CGFloat
                if !bubble.clippedTop && !entry.clippedTop {
                    delta = entry.top - bubble.rect.minY
                } else if !bubble.clippedBottom && !entry.clippedBottom {
                    delta = entry.bottom - bubble.rect.maxY
                } else {
                    continue
                }
                // 时间分隔线字数少、同一天里可能重复，只作辅助证据。
                let kindWeight = bubble.kind == .time ? 0.4 : 1.0
                var weight = similarity * min(Double(normalized.count), 12) / 12 * (bubble.clipped ? 0.5 : 1) * kindWeight
                // 文字被截断（画中画压住、或没识别全）时，完整的那次观察更可信。
                if bubble.clipped && abs(normalized.count - entry.normalized.count) > 2 { weight *= 0.6 }
                if !bubble.clipped && normalized.count == entry.normalized.count { weight *= 1.1 }
                votes.append(Vote(delta: delta, weight: weight, entry: entryIndex))
            }
        }
        guard !votes.isEmpty else { return nil }

        // 按偏移量聚类：同一真实偏移下，多条消息的 delta 应该落在一个行高以内。
        let tolerance = max(12, (bubbles.map(\.rect.height).min() ?? 20) * 0.8)
        struct Cluster { let center: CGFloat; let weight: Double; let distinct: Int }
        let clusters: [Cluster] = votes.map { seed in
            let members = votes.filter { abs($0.delta - seed.delta) <= tolerance }
            let weight = members.reduce(0) { $0 + $1.weight }
            let center = members.reduce(CGFloat(0)) { $0 + $1.delta * CGFloat($1.weight) } / CGFloat(max(weight, 0.0001))
            return Cluster(center: center, weight: weight, distinct: Set(members.map(\.entry)).count)
        }
        guard var chosen = clusters.max(by: { $0.weight < $1.weight }) else { return nil }
        lastVotes = chosen.distinct
        let rival = clusters
            .filter { abs($0.center - chosen.center) > 2 * tolerance }
            .max { $0.weight < $1.weight }
        // 两个位置证据接近（常见于“好”“嗯”这类短句重复），靠上一帧位置消歧，无提示就放弃。
        if let rival, rival.weight > 0.8 * chosen.weight {
            guard let hint else { return nil }
            chosen = abs(rival.center - hint) < abs(chosen.center - hint) ? rival : chosen
        }
        // 先用两套独立证据互相印证：文字偏移和画面位移落在同一个位置，就没有疑问了。
        if let motionOffset, abs(motionOffset - chosen.center) <= 4 {
            lastVotes = max(chosen.distinct, 1)
            lastOffsetCorroborated = true
            return chosen.center
        }
        // 否则看文字证据够不够：至少两条消息互相印证；或者一条足够长、相似度很高的消息——
        // 长句几乎不可能在别处重复，一条就够（整屏都是图片、只剩一两条文字气泡时很常见）。
        // 短句（“好”“嗯”）不在此列：同一会话里可能重复出现几次。
        let longEnough = chosen.distinct == 1 && chosen.weight >= 0.75
        guard chosen.distinct >= 2 || chosen.weight >= 0.7 || longEnough else { return nil }
        // 几何复核：按这个偏移，落在片段已覆盖范围内的其他气泡必须能在对应位置找到同一条消息。
        // 格式化、相似度高的不同消息会给出看似一致的错误偏移，这里拦下。
        // 被画中画压住、或位置上本来没有记录的气泡不作为冲突证据。
        let result = check(bubbles, in: segment, offset: chosen.center, occluders: occluders)
        guard result.agree >= 1, result.conflict <= max(0, result.agree / 3) else { return nil }
        return chosen.center
    }

    /// 复核结果。`unresolved` 是被画中画压住、或位置上本来就没有记录的气泡——都不算冲突。
    private struct CheckResult {
        var agree = 0
        var conflict = 0
        var unresolved = 0
    }

    private func check(
        _ bubbles: [ChatBubble], in segment: TranscriptSegment, offset: CGFloat, occluders: [CGRect]
    ) -> CheckResult {
        var result = CheckResult()
        for bubble in bubbles where !bubble.clipped && bubble.kind == .message {
            let top = bubble.rect.minY + offset, bottom = bubble.rect.maxY + offset
            guard top >= segment.coveredTop + 4, bottom <= segment.coveredBottom - 4 else { continue }
            let normalized = TextMatch.normalize(bubble.text)
            let tolerance = max(14, 0.9 * bubble.rect.height)
            let samePosition = segment.entries.filter {
                $0.kind == .message && !$0.clipped && abs($0.top - top) < tolerance
            }
            if samePosition.contains(where: { TextMatch.similarity($0.normalized, normalized) >= 0.7 }) {
                result.agree += 1
            } else if samePosition.isEmpty || occluders.contains(where: { $0.intersects(bubble.rect) }) {
                result.unresolved += 1
            } else {
                result.conflict += 1
            }
        }
        return result
    }

    /// 用气泡文字区域内的像素在文字估计附近 ±8 像素微调，让长截图接缝更准。
    /// 只比对气泡内部：聊天背景固定不动，整行比对会被背景拉偏。
    private func refine(
        _ offset: CGFloat, frame: ParsedChatFrame, bitmap: FrameBitmap,
        previous: Last
    ) -> CGFloat {
        guard previous.bitmap.width == bitmap.width, previous.bitmap.height == bitmap.height else { return offset }
        let base = offset - previous.offset   // 帧坐标 y → 上一帧坐标 y + base... 即 prevY = y + base
        let patches = frame.messageBubbles
            .filter { !$0.clipped && $0.rect.width > 40 }
            .filter { bubble in
                let prevTop = bubble.rect.minY + base
                return prevTop - 10 > previous.top && bubble.rect.maxY + base + 10 < previous.bottom
            }
            .sorted { $0.rect.width * $0.rect.height > $1.rect.width * $1.rect.height }
            .prefix(3)
        guard !patches.isEmpty else { return offset }

        var totals = [Double](repeating: 0, count: 17)
        for patch in patches {
            let rect = patch.rect.insetBy(dx: 2, dy: -2).integral
            for (i, s) in (-8...8).enumerated() {
                var cost = 0.0, n = 0
                var y = Int(rect.minY)
                while y < Int(rect.maxY) {
                    let prevY = y + Int(base.rounded()) + s
                    var x = Int(rect.minX)
                    while x < Int(rect.maxX) {
                        cost += abs(bitmap.luma(x: x, y: y) - previous.bitmap.luma(x: x, y: prevY))
                        n += 1
                        x += 3
                    }
                    y += 2
                }
                totals[i] += n > 0 ? cost / Double(n) : 0
            }
        }
        let current = totals[8]
        guard let best = totals.indices.min(by: { totals[$0] < totals[$1] }), totals[best] < current * 0.8 else { return offset }
        return previous.offset + base.rounded() + CGFloat(best - 8)
    }

    private func bestOtherSegment(
        _ bubbles: [ChatBubble], excluding: UUID?, occluders: [CGRect] = []
    ) -> (Int, CGFloat)? {
        for (index, segment) in segments.enumerated().reversed() where segment.id != excluding {
            if let offset = estimateOffset(bubbles, into: segment, hint: nil, occluders: occluders) {
                return (index, offset)
            }
        }
        return nil
    }

    // MARK: - 合并

    /// 把这一屏的气泡合入片段。返回片段内容是否变化（新消息、文字修正或删除幽灵条目）。
    /// - Parameter textBacked: 这一帧的位置由文字证据给出（碎片小字不会混进来），
    ///   新建的消息可以直接信任；否则要靠后续帧在同位置再次看到才确认。
    private func merge(_ frame: ParsedChatFrame, offset: CGFloat, into index: Int, textBacked: Bool) -> Bool {
        var segment = segments[index]
        var changed = false
        var matched = Set<UUID>()
        let viewTop = frame.contentTop + offset, viewBottom = frame.contentBottom + offset
        // 这一屏的文字证据是否足够。只有文字印证过的消息才进对话列表（整屏图片时尤其重要）。

        for bubble in frame.bubbles {
            let normalized = TextMatch.normalize(bubble.text)
            guard !normalized.isEmpty else { continue }
            let top = bubble.rect.minY + offset, bottom = bubble.rect.maxY + offset
            let tolerance = max(14, 0.9 * bubble.rect.height)
            let candidate = segment.entries.indices
                .filter { !matched.contains(segment.entries[$0].id) && segment.entries[$0].kind == bubble.kind }
                .compactMap { i -> (Int, Double)? in
                    let entry = segment.entries[i]
                    let overlap = min(entry.bottom, bottom) - max(entry.top, top)
                    let close = abs(entry.top - top) < tolerance || overlap > 0.5 * min(entry.bottom - entry.top, bottom - top)
                    guard close else { return nil }
                    let similarity = TextMatch.similarity(normalized, entry.normalized)
                    let prefix = bubble.clipped || entry.clipped
                        ? (entry.normalized.contains(normalized) || normalized.contains(entry.normalized)) : false
                    guard similarity >= 0.6 || prefix else { return nil }
                    return (i, max(similarity, prefix ? 0.7 : 0))
                }
                .max { $0.1 < $1.1 }
                // 文字对不上时按槽位认：同一方向、同一位置、同样大小的气泡就是同一条消息，
                // OCR 把“哈哈哈哈”读成别的字不能在原地多出一条。
                ?? (bubble.kind == .message ? segment.entries.indices
                    .filter { !matched.contains(segment.entries[$0].id) && segment.entries[$0].kind == .message }
                    .filter { Self.sameSlot(segment.entries[$0], top: top, bottom: bottom,
                                            minX: bubble.rect.minX, maxX: bubble.rect.maxX,
                                            side: bubble.side, sideConfidence: bubble.sideConfidence,
                                            clipped: bubble.clipped) }
                    .min { abs(segment.entries[$0].top - top) < abs(segment.entries[$1].top - top) }
                    .map { ($0, 0.0) } : nil)

            if let (i, _) = candidate {
                var entry = segment.entries[i]
                let before = entry.text
                let beforeQuote = entry.quote
                entry.observations += 1
                entry.misses = 0
                entry.lastSeen = frame.capturedAt
                entry.mergeSources([SeeUObservation(frame: frame, bubble: bubble)])
                if !bubble.clipped && entry.clipped {
                    // 之前只看到一半，现在看到完整气泡：以完整版本为准。
                    entry.variants = [normalized: (bubble.text, 2)]
                    entry.preferred = normalized
                    entry.normalized = normalized
                    entry.top = top; entry.bottom = bottom
                    entry.clippedTop = false; entry.clippedBottom = false
                } else if !bubble.clipped {
                    entry.observe(normalized: normalized, text: bubble.text)
                    entry.top = entry.top * 0.7 + top * 0.3
                    entry.bottom = entry.bottom * 0.7 + bottom * 0.3
                } else if entry.clipped {
                    // 两次都只看到一部分：保留更长的那次，完整的边以本帧为准。
                    if normalized.count > entry.normalized.count {
                        entry.variants = [normalized: (bubble.text, 1)]
                        entry.preferred = normalized
                        entry.normalized = normalized
                    }
                    if !bubble.clippedTop { entry.top = top; entry.clippedTop = false }
                    if !bubble.clippedBottom { entry.bottom = bottom; entry.clippedBottom = false }
                }
                if bubble.sideConfidence > entry.sideConfidence {
                    entry.side = bubble.side
                    entry.sideConfidence = bubble.sideConfidence
                }
                // 引用块在消息下方，可能这一帧才露出来。
                if let quote = bubble.quote, (entry.quote?.count ?? 0) < quote.count { entry.quote = quote }
                entry.minX = bubble.rect.minX; entry.maxX = bubble.rect.maxX
                if entry.senderName == nil { entry.senderName = bubble.senderName }
                if entry.text != before || entry.quote != beforeQuote { changed = true }
                // 和已有条目在同位置对上了文字，这条就是真的。
                if !entry.textConfirmed, !entry.clipped || textBacked {
                    entry.textConfirmed = true
                    changed = true
                }
                segment.entries[i] = entry
                matched.insert(entry.id)
            } else {
                let entry = TranscriptEntry(
                    id: UUID(), kind: bubble.kind, variants: [normalized: (bubble.text, 1)], normalized: normalized,
                    side: bubble.side, sideConfidence: bubble.sideConfidence,
                    top: top, bottom: bottom, minX: bubble.rect.minX, maxX: bubble.rect.maxX,
                    clippedTop: bubble.clippedTop, clippedBottom: bubble.clippedBottom,
                    senderName: bubble.senderName, quote: bubble.quote,
                    textConfirmed: !bubble.clipped && textBacked,
                    observations: 1, misses: 0, firstSeen: frame.capturedAt, lastSeen: frame.capturedAt,
                    sources: [SeeUObservation(frame: frame, bubble: bubble)]
                )
                segment.entries.append(entry)
                matched.insert(entry.id)
                changed = true
            }
        }

        // 应该在可见范围却没对上的条目：连续三帧都不在、且缺席次数不少于被看到的次数，
        // 视为误识别（画中画文字、图片小字、一闪而过的错读）删除。真实消息被看到很多次，偶尔漏读不会被删。
        segment.entries = segment.entries.compactMap { entry in
            guard !matched.contains(entry.id), entry.top >= viewTop, entry.bottom <= viewBottom else { return entry }
            var missed = entry
            missed.misses += 1
            if missed.misses >= 3 && missed.misses >= missed.observations { changed = true; return nil }
            return missed
        }
        // 之前被误当成独立消息的引用块（父消息当时不在屏内）：现在已挂到父消息上，删掉那条。
        let quotes = segment.entries.compactMap { $0.quote.map(TextMatch.normalize) }
        if !quotes.isEmpty {
            let before = segment.entries.count
            segment.entries.removeAll { entry in
                entry.kind == .message && entry.quote == nil && ChatLayoutParser.isQuoteLead(entry.text)
                    && quotes.contains { TextMatch.similarity($0, entry.normalized) >= 0.85 }
                    && entry.top >= viewTop && entry.bottom <= viewBottom
            }
            if segment.entries.count != before { changed = true }
        }
        segment.entries.sort { $0.top < $1.top }
        if Self.collapseOverlapping(&segment.entries) { changed = true }
        // 条目上限：丢掉离当前画面最远的一端。
        while segment.entries.count > Self.maxEntriesPerSegment, let first = segment.entries.first, let lastEntry = segment.entries.last {
            if viewTop - first.top > lastEntry.bottom - viewBottom {
                segment.entries.removeFirst()
                segment.coveredTop = segment.entries.first?.top ?? segment.coveredTop
            } else {
                segment.entries.removeLast()
                segment.coveredBottom = segment.entries.last?.bottom ?? segment.coveredBottom
            }
        }
        segment.coveredTop = min(segment.coveredTop, viewTop)
        segment.coveredBottom = max(segment.coveredBottom, viewBottom)
        segments[index] = segment
        return changed
    }

    /// 同一槽位：同一方向（或一方不确定）、纵向位置在一个气泡高度内、高度相近、横向大部分重合。
    /// 被裁切的气泡高度不可比，只看顶边或底边位置。
    static func sameSlot(
        _ entry: TranscriptEntry, top: CGFloat, bottom: CGFloat, minX: CGFloat, maxX: CGFloat,
        side: BubbleSide, sideConfidence: Double, clipped: Bool
    ) -> Bool {
        if side != .unknown, entry.side != .unknown, side != entry.side,
           sideConfidence >= 0.75, entry.sideConfidence >= 0.75 { return false }
        let height = bottom - top, entryHeight = entry.bottom - entry.top
        guard height > 0, entryHeight > 0 else { return false }
        let tolerance = max(10, 0.5 * min(height, entryHeight))
        if clipped || entry.clipped {
            guard abs(entry.top - top) < tolerance || abs(entry.bottom - bottom) < tolerance else { return false }
        } else {
            guard abs(entry.top - top) < tolerance,
                  max(height, entryHeight) / min(height, entryHeight) <= 1.45 else { return false }
        }
        let overlap = min(entry.maxX, maxX) - max(entry.minX, minX)
        return overlap >= 0.6 * min(entry.maxX - entry.minX, maxX - minX)
    }

    /// 同一位置被拆成两条的记录（历史遗留或合段带来）并成一条，保留观察更多的那条的身份。
    /// 相邻的两条真实消息之间有间距，纵向不会大面积重叠。
    static func collapseOverlapping(_ entries: inout [TranscriptEntry]) -> Bool {
        var changed = false
        var i = 0
        while i < entries.count {
            var j = i + 1
            while j < entries.count, entries[j].top < entries[i].bottom {
                let a = entries[i], b = entries[j]
                let vertical = min(a.bottom, b.bottom) - max(a.top, b.top)
                let horizontal = min(a.maxX, b.maxX) - max(a.minX, b.minX)
                if a.kind == b.kind, a.kind != .gap,
                   vertical > 0.5 * min(a.bottom - a.top, b.bottom - b.top),
                   horizontal > 0.5 * min(a.maxX - a.minX, b.maxX - b.minX),
                   !(a.side != .unknown && b.side != .unknown && a.side != b.side
                     && a.sideConfidence >= 0.75 && b.sideConfidence >= 0.75) {
                    var keep = a.observations >= b.observations ? a : b
                    keep.absorb(a.observations >= b.observations ? b : a)
                    entries[i] = keep
                    entries.remove(at: j)
                    changed = true
                    continue
                }
                j += 1
            }
            i += 1
        }
        return changed
    }

    /// 当前段和其他段有可靠重叠时合并（用户翻回之前看过的位置）。
    private func absorbOverlappingSegments(
        into target: UUID, viewTop: CGFloat, viewBottom: CGFloat
    ) -> [(id: UUID, shift: CGFloat)] {
        var merged: [(id: UUID, shift: CGFloat)] = []
        guard segments.count > 1, let targetIndex = segments.firstIndex(where: { $0.id == target }) else { return merged }
        // 只用当前可见的这一屏去比对，片段再长也只做一屏的计算量。
        let visible = segments[targetIndex].entries.filter { $0.top >= viewTop - 1 && $0.bottom <= viewBottom + 1 }
        let probe = visible.map { entry in
            ChatBubble(
                kind: entry.kind, text: entry.text,
                rect: CGRect(x: entry.minX, y: entry.top, width: entry.maxX - entry.minX, height: entry.bottom - entry.top),
                side: entry.side, sideConfidence: entry.sideConfidence,
                clippedTop: entry.clippedTop, clippedBottom: entry.clippedBottom,
                senderName: nil, quote: nil, color: nil
            )
        }
        for other in segments where other.id != target {
            // other 的坐标 + (-offset) = target 坐标
            guard let offset = estimateOffset(probe, into: other, hint: nil) else { continue }
            let shift = -offset
            guard var targetSegment = segments.first(where: { $0.id == target }) else { break }
            for entry in other.entries {
                let top = entry.top + shift, bottom = entry.bottom + shift
                let duplicate = targetSegment.entries.firstIndex { existing in
                    existing.kind == entry.kind
                        && abs(existing.top - top) < max(14, 0.9 * (bottom - top))
                        && (TextMatch.similarity(existing.normalized, entry.normalized) >= 0.6
                            || (entry.kind == .message && Self.sameSlot(
                                existing, top: top, bottom: bottom, minX: entry.minX, maxX: entry.maxX,
                                side: entry.side, sideConfidence: entry.sideConfidence, clipped: entry.clipped)))
                }
                if let duplicate {
                    targetSegment.entries[duplicate].mergeSources(entry.sources)
                    continue
                }
                var moved = entry
                moved.top = top; moved.bottom = bottom
                targetSegment.entries.append(moved)
            }
            targetSegment.entries.sort { $0.top < $1.top }
            targetSegment.isLive = targetSegment.isLive || other.isLive
            targetSegment.coveredTop = min(targetSegment.coveredTop, other.coveredTop + shift)
            targetSegment.coveredBottom = max(targetSegment.coveredBottom, other.coveredBottom + shift)
            if let i = segments.firstIndex(where: { $0.id == target }) { segments[i] = targetSegment }
            segments.removeAll { $0.id == other.id }
            if let position = chain.firstIndex(of: other.id) {
                if let targetPosition = chain.firstIndex(of: target) {
                    chain.removeAll { $0 == target || $0 == other.id }
                    chain.insert(target, at: min(min(position, targetPosition), chain.count))
                } else { chain[position] = target }
            }
            merged.append((other.id, shift))
        }
        refreshLiveFlags()
        return merged
    }
}
