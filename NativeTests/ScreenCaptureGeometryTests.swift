import XCTest
#if canImport(CoreGraphics)
import CoreGraphics
#endif
@testable import NativePolicy

final class ScreenCaptureGeometryTests: XCTestCase {
    func testPortraitLandscapeAndReturnUseTheirOwnCapture() throws {
        for size in [CGSize(width: 402, height: 874), CGSize(width: 874, height: 402), CGSize(width: 402, height: 874)] {
            let geometry = try XCTUnwrap(ScreenCaptureGeometry(imageSize: size, imageScale: 3, deviceScale: 3))
            let output = try XCTUnwrap(geometry.output(requestedScale: 2))
            XCTAssertEqual(geometry.pointSize, size)
            XCTAssertEqual(output.canvasSize, CGSize(width: size.width * 2, height: size.height * 2))
            XCTAssertEqual(output.scale, 2)
        }
    }

    func testImageScaleOneAndThreeDescribeTheSameScreen() throws {
        let scaled = try XCTUnwrap(ScreenCaptureGeometry(imageSize: CGSize(width: 874, height: 402), imageScale: 3, deviceScale: 3))
        let raw = try XCTUnwrap(ScreenCaptureGeometry(imageSize: CGSize(width: 2622, height: 1206), imageScale: 1, deviceScale: 3))
        XCTAssertEqual(scaled, raw)
        XCTAssertEqual(raw.pointSize, CGSize(width: 874, height: 402))
    }

    func testFractionalScaleRoundsOnlyCanvasAndKeepsUniformDrawingRatio() throws {
        let geometry = try XCTUnwrap(ScreenCaptureGeometry(imageSize: CGSize(width: 402, height: 874), imageScale: 3, deviceScale: 3))
        for requested in [0.05, 0.333, 1.1, 1.75, 2.25] {
            let output = try XCTUnwrap(geometry.output(requestedScale: requested))
            XCTAssertEqual(output.drawSize.width / 402, output.drawSize.height / 874, accuracy: 0.000001)
            XCTAssertLessThanOrEqual(abs(output.canvasSize.width - output.drawSize.width), 0.5)
            XCTAssertLessThanOrEqual(abs(output.canvasSize.height - output.drawSize.height), 0.5)
            XCTAssertEqual(output.canvasSize.width, output.canvasSize.width.rounded())
            XCTAssertEqual(output.canvasSize.height, output.canvasSize.height.rounded())
        }
    }

    func testScaleClampAndInvalidGeometry() throws {
        let geometry = try XCTUnwrap(ScreenCaptureGeometry(imageSize: CGSize(width: 402, height: 874), imageScale: 3, deviceScale: 3))
        XCTAssertEqual(try XCTUnwrap(geometry.output(requestedScale: 0)).scale, 0.05)
        XCTAssertEqual(try XCTUnwrap(geometry.output(requestedScale: 99)).scale, 3)
        XCTAssertNil(geometry.output(requestedScale: .nan))
        XCTAssertNil(geometry.output(requestedScale: .infinity))
        for scale in [0.0, -1, .nan, .infinity] {
            XCTAssertNil(ScreenCaptureGeometry(imageSize: CGSize(width: 402, height: 874), imageScale: scale, deviceScale: 3))
            XCTAssertNil(ScreenCaptureGeometry(imageSize: CGSize(width: 402, height: 874), imageScale: 3, deviceScale: scale))
        }
        XCTAssertNil(ScreenCaptureGeometry(imageSize: .zero, imageScale: 3, deviceScale: 3))
        XCTAssertNil(ScreenCaptureGeometry(imageSize: CGSize(width: CGFloat.infinity, height: 874), imageScale: 3, deviceScale: 3))
    }

    func testVisionBoxUsesLandscapePointsAndTopLeftOrigin() throws {
        let geometry = try XCTUnwrap(ScreenCaptureGeometry(imageSize: CGSize(width: 874, height: 402), imageScale: 3, deviceScale: 3))
        let box = geometry.pointRect(visionBounds: CGRect(x: 0.1, y: 0.7, width: 0.2, height: 0.1))
        XCTAssertEqual(box.minX, 87.4, accuracy: 0.000001)
        XCTAssertEqual(box.minY, 80.4, accuracy: 0.000001)
        XCTAssertEqual(box.width, 174.8, accuracy: 0.000001)
        XCTAssertEqual(box.height, 40.2, accuracy: 0.000001)
    }
}
