import UIKit

/// UIKit applies all eight UIImage orientations while drawing. UIImage.size already
/// reflects that orientation: swapping width/height here would rotate geometry twice.
enum ScreenCaptureImage {
    enum Format { case png, jpeg }

    struct Encoded {
        let data: Data
        let pixelSize: CGSize
        let scale: Double
    }

    static func geometry(of image: UIImage, deviceScale: Double) -> ScreenCaptureGeometry? {
        ScreenCaptureGeometry(imageSize: image.size, imageScale: Double(image.scale), deviceScale: deviceScale)
    }

    static func encode(_ image: UIImage, geometry: ScreenCaptureGeometry, requestedScale: Double,
                       format: Format, quality: Double) -> Encoded? {
        guard quality.isFinite, let output = geometry.output(requestedScale: requestedScale) else { return nil }
        let rendered = render(image, drawSize: output.drawSize, canvasSize: output.canvasSize)
        guard let pixels = rendered.cgImage else { return nil }
        let data: Data?
        switch format {
        case .png: data = rendered.pngData()
        case .jpeg: data = rendered.jpegData(compressionQuality: CGFloat(min(max(quality, 0.1), 1)))
        }
        // No fallback to the original image: that would return bytes with different
        // dimensions/orientation while claiming the requested output geometry.
        guard let data, !data.isEmpty else { return nil }
        return Encoded(data: data, pixelSize: CGSize(width: pixels.width, height: pixels.height), scale: output.scale)
    }

    /// Vision consumes the CGImage, which carries no UIImage orientation metadata.
    /// Normalize first so Vision's .up and the screenshot's point space agree.
    static func uprightImage(_ image: UIImage) -> UIImage? {
        guard let geometry = geometry(of: image, deviceScale: 1) else { return nil }
        if image.imageOrientation == .up, image.cgImage != nil { return image }
        return render(image, drawSize: geometry.pixelSize, canvasSize: geometry.pixelSize)
    }

    private static func render(_ image: UIImage, drawSize: CGSize, canvasSize: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: canvasSize, format: format).image { context in
            context.cgContext.setFillColor(UIColor.black.cgColor)
            context.cgContext.fill(CGRect(origin: .zero, size: canvasSize))
            image.draw(in: CGRect(origin: .zero, size: drawSize))
        }
    }
}
