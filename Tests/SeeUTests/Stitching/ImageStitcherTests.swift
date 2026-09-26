import CoreGraphics
import Foundation
import XCTest
@testable import SeeU

final class ImageStitcherTests: XCTestCase {
    private func image(width: Int = 120, height: Int = 240, value: UInt8 = 100) throws -> Data {
        let bytes = Data(repeating: value, count: width * height * 4)
        let provider = try XCTUnwrap(CGDataProvider(data: bytes as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8,
                                         bitsPerPixel: 32, bytesPerRow: width * 4,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return try XCTUnwrap(FrameBitmap.encodePNG(image))
    }

    func testPublicAPIWorksWithoutOCRAndFailedFramesDoNotChangeCanvas() async throws {
        let stitcher = SeeUImageStitcher()
        let data = try image()
        let first = try await stitcher.ingest(data)
        XCTAssertEqual(first.status, .started)
        let before = await stitcher.renderPNG()
        XCTAssertNotNil(before)
        let duplicate = try await stitcher.ingest(data)
        XCTAssertEqual(duplicate.status, .unchanged)
        XCTAssertEqual(duplicate.stripCount, 1)
        let unrelated = try await stitcher.ingest(image(value: 220))
        XCTAssertEqual(unrelated.status, .unmatched)
        let after = await stitcher.renderPNG()
        XCTAssertEqual(before, after)
        let incompatible = try await stitcher.ingest(image(width: 121))
        XCTAssertEqual(incompatible.status, .unmatched)
        await stitcher.reset()
        let empty = await stitcher.renderPNG()
        XCTAssertNil(empty)
    }

    func testInvalidExclusionAndBudgetFailureAreExplicit() async throws {
        let data = try image()
        let stitcher = SeeUImageStitcher(maximumStoredBytes: 1)
        do {
            _ = try await stitcher.ingest(data)
            XCTFail("Expected storage budget failure")
        } catch ImageStitchError.storageLimitOrEncodingFailure { }
        let empty = await stitcher.renderPNG()
        XCTAssertNil(empty)
        let validStore = SeeUImageStitcher()
        do {
            _ = try await validStore.ingest(data, region: ImageStitchRegion(exclusions: [.null]))
            XCTFail("Invalid exclusion must not expose pixels")
        } catch ImageStitchError.invalidRegion { }
    }

    /// 只在开发者本地配置目录时运行；不提交私人图片。
    func testOptionalLocalScreenshotsThroughPublicAPI() async throws {
        guard let directory = ProcessInfo.processInfo.environment["SEEU_ALIGNMENT_FIXTURE_DIRECTORY"] else {
            throw XCTSkip("Set SEEU_ALIGNMENT_FIXTURE_DIRECTORY to the local screenshot directory")
        }
        let folder = URL(fileURLWithPath: directory)
        let stitcher = SeeUImageStitcher()
        _ = try await stitcher.ingest(Data(contentsOf: folder.appendingPathComponent("IMG_3253.PNG")))
        let update = try await stitcher.ingest(Data(contentsOf: folder.appendingPathComponent("IMG_3252.PNG")))
        XCTAssertEqual(update.status, .appended)
        XCTAssertEqual(update.offset, 1499)
        XCTAssertEqual(update.imageSpan, 4055)
        let png = await stitcher.renderPNG()
        let result = try FrameBitmap(imageData: XCTUnwrap(png), limits: .init())
        XCTAssertEqual(result.width, 1179)
        XCTAssertEqual(result.height, 4055)
        if let output = ProcessInfo.processInfo.environment["SEEU_STITCH_OUTPUT_PATH"] {
            try XCTUnwrap(png).write(to: URL(fileURLWithPath: output), options: .atomic)
        }
    }
}
