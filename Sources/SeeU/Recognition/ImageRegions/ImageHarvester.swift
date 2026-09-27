import CoreGraphics
import Foundation

/// 按宿主请求从已识别的聊天帧中提取图片区域。
///
/// - 输入是 `ChatSessionEngine` 产出的 `LongScreenshotInput`（与长图存档同一份帧），
///   不重复解码、不重复 OCR；宿主通常在 `LongScreenshotStore.ingest` 之后调用。
/// - 独立 actor：Vision 与像素扫描不占用会话引擎或长图存储。
/// - 外观相同的图片跨帧复用同一个 `imageID`，并统计出现在多少个不同消息位置，
///   宿主可据此做"至少两处印证"的判断或缓存语义结果。
public actor ImageHarvester {
    private var request: SeeUImageRequest
    private let detectors: [any SeeUImageDetector]

    private struct Entry {
        let imageID: UUID
        let kind: SeeUImageKind
        let pixels: [UInt8]
        var positions: Set<String>
        var lastUsed: Int
    }
    private var catalog: [Entry] = []
    private var tick = 0
    private var lastThumbnail: [UInt8]?
    private var lastConversationID: UUID?
    static let catalogLimit = 256
    static let sameImageThreshold = 0.065

    public init(request: SeeUImageRequest = .none,
                detectors: [any SeeUImageDetector] = [SeeUChatImageDetector()]) {
        self.request = request
        self.detectors = detectors
    }

    public func setRequest(_ request: SeeUImageRequest) {
        self.request = request
    }

    /// 清空跨帧去重记录（新录屏或用户清空时调用）。
    public func reset() {
        catalog = []
        tick = 0
        lastThumbnail = nil
        lastConversationID = nil
    }

    public func harvest(_ input: LongScreenshotInput) -> SeeUImageHarvest {
        let parsed = input.parsed
        func result(_ regions: [SeeUImageRegion]) -> SeeUImageHarvest {
            SeeUImageHarvest(sessionID: input.sessionID, conversationID: input.conversationID, frameID: input.frameID,
                             showsSenderNames: parsed.showsSenderNames, regions: regions)
        }
        guard !request.kinds.isEmpty else { return result([]) }
        // 画面没变时不重复跑 Vision。
        let thumbnail = input.bitmap.thumbnail()
        defer {
            lastThumbnail = thumbnail
            lastConversationID = input.conversationID
        }
        if lastConversationID == input.conversationID, let lastThumbnail,
           FrameBitmap.thumbnailDistance(lastThumbnail, thumbnail) < 1 {
            return result([])
        }

        let frame = SeeUImageFrame(bitmap: input.bitmap, parsed: parsed)
        let kinds = request.kinds
        let candidates = detectors
            .filter { !$0.kinds.isDisjoint(with: kinds) }
            .flatMap { $0.detect(in: frame) }
            .filter { kinds.contains($0.kind) }
        let bounds = CGRect(origin: .zero, size: input.bitmap.size)
        var regions: [SeeUImageRegion] = []
        for candidate in candidates {
            let rect = candidate.rect.intersection(bounds).integral
            guard !rect.isNull, rect.width >= 8, rect.height >= 8,
                  let crop = input.bitmap.image.cropping(to: rect),
                  let pixels = ImagePatch.sample(crop),
                  let scaled = ImagePatch.downscaled(crop, maximum: request.maximumPixelSize),
                  let jpeg = FrameBitmap.encodeJPEG(scaled, quality: request.jpegQuality) else { continue }
            let anchors = Self.anchors(for: rect, alignedIndex: candidate.alignedBubbleIndex,
                                       bubbles: parsed.bubbles, ids: input.messageIDs)
            let position = anchors.aligned.map { "aligned:\($0)" }
                ?? "between:\(anchors.preceding?.uuidString ?? "-")|\(anchors.following?.uuidString ?? "-")"
            let (entry, isNew) = remember(kind: candidate.kind, pixels: pixels, position: position)
            regions.append(SeeUImageRegion(
                id: UUID(), imageID: entry.imageID, kind: candidate.kind, side: candidate.side,
                frameID: input.frameID, rect: rect,
                precedingMessageID: anchors.preceding, followingMessageID: anchors.following,
                alignedMessageID: anchors.aligned, evidenceCount: entry.positions.count,
                isNewImage: isNew, jpegData: jpeg, dominantColor: ImagePatch.dominantColor(pixels)
            ))
        }
        return result(regions.sorted { $0.rect.minY < $1.rect.minY })
    }

    // MARK: - 内部

    private func remember(kind: SeeUImageKind, pixels: [UInt8], position: String) -> (Entry, Bool) {
        tick += 1
        if let index = catalog.firstIndex(where: {
            $0.kind == kind && ImagePatch.difference($0.pixels, pixels) < Self.sameImageThreshold
        }) {
            catalog[index].positions.insert(position)
            catalog[index].lastUsed = tick
            return (catalog[index], false)
        }
        let entry = Entry(imageID: UUID(), kind: kind, pixels: pixels, positions: [position], lastUsed: tick)
        catalog.append(entry)
        if catalog.count > Self.catalogLimit,
           let oldest = catalog.indices.min(by: { catalog[$0].lastUsed < catalog[$1].lastUsed }) {
            catalog.remove(at: oldest)
        }
        return (entry, true)
    }

    static func anchors(for rect: CGRect, alignedIndex: Int?, bubbles: [ChatBubble],
                        ids: [UUID?]) -> (preceding: UUID?, following: UUID?, aligned: UUID?) {
        guard bubbles.count == ids.count else { return (nil, nil, nil) }
        let aligned = alignedIndex.flatMap { ids.indices.contains($0) ? ids[$0] : nil }
        var preceding: UUID?, following: UUID?
        for index in bubbles.indices {
            guard let id = ids[index], id != aligned else { continue }
            if bubbles[index].rect.maxY <= rect.minY + 4 { preceding = id }
            if following == nil, bubbles[index].rect.minY >= rect.maxY - 4 { following = id }
        }
        return (preceding, following, aligned)
    }
}
