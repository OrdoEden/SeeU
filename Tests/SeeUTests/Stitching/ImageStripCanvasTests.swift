import CoreGraphics
import Foundation
import XCTest
@testable import SeeU

final class ImageStripCanvasTests: XCTestCase {
    private func bitmap(width: Int = 40, height: Int = 100,
                        pixel: (Int, Int) -> (UInt8, UInt8, UInt8)) throws -> FrameBitmap {
        var bytes = [UInt8]()
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = pixel(x, y)
                bytes.append(contentsOf: [r, g, b, 255])
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8,
                                          bitsPerPixel: 32, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                          provider: provider, decode: nil, shouldInterpolate: false,
                                          intent: .defaultIntent))
        return try FrameBitmap(image: image)
    }

    private func rendered(_ canvas: ImageStripCanvas) throws -> FrameBitmap {
        try FrameBitmap(image: XCTUnwrap(canvas.render(maxPixelHeight: 10_000)))
    }

    private func time(_ second: Double) -> Date { Date(timeIntervalSince1970: second) }

    func testNewOccluderPreservesOlderClearPixelsAndNewerValidPixels() throws {
        let canvas = ImageStripCanvas(width: 40)
        let old = try bitmap { _, _ in (210, 20, 20) }
        let new = try bitmap { _, _ in (20, 210, 20) }
        let rect = CGRect(x: 0, y: 0, width: 40, height: 100)
        XCTAssertTrue(canvas.add(bitmap: old, rect: rect, offset: 0, capturedAt: time(1)))
        XCTAssertTrue(canvas.add(bitmap: new, rect: rect, offset: 0,
                                 exclusions: [CGRect(x: 10, y: 20, width: 20, height: 60)], capturedAt: time(2)))
        XCTAssertEqual(canvas.count, 2)
        let result = try rendered(canvas)
        XCTAssertGreaterThan(result.color(x: 20, y: 50).r, 200)
        XCTAssertGreaterThan(result.color(x: 3, y: 50).g, 200)
        XCTAssertGreaterThan(result.color(x: 20, y: 5).g, 200)
    }

    func testCoveredNewerInteriorIsNotDiscardedForOlderWideImage() throws {
        let canvas = ImageStripCanvas(width: 40)
        let old = try bitmap { _, _ in (210, 20, 20) }
        let new = try bitmap { _, _ in (20, 210, 20) }
        canvas.add(bitmap: old, rect: CGRect(x: 0, y: 0, width: 40, height: 100), offset: 0, capturedAt: time(1))
        canvas.add(bitmap: new, rect: CGRect(x: 0, y: 20, width: 40, height: 60), offset: 0, capturedAt: time(2))
        canvas.add(bitmap: old, rect: CGRect(x: 0, y: 0, width: 40, height: 100), offset: 90, capturedAt: time(3))
        XCTAssertEqual(canvas.count, 3)
        let result = try rendered(canvas)
        XCTAssertEqual(result.height, 190)
        XCTAssertGreaterThan(result.color(x: 20, y: 50).g, 200)
        XCTAssertGreaterThan(result.color(x: 20, y: 10).r, 200)
    }

    func testShiftedSegmentMergePreservesExclusionsAndChronology() throws {
        let canvas = ImageStripCanvas(width: 40), other = ImageStripCanvas(width: 40)
        let red = try bitmap { _, _ in (210, 20, 20) }
        let green = try bitmap { _, _ in (20, 210, 20) }
        let rect = CGRect(x: 0, y: 0, width: 40, height: 100)
        canvas.add(bitmap: red, rect: rect, offset: 0, capturedAt: time(1))
        other.add(bitmap: green, rect: rect, offset: -25,
                  exclusions: [CGRect(x: 10, y: 20, width: 20, height: 60)], capturedAt: time(2))
        canvas.absorb(other, shift: 25)
        XCTAssertEqual(canvas.span, 100)
        let result = try rendered(canvas)
        XCTAssertGreaterThan(result.color(x: 20, y: 50).r, 200)
        XCTAssertGreaterThan(result.color(x: 3, y: 50).g, 200)
        canvas.absorb(other, shift: 25)
        XCTAssertEqual(canvas.count, 2)
    }

    func testPixelIdenticalOverlapKeepsRowsContinuousInBothDirections() throws {
        let earlier = try bitmap { _, y in (UInt8(y), 40, 70) }
        let later = try bitmap { _, y in (UInt8(y + 60), 40, 70) }
        let rect = CGRect(x: 0, y: 0, width: 40, height: 100)
        for reverse in [false, true] {
            let canvas = ImageStripCanvas(width: 40)
            canvas.add(bitmap: reverse ? later : earlier, rect: rect, offset: reverse ? 60 : 0, capturedAt: time(1))
            canvas.add(bitmap: reverse ? earlier : later, rect: rect, offset: reverse ? 0 : 60, capturedAt: time(2))
            let result = try rendered(canvas)
            XCTAssertEqual(result.height, 160)
            for y in 0..<160 { XCTAssertEqual(result.color(x: 20, y: y).r, Double(y), accuracy: 1) }
        }
    }

    func testUncoveredExclusionRemainsNeutralInsteadOfCopyingOccluder() throws {
        let canvas = ImageStripCanvas(width: 40)
        let red = try bitmap { _, _ in (210, 20, 20) }
        canvas.add(bitmap: red, rect: CGRect(x: 0, y: 0, width: 40, height: 100), offset: 0,
                   exclusions: [CGRect(x: 10, y: 20, width: 20, height: 60)], capturedAt: time(1))
        let result = try rendered(canvas), color = result.color(x: 20, y: 50)
        XCTAssertEqual(color.r, color.g, accuracy: 1)
        XCTAssertGreaterThan(color.g, 220)
    }

    func testSeamUsesMatchingPixelsEvenInsideProtectedForeground() throws {
        let canvas = ImageStripCanvas(width: 40)
        let earlier = try bitmap { _, y in (70...74).contains(y) ? (20, 20, 210) : (210, 20, 20) }
        let later = try bitmap { _, y in (10...14).contains(y) ? (20, 20, 210) : (20, 210, 20) }
        let rect = CGRect(x: 0, y: 0, width: 40, height: 100)
        canvas.add(bitmap: earlier, rect: rect, offset: 0, protectedRects: [rect], capturedAt: time(1))
        canvas.add(bitmap: later, rect: rect, offset: 60, protectedRects: [rect], capturedAt: time(2))
        let result = try rendered(canvas)
        XCTAssertGreaterThan(result.color(x: 20, y: 69).r, 200)
        XCTAssertGreaterThan(result.color(x: 20, y: 72).b, 200)
        XCTAssertGreaterThan(result.color(x: 20, y: 75).g, 200)
    }

    func testSeamIsRestrictedToAlignmentSupportInsteadOfUnrelatedMatchingChrome() throws {
        let canvas = ImageStripCanvas(width: 40)
        let earlier = try bitmap { _, y in (70...74).contains(y) ? (20, 20, 210) : (210, 20, 20) }
        let later = try bitmap { _, y in
            if (10...14).contains(y) { return (20, 20, 210) }
            // 另一个像素一致区模拟输入栏碰巧与不同内容颜色相同。
            return (25...35).contains(y) ? (210, 20, 20) : (20, 210, 20)
        }
        let rect = CGRect(x: 0, y: 0, width: 40, height: 100)
        canvas.add(bitmap: earlier, rect: rect, offset: 0, capturedAt: time(1))
        canvas.add(bitmap: later, rect: rect, offset: 60, capturedAt: time(2), seamRange: 11...13)
        let result = try rendered(canvas)
        XCTAssertGreaterThan(result.color(x: 20, y: 69).r, 200)
        XCTAssertGreaterThan(result.color(x: 20, y: 72).b, 200)
        XCTAssertGreaterThan(result.color(x: 20, y: 75).g, 200)
        canvas.add(bitmap: later, rect: rect, offset: 60, capturedAt: time(3))
        let replaced = try rendered(canvas)
        for y in 0..<result.height {
            XCTAssertEqual(replaced.color(x: 20, y: y), result.color(x: 20, y: y))
        }
    }

    func testCanvasHasNoImplicitTenStripLimitAndRejectsInvalidInputAtomically() throws {
        let canvas = ImageStripCanvas(width: 40)
        let image = try bitmap { _, _ in (210, 20, 20) }
        let rect = CGRect(x: 0, y: 0, width: 40, height: 100)
        for index in 0..<12 {
            XCTAssertTrue(canvas.add(bitmap: image, rect: rect, offset: CGFloat(index * 60), capturedAt: time(Double(index))))
        }
        XCTAssertEqual(canvas.count, 12)
        let bytes = canvas.storedByteCount
        XCTAssertFalse(canvas.add(bitmap: image, rect: rect, offset: .infinity, capturedAt: time(13)))
        XCTAssertFalse(canvas.add(bitmap: image, rect: rect, offset: 0,
                                  exclusions: [CGRect(x: 0, y: CGFloat.nan, width: 10, height: 10)], capturedAt: time(13)))
        XCTAssertFalse(canvas.add(bitmap: image, rect: CGRect(x: 0, y: 0, width: -40, height: 100),
                                  offset: 0, capturedAt: time(13)))
        XCTAssertFalse(canvas.add(bitmap: image, rect: rect, offset: 720,
                                  capturedAt: time(13), maxStoredBytes: bytes))
        XCTAssertEqual(canvas.count, 12)
        XCTAssertEqual(canvas.storedByteCount, bytes)
        canvas.trim(to: 2)
        XCTAssertEqual(canvas.count, 2)
    }

    func testBudgetAllowsCoveredSourceReplacementAndRejectsGrowthAtomically() throws {
        let canvas = ImageStripCanvas(width: 40)
        let image = try bitmap { _, _ in (210, 20, 20) }
        let rect = CGRect(x: 0, y: 0, width: 40, height: 100)
        XCTAssertTrue(canvas.add(bitmap: image, rect: rect, offset: 0, capturedAt: time(1)))
        let budget = canvas.storedByteCount
        XCTAssertTrue(canvas.add(bitmap: image, rect: rect, offset: 0, capturedAt: time(2), maxStoredBytes: budget))
        XCTAssertEqual(canvas.count, 1)
        XCTAssertFalse(canvas.add(bitmap: image, rect: rect, offset: 60, capturedAt: time(3), maxStoredBytes: budget))
        XCTAssertEqual(canvas.span, 100)
        XCTAssertEqual(canvas.storedByteCount, budget)
    }
}
