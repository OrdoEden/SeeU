import CoreGraphics
import Foundation

/// 对话列表里的一条（消息或时间分隔线）。`top/bottom` 是片段内的全局 y（帧像素单位）。
nonisolated struct TranscriptEntry: Sendable {
    let id: UUID
    let kind: BubbleKind
    var variants: [String: (text: String, count: Int)]
    var normalized: String
    var side: BubbleSide
    var sideConfidence: Double
    var top: CGFloat
    var bottom: CGFloat
    var minX: CGFloat
    var maxX: CGFloat
    var clippedTop: Bool
    var clippedBottom: Bool
    var senderName: String?
    var quote: String?
    /// 这条消息足够可信，可以进对话列表和分析上下文。
    /// 一帧里看到一次可能只是噪声（整屏图片时图上的小字会被识别成行），
    /// 但只要在两帧里被稳定看到（同一位置、同一文字），它就在随聊天滚动，是真实消息。
    var textConfirmed: Bool
    var observations: Int
    var misses: Int
    var firstSeen: Date
    var lastSeen: Date
    var sources: [SeeUObservation] = []

    /// 合段只补来源，不让另一段的较差 OCR 原文覆盖现有投票结果。
    mutating func mergeSources(_ incoming: [SeeUObservation]) {
        var byFrame = Dictionary(sources.map { ($0.frameID, $0) }, uniquingKeysWith: { first, _ in first })
        for source in incoming {
            if let existing = byFrame[source.frameID],
               (existing.recognitionConfidence ?? -1) >= (source.recognitionConfidence ?? -1) { continue }
            byFrame[source.frameID] = source
        }
        sources = Array(byFrame.values.sorted {
            if $0.observedAt == $1.observedAt { return $0.frameID.uuidString < $1.frameID.uuidString }
            return $0.observedAt < $1.observedAt
        }.suffix(3))
    }

    /// 当前采用的读法（variants 的键）。只有挑战者明显更多次出现才切换，避免两种读法来回跳。
    var preferred: String? = nil

    var clipped: Bool { clippedTop || clippedBottom }

    /// 多帧投票后的文字：采用的读法优先，其次出现次数最多的识别结果，避免单帧 OCR 抖动触发重新分析。
    var text: String {
        if let preferred, let chosen = variants[preferred] { return chosen.text }
        return variants.values.max { $0.count < $1.count }?.text ?? ""
    }

    /// 记录一次完整（未裁切）的读法并按滞回规则决定是否切换采用的文字。
    mutating func observe(normalized key: String, text raw: String) {
        var variant = variants[key] ?? (raw, 0)
        variant.count += 1
        // 同一规范化文字的多种原文里，不含“口合”类拆字的更可信，不被后来的拆字读法覆盖。
        if !(TextMatch.hasSplitRadical(raw) && !TextMatch.hasSplitRadical(variant.text)) { variant.text = raw }
        variants[key] = variant
        if variants.count > 4,
           let weakest = variants.filter({ $0.key != key && $0.key != preferred })
               .min(by: { $0.value.count < $1.value.count })?.key {
            variants.removeValue(forKey: weakest)
        }
        let current = preferred.flatMap { variants[$0]?.count } ?? 0
        if preferred == nil || current == 0 {
            preferred = variants.max { $0.value.count < $1.value.count }?.key
        } else if let (leader, votes) = variants.max(by: { $0.value.count < $1.value.count }).map({ ($0.key, $0.value.count) }),
                  leader != preferred, votes >= 2, Double(votes) > 1.5 * Double(current) {
            preferred = leader
        }
        normalized = TextMatch.normalize(text)
    }

    /// 把同一位置被误拆成两条的记录并入本条：读法票数相加、来源合并。
    mutating func absorb(_ other: TranscriptEntry) {
        for (key, value) in other.variants {
            var variant = variants[key] ?? (value.text, 0)
            variant.count += value.count
            if TextMatch.hasSplitRadical(variant.text) && !TextMatch.hasSplitRadical(value.text) { variant.text = value.text }
            variants[key] = variant
        }
        observations += other.observations
        textConfirmed = textConfirmed || other.textConfirmed
        if other.sideConfidence > sideConfidence {
            side = other.side
            sideConfidence = other.sideConfidence
        }
        if (other.quote?.count ?? 0) > (quote?.count ?? 0) { quote = other.quote }
        if senderName == nil { senderName = other.senderName }
        firstSeen = min(firstSeen, other.firstSeen)
        lastSeen = max(lastSeen, other.lastSeen)
        mergeSources(other.sources)
        if let leader = variants.max(by: { $0.value.count < $1.value.count }),
           Double(leader.value.count) > 1.5 * Double(preferred.flatMap { variants[$0]?.count } ?? 0) {
            preferred = leader.key
        }
        normalized = TextMatch.normalize(text)
    }
}

/// 一段连续的对话。快速滚动、跳转历史导致没有重叠时，另起一段，不硬拼。
///
/// 各段之间用 `chain` 记先后：链首是包含最新消息的一段，往后依次更早。链上相邻两段之间
/// 可能有未截到的内容（`BubbleKind.gap`），但顺序是确定的，所以分析上下文能把它们接起来。
nonisolated struct TranscriptSegment: Sendable {
    let id: UUID
    var entries: [TranscriptEntry] = []
    /// 是否包含最新消息。等于“是本段链的链首”，由 `refreshLiveFlags` 统一计算。
    var isLive: Bool
    var coveredTop: CGFloat = .greatestFiniteMagnitude
    var coveredBottom: CGFloat = -.greatestFiniteMagnitude
    let createdAt: Date
}

/// 一帧放进哪段、放在什么位置。
nonisolated public struct StitchPlacement: Sendable {
    public enum Kind: Sendable {
        case extended       // 和当前段有重叠，平移后合入
        case rejoined       // 回到之前的某一段
        case newSegment     // 没有任何重叠，另起一段（上下文可能有缺口）
    }

    public let kind: Kind
    public let segmentID: UUID
    /// 这一段在链里的位置：0 = 含最新消息的一段，越大越早。
    public let chainIndex: Int
    /// 帧坐标 + offset = 片段全局坐标。
    public let offset: CGFloat
    /// 本帧相对上一帧的滚动量（同一段内才有）。负值 = 往上翻历史，正值 = 往下看更新的消息。
    public let scrollDelta: CGFloat?
    /// 与本段合并掉的其他段：id 与平移量（被合并段坐标 + shift = 本段坐标）。
    public let merged: [(id: UUID, shift: CGFloat)]
    public let changed: Bool
    /// 本帧中已由图像匹配验证的纵向范围；供合成选缝，不带聊天语义。
    public var matchingRange: ClosedRange<CGFloat>? = nil
}
