import AppKit
import ImageIO

/// Documents retain only metadata. The visible preview owns its decoded frame.
struct PreviewImageSource {
    let url: URL
    let pixelSize: NSSize

    init?(url: URL, data: Data) {
        guard let source = CGImageSourceCreateWithData(data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0, width.isFinite, height.isFinite,
              Self.thumbnail(source, maximum: 1) != nil else { return nil }
        self.url = url
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        pixelSize = (5...8).contains(orientation)
            ? NSSize(width: height, height: width) : NSSize(width: width, height: height)
    }

    func decode(maximum: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary),
              let frame = Self.thumbnail(source, maximum: maximum) else { return nil }
        // Logical dimensions stay fixed as the backing bitmap changes on resize.
        let representation = NSBitmapImageRep(cgImage: frame)
        representation.size = pixelSize
        let image = NSImage(size: pixelSize)
        image.addRepresentation(representation)
        image.cacheMode = .never
        return image
    }

    private static func thumbnail(_ source: CGImageSource, maximum: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(4096, max(1, maximum)),
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }
}
