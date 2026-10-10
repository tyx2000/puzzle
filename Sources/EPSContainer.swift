import Foundation

/// Finds the bitmap preview embedded in an EPS file.
///
/// EPS is PostScript, and macOS stopped rendering PostScript years ago: there
/// is no system API left that will draw one. `NSEPSImageRep` still exists and
/// still returns nil, ImageIO declines the type, and Quartz will not open it.
///
/// What saves the format is that almost every EPS written by a drawing program
/// is wrapped in a DOS EPS binary container, which carries a flattened TIFF
/// preview beside the PostScript precisely so that software which cannot
/// interpret PostScript has something to show. That preview is what Finder puts
/// in a thumbnail, and it is what Puzzle draws. Illustrator writes `.ai` files
/// in the same container, so they take this path too.
///
/// An EPS that is pure PostScript with no preview cannot be displayed by
/// anything on this machine, and the editor says so rather than pretending.
enum EPSContainer {
    /// The DOS EPS binary header's signature, little-endian 0xC6D3D0C5.
    private static let signature: [UInt8] = [0xC5, 0xD0, 0xD3, 0xC6]
    /// Header layout: signature, then three (offset, length) pairs for the
    /// PostScript, WMF and TIFF sections, then a checksum. 30 bytes in all.
    private static let headerLength = 30

    /// True when the bytes are an EPS of either shape — binary container or
    /// bare PostScript. Used to explain why a file will not display.
    static func isEPS(_ data: Data) -> Bool {
        hasBinaryHeader(data) || data.starts(with: Array("%!PS".utf8))
    }

    static func hasBinaryHeader(_ data: Data) -> Bool {
        data.count >= headerLength && data.starts(with: signature)
    }

    /// Byte range of the embedded TIFF preview, relative to the start of the
    /// file, or nil when there is no container or no preview in it.
    ///
    /// The WMF slot is deliberately ignored: it is a Windows metafile, which
    /// ImageIO cannot read either, so claiming it would only move the failure.
    static func previewRange(in data: Data) -> Range<Int>? {
        guard hasBinaryHeader(data) else { return nil }
        let offset = uint32(data, at: 20)
        let length = uint32(data, at: 24)
        guard offset >= headerLength, length > 0 else { return nil }
        // A truncated download names a preview that runs past the end of the
        // file; slicing on those numbers unchecked would trap.
        guard let end = offset.addingReportingOverflowIfPositive(length),
              end <= data.count else { return nil }
        return offset..<end
    }

    private static func uint32(_ data: Data, at offset: Int) -> Int {
        let base = data.startIndex + offset
        guard base >= data.startIndex, base + 4 <= data.endIndex else { return 0 }
        let value = UInt32(data[base]) | (UInt32(data[base + 1]) << 8)
            | (UInt32(data[base + 2]) << 16) | (UInt32(data[base + 3]) << 24)
        // The header is unsigned 32-bit; anything past Int.max is nonsense on a
        // file we have already size-limited, so it reads as absent.
        return value > UInt32(Int32.max) ? 0 : Int(value)
    }
}

private extension Int {
    /// `self + other`, or nil if it overflows. Both sides are already known to
    /// be non-negative here.
    func addingReportingOverflowIfPositive(_ other: Int) -> Int? {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? nil : sum
    }
}
