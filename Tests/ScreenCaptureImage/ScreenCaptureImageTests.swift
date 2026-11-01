import XCTest
import UIKit

final class ScreenCaptureImageTests: XCTestCase {
    private typealias RGB = (Double, Double, Double)
    private let red: RGB = (1, 0, 0)
    private let green: RGB = (0, 1, 0)
    private let blue: RGB = (0, 0, 1)
    private let yellow: RGB = (1, 1, 0)

    // Expected top-left, top-right, bottom-left, bottom-right colors. These are
    // independent of the encoder, including both mirrored quarter-turn variants.
    private var cases: [(UIImage.Orientation, [RGB])] {
        [(.up, [red, green, blue, yellow]),
         (.upMirrored, [green, red, yellow, blue]),
         (.down, [yellow, blue, green, red]),
         (.downMirrored, [blue, yellow, red, green]),
         (.left, [green, yellow, red, blue]),
         (.right, [blue, red, yellow, green]),
         (.leftMirrored, [red, blue, green, yellow]),
         (.rightMirrored, [yellow, green, blue, red])]
    }

    private func source() throws -> CGImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let image = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 80), format: format).image { context in
            for (index, color) in [UIColor.red, .green, .blue, .yellow].enumerated() {
                context.cgContext.setFillColor(color.cgColor)
                context.cgContext.fill(CGRect(x: (index % 2) * 60, y: (index / 2) * 40, width: 60, height: 40))
            }
        }
        return try XCTUnwrap(image.cgImage)
    }

    /// Draw the requested UIKit point into a one-pixel canvas, then read that
    /// pixel in a known RGBA layout. No assumptions about UIImage's byte order.
    private func pixel(_ image: UIImage, x: CGFloat, y: CGFloat) throws -> RGB {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        let sample = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1), format: format).image { _ in
            image.draw(at: CGPoint(x: -x, y: -y))
        }
        let cg = try XCTUnwrap(sample.cgImage)
        var bytes = [UInt8](repeating: 0, count: 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1,
                                          bitsPerComponent: 8, bytesPerRow: 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        XCTAssertTrue(drawn)
        return (Double(bytes[0]) / 255, Double(bytes[1]) / 255, Double(bytes[2]) / 255)
    }

    private func assertCorners(_ image: UIImage, expected: [RGB], tolerance: Double,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        for (index, expected) in expected.enumerated() {
            let x = image.size.width * (index % 2 == 0 ? 0.25 : 0.75)
            let y = image.size.height * (index / 2 == 0 ? 0.25 : 0.75)
            let actual = try pixel(image, x: x, y: y)
            XCTAssertEqual(actual.0, expected.0, accuracy: tolerance, "red at corner \(index)", file: file, line: line)
            XCTAssertEqual(actual.1, expected.1, accuracy: tolerance, "green at corner \(index)", file: file, line: line)
            XCTAssertEqual(actual.2, expected.2, accuracy: tolerance, "blue at corner \(index)", file: file, line: line)
        }
    }

    func testPNGAndJPEGApplyAllEightOrientationsWithoutStretchingOrDoubleRotation() throws {
        let source = try source()
        for (orientation, corners) in cases {
            let image = UIImage(cgImage: source, scale: 2, orientation: orientation)
            let geometry = try XCTUnwrap(ScreenCaptureImage.geometry(of: image, deviceScale: 2))
            for scale in [1.0, 2.0] {
                for format in [ScreenCaptureImage.Format.png, .jpeg] {
                    let result = try XCTUnwrap(ScreenCaptureImage.encode(image, geometry: geometry,
                        requestedScale: scale, format: format, quality: 0.95))
                    let decoded = try XCTUnwrap(UIImage(data: result.data))
                    let pixels = try XCTUnwrap(decoded.cgImage)
                    XCTAssertEqual(result.pixelSize, CGSize(width: pixels.width, height: pixels.height))
                    XCTAssertEqual(result.pixelSize, CGSize(width: image.size.width * scale, height: image.size.height * scale))
                    XCTAssertEqual(decoded.imageOrientation, .up)
                    XCTAssertEqual(result.scale, scale)
                    try assertCorners(decoded, expected: corners, tolerance: 0.08)
                }
            }
        }
    }

    func testOCRNormalizationUsesTheSameOrientedPixelsAsScreenshot() throws {
        let source = try source()
        for (orientation, corners) in cases {
            let image = UIImage(cgImage: source, scale: 2, orientation: orientation)
            let upright = try XCTUnwrap(ScreenCaptureImage.uprightImage(image))
            let pixels = try XCTUnwrap(upright.cgImage)
            XCTAssertEqual(upright.imageOrientation, .up)
            XCTAssertEqual(CGSize(width: pixels.width, height: pixels.height),
                           CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale))
            try assertCorners(upright, expected: corners, tolerance: 0.02)
        }
    }

    func testFractionalOutputMetadataDescribesDecodedBytes() throws {
        let image = UIImage(cgImage: try source(), scale: 2, orientation: .right)
        let geometry = try XCTUnwrap(ScreenCaptureImage.geometry(of: image, deviceScale: 2))
        let result = try XCTUnwrap(ScreenCaptureImage.encode(image, geometry: geometry,
            requestedScale: 0.333, format: .png, quality: 1))
        let decoded = try XCTUnwrap(UIImage(data: result.data)?.cgImage)
        XCTAssertEqual(result.pixelSize, CGSize(width: decoded.width, height: decoded.height))
        XCTAssertEqual(result.pixelSize, CGSize(width: 13, height: 20))
        XCTAssertEqual(result.scale, 0.333)
    }

    func testInvalidEncodingParametersDoNotReturnOriginalBytes() throws {
        let image = UIImage(cgImage: try source(), scale: 2, orientation: .right)
        let geometry = try XCTUnwrap(ScreenCaptureImage.geometry(of: image, deviceScale: 2))
        XCTAssertNil(ScreenCaptureImage.encode(image, geometry: geometry, requestedScale: .nan, format: .png, quality: 1))
        XCTAssertNil(ScreenCaptureImage.encode(image, geometry: geometry, requestedScale: 2, format: .jpeg, quality: .nan))
    }
}
