import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import SeeU

final class ImageAlignmentTests: XCTestCase {
    func testMovingContentWinsOverFixedWallpaperInBothDirections() throws {
        let previous = try bitmap(scroll: 0), current = try bitmap(scroll: 173)
        let forward = align(previous, current), backward = align(current, previous)
        XCTAssertEqual(forward.status, .matched)
        XCTAssertEqual(forward.offset, 173)
        XCTAssertGreaterThanOrEqual(forward.matchedRegions, 3)
        XCTAssertEqual(backward.status, .matched)
        XCTAssertEqual(backward.offset, -173)
    }

    func testUnchangedAndUnrelatedContentAreDifferentOutcomes() throws {
        let original = try bitmap(scroll: 0)
        XCTAssertEqual(align(original, original).status, .unchanged)
        let unrelated = try bitmap(scroll: 0, seed: 871)
        XCTAssertEqual(align(original, unrelated).status, .unmatched)
    }

    func testRepeatedTextureIsNotResolvedByAnUnverifiedHint() throws {
        let previous = try bitmap(scroll: 0, repeating: true)
        let current = try bitmap(scroll: 31, repeating: true)
        let result = ImageAligner.align(previous: previous, current: current,
                                       previousRegion: ImageStitchRegion(), currentRegion: ImageStitchRegion(), hint: 31)
        XCTAssertEqual(result.status, .unmatched)
    }

    func testRegionsAndOcclusionDoNotVoteForOverlay() throws {
        let previous = try bitmap(scroll: 0)
        let overlay = CGRect(x: 45, y: 40, width: 155, height: 90)
        let current = try bitmap(scroll: 173, overlay: overlay)
        let result = ImageAligner.align(previous: previous, current: current,
                                       previousRegion: ImageStitchRegion(rect: CGRect(x: 0, y: 30, width: 240, height: 460)),
                                       currentRegion: ImageStitchRegion(rect: CGRect(x: 0, y: 30, width: 240, height: 460), exclusions: [overlay]))
        XCTAssertEqual(result.status, .matched)
        XCTAssertEqual(result.offset, 173)
        let invalid = ImageAligner.align(previous: previous, current: current,
                                        previousRegion: ImageStitchRegion(rect: .null), currentRegion: ImageStitchRegion())
        XCTAssertEqual(invalid.status, .unmatched)
        XCTAssertTrue(ImageStitchRegion(exclusions: [CGRect(x: 0, y: 0, width: -1, height: 20)])
            .bounds(in: previous).isNull)
        XCTAssertTrue(ImageStitchRegion(exclusions: Array(repeating: CGRect(x: 0, y: 0, width: 1, height: 1), count: 129))
            .bounds(in: previous).isNull)
        XCTAssertFalse(ImageStitchRegion(exclusions: [.zero]).bounds(in: previous).isNull)
        let fractional = ImageAligner.align(previous: previous, current: current,
                                            previousRegion: ImageStitchRegion(rect: CGRect(x: 0, y: 0.1, width: 240, height: 11.1)),
                                            currentRegion: ImageStitchRegion())
        XCTAssertEqual(fractional.status, .unmatched)
    }

    /// 可选本地回归；私人截图不进入测试资源或版本控制。
    func testOptionalLocalWallpaperScreenshots() throws {
        guard let directory = ProcessInfo.processInfo.environment["SEEU_ALIGNMENT_FIXTURE_DIRECTORY"] else {
            throw XCTSkip("Set SEEU_ALIGNMENT_FIXTURE_DIRECTORY to the local screenshot directory")
        }
        func load(_ name: String) throws -> FrameBitmap {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
            return try FrameBitmap(imageData: Data(contentsOf: url), limits: SeeUImageLimits())
        }
        let previous = try load("IMG_3253.PNG"), current = try load("IMG_3252.PNG")
        let result = align(previous, current)
        XCTAssertEqual(result.status, .matched)
        XCTAssertEqual(result.offset, 1499)
        XCTAssertEqual(align(current, previous).offset, -1499)
    }

    private func align(_ previous: FrameBitmap, _ current: FrameBitmap) -> ImageAlignment {
        ImageAligner.align(previous: previous, current: current,
                           previousRegion: ImageStitchRegion(), currentRegion: ImageStitchRegion())
    }

    private func bitmap(scroll: Int, seed: Int = 17, repeating: Bool = false,
                        overlay: CGRect? = nil) throws -> FrameBitmap {
        let width = 240, height = 520
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        func texture(_ x: Int, _ y: Int, _ seed: Int) -> UInt8 {
            let value = UInt64(x + 1) &* 73_856_093 ^ UInt64(y + 1) &* 19_349_663 ^ UInt64(seed) &* 83_492_791
            return UInt8((value ^ (value >> 13) ^ (value >> 23)) & 255)
        }
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                let foreground = x >= 60 && x < 150
                let contentY = repeating ? (y + scroll) % 64 : y + scroll
                let value = foreground ? texture(x, contentY, seed) : texture(x, y, 3)
                bytes[index] = value
                bytes[index + 1] = value
                bytes[index + 2] = value
                if overlay?.contains(CGPoint(x: x, y: y)) == true {
                    bytes[index] = 245; bytes[index + 1] = 30; bytes[index + 2] = 60
                }
            }
        }
        let data = Data(bytes)
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                         bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let encoded = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return try FrameBitmap(imageData: encoded as Data, limits: SeeUImageLimits())
    }
}
