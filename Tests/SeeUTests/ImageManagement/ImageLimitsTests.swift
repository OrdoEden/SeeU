import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import SeeU

final class ImageLimitsTests: XCTestCase {
    func testEncodedAndPixelBudgetsFailExplicitlyBeforeOCR() throws {
        XCTAssertThrowsError(try FrameBitmap(imageData: Data(repeating: 0, count: 2),
                                            limits: SeeUImageLimits(maximumEncodedBytes: 1))) {
            guard case SeeUImageError.encodedSizeExceeded = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
        let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        XCTAssertThrowsError(try FrameBitmap(imageData: data as Data, limits: SeeUImageLimits(maximumPixels: 3))) {
            guard case SeeUImageError.pixelBudgetExceeded = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
    }
}
