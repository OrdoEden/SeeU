import CoreGraphics
import Foundation

/// 图片区域的类别。SeeU 只识别像素与版式，类别的业务用途由宿主决定。
/// 宿主可声明自己的类别，并配合自定义 `SeeUImageDetector` 使用。
nonisolated public struct SeeUImageKind: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    /// 聊天头像列中的方形头像（两侧都会识别，`side` 区分）。
    public static let avatar = SeeUImageKind(rawValue: "avatar")
    /// 头像旁没有文字气泡、尺寸较小的图片消息（表情包）。
    public static let sticker = SeeUImageKind(rawValue: "sticker")
    /// 头像旁没有文字气泡、尺寸较大的图片消息（照片、截图）。
    public static let photo = SeeUImageKind(rawValue: "photo")
}

/// 宿主声明需要提取的图片类别与输出规格。
nonisolated public struct SeeUImageRequest: Sendable, Equatable {
    public var kinds: Set<SeeUImageKind>
    /// 裁图输出的最长边像素；越小越省内存与上传流量。
    public var maximumPixelSize: Int
    public var jpegQuality: Double

    public init(kinds: Set<SeeUImageKind>, maximumPixelSize: Int = 256, jpegQuality: Double = 0.85) {
        self.kinds = kinds
        self.maximumPixelSize = max(16, maximumPixelSize)
        self.jpegQuality = min(max(jpegQuality, 0.1), 1)
    }

    public static let none = SeeUImageRequest(kinds: [])
}

/// 0...1 的 sRGB 颜色，不携带 UIKit 依赖。
nonisolated public struct SeeUColor: Sendable, Equatable, Codable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

/// 检测器看到的一帧：原像素、版式解析结果和页面底色。只在一次检测期间持有。
nonisolated public final class SeeUImageFrame: @unchecked Sendable {
    let bitmap: FrameBitmap
    public let parsed: ParsedChatFrame
    public var image: CGImage { bitmap.image }
    public var pixelSize: CGSize { bitmap.size }

    init(bitmap: FrameBitmap, parsed: ParsedChatFrame) {
        self.bitmap = bitmap
        self.parsed = parsed
    }

    /// 内容区的页面底色（排除文字框），用于判断图片边界。
    public private(set) lazy var backgroundColor: SeeUColor? = {
        let content = CGRect(x: 0, y: parsed.contentTop, width: pixelSize.width,
                             height: max(0, parsed.contentBottom - parsed.contentTop))
        return bitmap.dominantColor(in: content, excluding: parsed.bubbles.map(\.rect)).map {
            SeeUColor(red: $0.r / 255, green: $0.g / 255, blue: $0.b / 255)
        }
    }()

    /// 单点颜色，坐标为帧像素、左上原点。
    public func color(x: Int, y: Int) -> SeeUColor {
        let c = bitmap.color(x: x, y: y)
        return SeeUColor(red: c.r / 255, green: c.g / 255, blue: c.b / 255)
    }
}

/// 检测器输出的候选区域，由 `ImageHarvester` 负责裁图、去重、定位与编码。
nonisolated public struct SeeUImageCandidate: Sendable, Equatable {
    public let kind: SeeUImageKind
    /// 帧像素、左上原点。
    public let rect: CGRect
    public let side: BubbleSide
    /// 与区域同一行、属于同一条消息的气泡下标（`parsed.bubbles`），例如头像右侧的文字气泡。
    public let alignedBubbleIndex: Int?

    public init(kind: SeeUImageKind, rect: CGRect, side: BubbleSide, alignedBubbleIndex: Int? = nil) {
        self.kind = kind
        self.rect = rect
        self.side = side
        self.alignedBubbleIndex = alignedBubbleIndex
    }
}

/// 宿主可注入的检测协议。实现应是纯函数：只读 `frame`，同步返回候选。
/// 在 `ImageHarvester` 的 actor 上串行调用，不要在内部再开线程持有帧。
public protocol SeeUImageDetector: Sendable {
    /// 本检测器能产出的类别；与请求无交集时不会被调用。
    var kinds: Set<SeeUImageKind> { get }
    func detect(in frame: SeeUImageFrame) -> [SeeUImageCandidate]
}

/// 一次提取出的图片区域。
nonisolated public struct SeeUImageRegion: Sendable, Identifiable {
    /// 本次出现的 ID（每帧每区域不同）。
    public let id: UUID
    /// 外观相同的图片共享的稳定 ID；跨帧、跨会话复用，宿主可据此缓存语义或去重上传。
    public let imageID: UUID
    public let kind: SeeUImageKind
    public let side: BubbleSide
    public let frameID: UUID
    /// 帧像素、左上原点。
    public let rect: CGRect
    /// 区域上方最近的文字消息 ID（`SeeUConversationItem.id`）。
    public let precedingMessageID: UUID?
    /// 区域下方最近的文字消息 ID。
    public let followingMessageID: UUID?
    /// 与区域同一行的文字消息 ID（例如头像所属的那条消息）。
    public let alignedMessageID: UUID?
    /// 同一 `imageID` 在不同消息位置出现的次数，越多越可信（头像通常需要 ≥ 2）。
    public let evidenceCount: Int
    /// 首次出现时为 true。
    public let isNewImage: Bool
    public let jpegData: Data
    /// 主色（忽略近黑、近白），界面如何使用由宿主决定。
    public let dominantColor: SeeUColor?
}

/// 一帧的提取结果。
nonisolated public struct SeeUImageHarvest: Sendable {
    public let sessionID: UUID
    public let conversationID: UUID?
    public let frameID: UUID
    /// 本帧气泡上方出现昵称，通常是群聊；宿主可据此忽略头像。
    public let showsSenderNames: Bool
    public let regions: [SeeUImageRegion]

    public func regions(of kind: SeeUImageKind) -> [SeeUImageRegion] { regions.filter { $0.kind == kind } }
}
