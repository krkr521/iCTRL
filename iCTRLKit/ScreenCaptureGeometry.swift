import Foundation

/// Geometry from one capture, never from a previous app frame or device rotation.
/// `imageSize` must already include the image's display orientation (UIImage.size does).
struct ScreenCaptureGeometry: Equatable {
    let pixelSize: CGSize
    let pointSize: CGSize
    let deviceScale: Double

    init?(imageSize: CGSize, imageScale: Double, deviceScale: Double) {
        guard Self.isValid(imageSize), imageScale.isFinite, imageScale > 0,
              deviceScale.isFinite, deviceScale > 0 else { return nil }
        let pixels = CGSize(width: imageSize.width * imageScale, height: imageSize.height * imageScale)
        guard Self.isValid(pixels) else { return nil }
        let points = CGSize(width: pixels.width / deviceScale, height: pixels.height / deviceScale)
        guard Self.isValid(points) else { return nil }
        pixelSize = pixels
        pointSize = points
        self.deviceScale = deviceScale
    }

    struct Output {
        let scale: Double
        /// Uniformly scaled drawing bounds. Never stretch each axis to rounded pixels.
        let drawSize: CGSize
        /// A bitmap has integral dimensions; its last edge can differ by < 0.5 pixel.
        let canvasSize: CGSize
    }

    func output(requestedScale: Double) -> Output? {
        guard requestedScale.isFinite else { return nil }
        let outputScale = min(max(requestedScale, 0.05), 3)
        let draw = CGSize(width: pointSize.width * outputScale, height: pointSize.height * outputScale)
        guard Self.isValid(draw) else { return nil }
        return Output(scale: outputScale, drawSize: draw,
                      canvasSize: CGSize(width: max(1, draw.width.rounded()), height: max(1, draw.height.rounded())))
    }

    /// Vision uses a bottom-left normalized origin; input APIs use top-left points.
    func pointRect(visionBounds: CGRect) -> CGRect {
        CGRect(x: visionBounds.minX * pointSize.width,
               y: (1 - visionBounds.maxY) * pointSize.height,
               width: visionBounds.width * pointSize.width,
               height: visionBounds.height * pointSize.height)
    }

    private static func isValid(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }
}
