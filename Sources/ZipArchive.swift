import Foundation
import Compression

/// Minimal read-only ZIP reader, enough for the one container format Puzzle
/// opens: an EPUB.
///
/// macOS ships no ZIP API a Swift process can link (libarchive has no header in
/// the SDK), and shelling out to `/usr/bin/unzip` would mean writing the whole
/// book to a temporary directory to read one chapter. Reading the central
/// directory and inflating single entries on demand keeps a 40 MB book at the
/// cost of the chapter on screen, and the deflate itself is the system's:
/// `COMPRESSION_ZLIB` is raw DEFLATE, which is exactly what a ZIP entry holds.
struct ZipArchive {
    struct Entry {
        let path: String
        let compressionMethod: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        /// Offset of the *local* header. The entry's bytes start past it, at a
        /// distance only that header knows (its name and extra fields are
        /// allowed to differ in length from the central directory's).
        let localHeaderOffset: Int
    }

    private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4b50
    private static let centralFileHeaderSignature: UInt32 = 0x0201_4b50
    private static let localFileHeaderSignature: UInt32 = 0x0403_4b50
    private static let stored: UInt16 = 0
    private static let deflated: UInt16 = 8

    /// A single entry that inflates to more than this is refused. Nothing in a
    /// book is this big, and a compressed stream that claims to be is either
    /// broken or hostile.
    static let maxEntryBytes = 64 * 1024 * 1024
    /// The EOCD record sits at the end, after a comment of up to 64 KB.
    private static let maxCommentBytes = 0xFFFF

    private let data: Data
    private let entries: [String: Entry]
    /// Central-directory order, which for an EPUB is roughly reading order.
    let paths: [String]

    /// Map the file and read its index. Nothing is decompressed here.
    init?(url: URL) {
        guard let mapped = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return nil
        }
        self.init(data: mapped)
    }

    init?(data: Data) {
        guard data.count >= 22 else { return nil }
        self.data = data

        // Scan backwards for the end-of-central-directory record. It is the
        // only structure whose position is not written down anywhere.
        let searchFloor = max(0, data.count - Self.maxCommentBytes - 22)
        var eocd = -1
        var candidate = data.count - 22
        while candidate >= searchFloor {
            if Self.uint32(data, at: candidate) == Self.endOfCentralDirectorySignature {
                eocd = candidate
                break
            }
            candidate -= 1
        }
        guard eocd >= 0 else { return nil }

        let entryCount = Int(Self.uint16(data, at: eocd + 10))
        let directorySize = Int(Self.uint32(data, at: eocd + 12))
        let directoryOffset = Int(Self.uint32(data, at: eocd + 16))
        guard directoryOffset >= 0, directorySize >= 0,
              directoryOffset + directorySize <= data.count else { return nil }

        var index: [String: Entry] = [:]
        var order: [String] = []
        var cursor = directoryOffset
        let directoryEnd = directoryOffset + directorySize
        for _ in 0..<entryCount {
            guard cursor + 46 <= directoryEnd,
                  Self.uint32(data, at: cursor) == Self.centralFileHeaderSignature else { break }
            let method = Self.uint16(data, at: cursor + 10)
            let compressed = Int(Self.uint32(data, at: cursor + 20))
            let uncompressed = Int(Self.uint32(data, at: cursor + 24))
            let nameLength = Int(Self.uint16(data, at: cursor + 28))
            let extraLength = Int(Self.uint16(data, at: cursor + 30))
            let commentLength = Int(Self.uint16(data, at: cursor + 32))
            let localOffset = Int(Self.uint32(data, at: cursor + 42))
            let nameStart = cursor + 46
            guard nameStart + nameLength <= directoryEnd else { break }
            let nameBytes = Self.slice(data, at: nameStart, length: nameLength)
            // ZIP names are CP437 unless the UTF-8 flag is set; every EPUB in
            // practice is UTF-8, and a name we cannot decode is one we could
            // not have been asked for anyway.
            if let name = String(data: nameBytes, encoding: .utf8), !name.hasSuffix("/") {
                let entry = Entry(path: name, compressionMethod: method,
                                  compressedSize: compressed,
                                  uncompressedSize: uncompressed,
                                  localHeaderOffset: localOffset)
                if index.updateValue(entry, forKey: name) == nil { order.append(name) }
            }
            cursor = nameStart + nameLength + extraLength + commentLength
        }
        guard !index.isEmpty else { return nil }
        entries = index
        paths = order
    }

    func contains(_ path: String) -> Bool { entries[path] != nil }

    /// Inflate one entry. Returns nil for a missing, oversized, truncated or
    /// unsupported (encrypted, zip64) entry rather than trapping.
    func data(for path: String) -> Data? {
        guard let entry = entries[path] else { return nil }
        guard entry.uncompressedSize >= 0, entry.uncompressedSize <= Self.maxEntryBytes,
              entry.compressedSize >= 0, entry.compressedSize <= Self.maxEntryBytes else {
            return nil
        }
        // The local header repeats the name and extra fields at its own
        // lengths, and only they say where the payload starts.
        let header = entry.localHeaderOffset
        guard header >= 0, header + 30 <= data.count,
              Self.uint32(data, at: header) == Self.localFileHeaderSignature else { return nil }
        let nameLength = Int(Self.uint16(data, at: header + 26))
        let extraLength = Int(Self.uint16(data, at: header + 28))
        let start = header + 30 + nameLength + extraLength
        guard start >= 0, start + entry.compressedSize <= data.count else { return nil }
        let payload = Self.slice(data, at: start, length: entry.compressedSize)

        switch entry.compressionMethod {
        case Self.stored:
            guard payload.count == entry.uncompressedSize else { return nil }
            return payload
        case Self.deflated:
            return Self.inflate(payload, to: entry.uncompressedSize)
        default:
            return nil
        }
    }

    /// Raw DEFLATE, to a buffer the central directory already sized for us.
    private static func inflate(_ payload: Data, to size: Int) -> Data? {
        guard size > 0 else { return Data() }
        var output = Data(count: size)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress
            else { return 0 }
            return payload.withUnsafeBytes { source -> Int in
                guard let sourceBase = source.bindMemory(to: UInt8.self).baseAddress
                else { return 0 }
                return compression_decode_buffer(destinationBase, size,
                                                 sourceBase, payload.count,
                                                 nil, COMPRESSION_ZLIB)
            }
        }
        // A short read means a truncated or corrupt stream: the central
        // directory promised more bytes than the deflate produced.
        guard written == size else { return nil }
        return output
    }

    /// `Data` read from a file is not zero-based, so every offset in the
    /// archive has to be taken relative to `startIndex`.
    private static func slice(_ data: Data, at offset: Int, length: Int) -> Data {
        let start = data.startIndex + offset
        let end = start + length
        guard offset >= 0, length >= 0, end <= data.endIndex else { return Data() }
        return data.subdata(in: start..<end)
    }

    private static func uint16(_ data: Data, at offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else { return 0 }
        let base = data.startIndex + offset
        return UInt16(data[base]) | (UInt16(data[base + 1]) << 8)
    }

    private static func uint32(_ data: Data, at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        let base = data.startIndex + offset
        return UInt32(data[base]) | (UInt32(data[base + 1]) << 8)
            | (UInt32(data[base + 2]) << 16) | (UInt32(data[base + 3]) << 24)
    }
}
