import AppKit
import ImageIO
import CoreGraphics

/// Documents retain only metadata. The visible preview owns its decoded frame.
struct PreviewImageSource {
    let url: URL
    let pixelSize: NSSize
    /// How the pixels are produced.
    private enum Backing {
        /// ImageIO reads the file. `previewRange`, when set, is the slice of an
        /// EPS container holding the bitmap preview — the whole file is
        /// PostScript, which nothing on macOS can draw, so the preview beside
        /// it is what gets shown.
        case bitmap(previewRange: Range<Int>?)
        /// The file is a PDF under another name. Illustrator saves `.ai` this
        /// way whenever "Create PDF Compatible File" is on, which is the
        /// default, and a PDF carries no pixel dimensions for ImageIO to
        /// report. Drawn through Quartz instead, which has the happy result
        /// that it re-renders sharp at whatever size the pane asks for.
        case pdfPage
    }
    private let backing: Backing

    init?(url: URL, data: Data) {
        let previewRange = EPSContainer.previewRange(in: data)
        let decodable = Self.decodable(data, previewRange: previewRange)
        if let source = CGImageSourceCreateWithData(decodable as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any],
           let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
           let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
           width > 0, height > 0, width.isFinite, height.isFinite,
           Self.thumbnail(source, maximum: Self.probeSize) != nil {
            self.url = url
            self.backing = .bitmap(previewRange: previewRange)
            let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            pixelSize = (5...8).contains(orientation)
                ? NSSize(width: height, height: width) : NSSize(width: width, height: height)
            return
        }
        guard let box = Self.pageBox(of: url) else { return nil }
        self.url = url
        self.backing = .pdfPage
        pixelSize = box
    }

    /// Natural size of a PDF's first page, in points.
    private static func pageBox(of url: URL) -> NSSize? {
        guard let document = CGPDFDocument(url as CFURL), document.numberOfPages > 0,
              let page = document.page(at: 1) else { return nil }
        let box = page.getBoxRect(.cropBox)
        let rotation = abs(page.rotationAngle) % 360
        let size = (rotation == 90 || rotation == 270)
            ? NSSize(width: box.height, height: box.width)
            : NSSize(width: box.width, height: box.height)
        guard size.width > 0, size.height > 0,
              size.width.isFinite, size.height.isFinite else { return nil }
        return size
    }

    func decode(maximum: Int) -> NSImage? {
        let decoded: CGImage?
        switch backing {
        case .bitmap:
            decoded = imageSource().flatMap { Self.thumbnail($0, maximum: maximum) }
        case .pdfPage:
            decoded = renderPage(maximum: maximum)
        }
        guard let frame = decoded else { return nil }
        // Logical dimensions stay fixed as the backing bitmap changes on resize.
        let representation = NSBitmapImageRep(cgImage: frame)
        representation.size = pixelSize
        let image = NSImage(size: pixelSize)
        image.addRepresentation(representation)
        image.cacheMode = .never
        return image
    }

    /// Rasterise the first page at the requested size. Vector art has no
    /// native resolution, so the only bound that matters is the one the pane
    /// asked for.
    private func renderPage(maximum: Int) -> CGImage? {
        guard let document = CGPDFDocument(url as CFURL), let page = document.page(at: 1)
        else { return nil }
        let box = page.getBoxRect(.cropBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let bound = CGFloat(min(4096, max(1, maximum)))
        let scale = min(bound / box.width, bound / box.height)
        let width = Int((box.width * scale).rounded()), height = Int((box.height * scale).rounded())
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.origin.x, y: -box.origin.y)
        context.drawPDFPage(page)
        return context.makeImage()
    }

    /// Re-read the file rather than holding its bytes: a decode happens on
    /// every resize, and a retained copy of a 200 MB scan would defeat the
    /// bounded decoding this type exists for. The mapped slice costs nothing
    /// until ImageIO touches the pages.
    private func imageSource() -> CGImageSource? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard case .bitmap(let previewRange) = backing, let previewRange else {
            return CGImageSourceCreateWithURL(url as CFURL, options)
        }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              previewRange.upperBound <= data.count else { return nil }
        return CGImageSourceCreateWithData(
            Self.decodable(data, previewRange: previewRange) as CFData, options)
    }

    /// The bytes ImageIO is actually given: the whole file, or the embedded
    /// preview sliced out of a container.
    private static func decodable(_ data: Data, previewRange: Range<Int>?) -> Data {
        guard let previewRange, previewRange.upperBound <= data.count else { return data }
        let start = data.startIndex + previewRange.lowerBound
        let end = data.startIndex + previewRange.upperBound
        return data.subdata(in: start..<end)
    }

    /// Size of the throwaway decode that proves a file is really readable
    /// before it is accepted as a picture.
    ///
    /// Not 1 pixel, which is what this used to ask for: HEVC — the codec inside
    /// a HEIC — has a minimum coded size and returns nothing for a thumbnail
    /// that small, so every HEIC on the machine failed the probe and opened as
    /// "unsupported file type" instead of as a photo. Sixteen pixels decodes
    /// everything ImageIO claims to support and still costs nothing.
    private static let probeSize = 16

    private static func thumbnail(_ source: CGImageSource, maximum: Int) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(4096, max(1, maximum)),
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }
}
