import CoreGraphics
import Foundation

/// 聊天业务适配：保留窗口、气泡提示和页面头尾；像素合成由通用画布负责。
nonisolated final class ChatLadder {
    static let defaultCapacity = 10

    let width: Int
    private(set) var capacity: Int
    private let canvas: ImageStripCanvas
    private var header: (data: Data, capturedAt: Date)?
    private var footer: (data: Data?, bottom: CGFloat, capturedAt: Date)?

    init(width: Int, capacity: Int = ChatLadder.defaultCapacity) {
        self.width = width
        self.capacity = max(2, capacity)
        self.canvas = ImageStripCanvas(width: width)
    }

    var top: CGFloat? { canvas.top }
    var bottom: CGFloat? { canvas.bottom }
    var span: Int { canvas.span }
    var rungCount: Int { canvas.count }

    func add(
        bitmap: FrameBitmap, contentTop: CGFloat, contentBottom: CGFloat, offset: CGFloat,
        bubbleRects: [CGRect], capturedAt: Date, header: (jpeg: Data, height: Int)?,
        footer: (jpeg: Data, height: Int)?, exclusions: [CGRect] = [], seamRange: ClosedRange<CGFloat>? = nil
    ) {
        let pad = max(12, 0.035 * CGFloat(width))
        guard contentBottom - contentTop > 40,
              canvas.add(bitmap: bitmap,
                         rect: CGRect(x: 0, y: contentTop, width: CGFloat(width), height: contentBottom - contentTop),
                         offset: offset, exclusions: exclusions,
                         protectedRects: bubbleRects.map { $0.insetBy(dx: 0, dy: -pad) },
                         capturedAt: capturedAt, seamRange: seamRange) else { return }
        if let header, self.header == nil || capturedAt >= self.header!.capturedAt {
            self.header = (header.jpeg, capturedAt)
        }
        let frameBottom = min(CGFloat(bitmap.height), contentBottom.rounded()) + offset.rounded()
        if self.footer == nil || frameBottom > self.footer!.bottom ||
            (frameBottom == self.footer!.bottom && capturedAt >= self.footer!.capturedAt) {
            self.footer = (footer?.jpeg, frameBottom, capturedAt)
        }
        canvas.trim(to: capacity)
    }

    func absorb(_ other: ChatLadder, shift: CGFloat) {
        guard other !== self, other.width == width, shift.isFinite, abs(shift) <= 1_000_000_000,
              other.top.map({ abs($0 + shift.rounded()) <= 1_000_000_000 }) ?? true,
              other.bottom.map({ abs($0 + shift.rounded()) <= 1_000_000_000 }) ?? true else { return }
        canvas.absorb(other.canvas, shift: shift)
        if let incoming = other.header, header == nil || incoming.capturedAt >= header!.capturedAt {
            header = incoming
        }
        if let incoming = other.footer {
            let shiftedBottom = incoming.bottom + shift.rounded()
            if footer == nil || shiftedBottom > footer!.bottom ||
                (shiftedBottom == footer!.bottom && incoming.capturedAt >= footer!.capturedAt) {
                footer = (incoming.data, shiftedBottom, incoming.capturedAt)
            }
        }
        canvas.trim(to: capacity)
    }

    func setCapacity(_ value: Int) {
        capacity = max(2, value)
        canvas.trim(to: capacity)
    }

    func render(maxPixelHeight: Int) -> CGImage? {
        let headerImage = header.flatMap { FrameBitmap.decodeJPEG($0.data) }
        // 键盘帧或已移出窗口的最底帧不能给当前画布添加旧输入栏。
        let footerImage: CGImage?
        if let footer, let bottom, abs(footer.bottom - bottom) < 1, let data = footer.data {
            footerImage = FrameBitmap.decodeJPEG(data)
        } else {
            footerImage = nil
        }
        return canvas.render(maxPixelHeight: maxPixelHeight, header: headerImage, footer: footerImage)
    }
}
