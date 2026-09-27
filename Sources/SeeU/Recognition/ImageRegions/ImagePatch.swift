import CoreGraphics
import Foundation

/// 24×24 RGBA 缩略采样与比较，供头像/表情包的纹理判断、去重和取主色共用。
nonisolated enum ImagePatch {
    static let side = 24

    static func sample(_ image: CGImage) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let success = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: side, height: side,
                                          bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                            | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return success ? pixels : nil
    }

    /// 亮度方差足够大才算有内容；纯色块（空白、占位色）会被拒绝。
    static func hasTexture(_ pixels: [UInt8]) -> Bool {
        var luminance: [Double] = []
        luminance.reserveCapacity(pixels.count / 4)
        var index = 0
        while index + 2 < pixels.count {
            let sum = Int(pixels[index]) + Int(pixels[index + 1]) + Int(pixels[index + 2])
            luminance.append(Double(sum) / 765)
            index += 4
        }
        guard !luminance.isEmpty else { return false }
        let count = Double(luminance.count)
        let mean = luminance.reduce(0, +) / count
        var squares = 0.0
        for value in luminance {
            let delta = value - mean
            squares += delta * delta
        }
        return squares / count > 0.006
    }

    /// 平均通道差，0...1；< 0.065 视为同一张图。
    static func difference(_ first: [UInt8], _ second: [UInt8]) -> Double {
        guard first.count == second.count, !first.isEmpty else { return 1 }
        var total = 0
        for index in stride(from: 0, to: first.count, by: 4) {
            for channel in 0..<3 { total += abs(Int(first[index + channel]) - Int(second[index + channel])) }
        }
        return Double(total) / Double(first.count / 4 * 3 * 255)
    }

    /// 量化到 8×8×8 色桶取最多的一桶均值；跳过近黑、近白像素和边缘 2px。
    static func dominantColor(_ pixels: [UInt8]) -> SeeUColor? {
        guard pixels.count == side * side * 4 else { return nil }
        var bins: [Int: (count: Int, red: Int, green: Int, blue: Int)] = [:]
        for y in 2..<(side - 2) {
            for x in 2..<(side - 2) {
                let index = (y * side + x) * 4
                let r = Int(pixels[index]), g = Int(pixels[index + 1]), b = Int(pixels[index + 2])
                guard max(r, g, b) > 24, min(r, g, b) < 238 else { continue }
                let key = (r / 32) * 64 + (g / 32) * 8 + b / 32
                let old = bins[key] ?? (0, 0, 0, 0)
                bins[key] = (old.count + 1, old.red + r, old.green + g, old.blue + b)
            }
        }
        guard let best = bins.max(by: {
            $0.value.count == $1.value.count ? $0.key < $1.key : $0.value.count < $1.value.count
        })?.value else { return nil }
        let divisor = Double(best.count) * 255
        return SeeUColor(red: Double(best.red) / divisor, green: Double(best.green) / divisor,
                         blue: Double(best.blue) / divisor)
    }

    /// 最长边不超过 maximum 的等比缩放；已足够小时原样返回。
    static func downscaled(_ image: CGImage, maximum: Int) -> CGImage? {
        let longest = max(image.width, image.height)
        guard longest > maximum else { return image }
        let scale = Double(maximum) / Double(longest)
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
